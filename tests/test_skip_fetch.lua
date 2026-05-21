local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

---@type integer
local pypi_get_calls
---@type integer
local pypi_cached_calls
---@type table<string, any>
local pypi_fetched = {}
---@type table<string, any>
local saved_modules = {}

-- Many earlier suites stub random `pydeps.*` modules (cache, project,
-- virtual_text, state, …) in `package.loaded`. State/virtual_text capture
-- those references in their top-level locals at first load, so swapping
-- only `pypi` leaves stale closures calling the wrong table. Drop *every*
-- pydeps.* entry from the cache (except the stubs we want to install)
-- before calling setup(), so the whole graph rebuilds from disk against
-- our stubs. Restore originals in post_case so we don't pollute later
-- suites.
---@param name any
---@return boolean
local function is_pydeps_module(name)
  return type(name) == "string" and (name == "pydeps" or name:sub(1, 7) == "pydeps.")
end

local function snapshot_pydeps_modules()
  saved_modules = {}
  for name, mod in pairs(package.loaded) do
    if is_pydeps_module(name) then
      saved_modules[name] = mod
    end
  end
end

local function clear_pydeps_modules()
  for name in pairs(saved_modules) do
    package.loaded[name] = nil
  end
end

local function restore_pydeps_modules()
  -- First wipe everything we may have populated during the test, including
  -- modules require()d for the first time during the test run (so they
  -- aren't carried into the next suite).
  for name in pairs(package.loaded) do
    if is_pydeps_module(name) then
      package.loaded[name] = nil
    end
  end
  for name, mod in pairs(saved_modules) do
    package.loaded[name] = mod
  end
  saved_modules = {}
end

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      helpers.close_extra_windows()
      vim.cmd("enew!")

      pypi_get_calls = 0
      pypi_cached_calls = 0

      snapshot_pydeps_modules()
      clear_pydeps_modules()

      package.loaded["pydeps.core.env"] = {
        get = function()
          return {}
        end,
      }
      -- Once a package is fetched, subsequent get_cached must return
      -- non-nil so the render loop stabilises. Without this, every render
      -- re-queues pypi.get for the same package, generating an unbounded
      -- chain of calls through the debouncer. Tests that need to verify
      -- skip_fetch suppression while the cache is empty must clear
      -- `pypi_fetched` themselves so the stub's get_cached returns nil.
      pypi_fetched = {}
      package.loaded["pydeps.providers.pypi"] = {
        get_cached = function(name)
          pypi_cached_calls = pypi_cached_calls + 1
          return pypi_fetched[name]
        end,
        get = function(name, cb)
          pypi_get_calls = pypi_get_calls + 1
          local meta = { releases = {} }
          pypi_fetched[name] = meta
          if cb then
            cb(meta)
          end
        end,
        is_yanked = function()
          return false
        end,
        sorted_versions = function()
          return {}
        end,
      }

      require("pydeps").setup({
        auto_refresh = true,
        refresh_debounce_ms = 10,
        enable_diagnostics = false,
        notify_on_missing_lockfile = false,
        show_missing_virtual_text = false,
        ui = {
          section_padding = 2,
          icons = { enabled = false },
          show = { resolved = true, latest = false },
        },
      })
    end,
    post_case = function()
      -- Always run restore_pydeps_modules so a disable() error doesn't
      -- leak our stubs into later suites, but re-raise the error after
      -- restoring so cleanup regressions still surface.
      local ok, err = pcall(function()
        require("pydeps.core.state").disable()
      end)
      restore_pydeps_modules()
      if not ok then
        error(err)
      end
    end,
  },
})

local function create_project(lines)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  helpers.create_uv_lock(dir, { requests = "2.31.0" })
  -- Suppress autocmds on edit so each test controls exactly when BufReadPost
  -- fires. Without this, vim.cmd("edit ...") triggers a real BufReadPost
  -- that pre-warms the pypi stub cache, making subsequent skip_fetch /
  -- jobs.stop_all assertions vacuously true.
  vim.api.nvim_cmd({ cmd = "edit", args = { path }, mods = { noautocmd = true } }, {})
  helpers.setup_buffer(lines)
  return dir, path
end

T["BufReadPost still fetches PyPI metadata"] = function()
  local dir = create_project({
    "[project]",
    "dependencies = [",
    '  "requests>=2",',
    "]",
  })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
  vim.wait(200, function()
    return pypi_get_calls > 0
  end, 10)

  MiniTest.expect.equality(pypi_get_calls > 0, true)
  vim.fn.delete(dir, "rf")
end

T["BufWritePost does not fetch PyPI metadata"] = function()
  local dir = create_project({
    "[project]",
    "dependencies = [",
    '  "requests>=2",',
    "]",
  })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  -- Warm up via BufReadPost so the autocmd path is exercised at least once.
  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
  vim.wait(100, function()
    return false
  end)

  -- Clear the stub cache so get_cached returns nil. Without this, the
  -- warm-up has populated `pypi_fetched["requests"]`, which would make
  -- BufWritePost's render skip queue_pypi_request even if skip_fetch were
  -- broken — i.e. the assertion below would pass vacuously.
  pypi_fetched = {}

  -- Reset counter and fire BufWritePost. With skip_fetch=true wired through,
  -- this must not call pypi.get even when get_cached returns nil.
  pypi_get_calls = 0
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })
  vim.wait(150, function()
    return false
  end)

  MiniTest.expect.equality(pypi_get_calls, 0)
  vim.fn.delete(dir, "rf")
end

T["queue_pypi_request is suppressed after jobs.stop_all"] = function()
  local dir = create_project({
    "[project]",
    "dependencies = [",
    '  "requests>=2",',
    "]",
  })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local jobs = require("pydeps.core.jobs")
  jobs._reset()
  jobs.stop_all()

  pypi_get_calls = 0
  vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
  vim.wait(150, function()
    return false
  end)

  MiniTest.expect.equality(pypi_get_calls, 0)

  jobs._reset()
  vim.fn.delete(dir, "rf")
end

return T
