local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

---@type integer
local pypi_get_calls
---@type integer
local pypi_cached_calls

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      helpers.close_extra_windows()
      vim.cmd("enew!")

      pypi_get_calls = 0
      pypi_cached_calls = 0

      package.loaded["pydeps.core.env"] = {
        get = function()
          return {}
        end,
      }
      package.loaded["pydeps.providers.pypi"] = {
        get_cached = function()
          pypi_cached_calls = pypi_cached_calls + 1
          return nil
        end,
        get = function(_, cb)
          pypi_get_calls = pypi_get_calls + 1
          if cb then
            cb({ releases = {} })
          end
        end,
        is_yanked = function()
          return false
        end,
        sorted_versions = function()
          return {}
        end,
      }
      package.loaded["pydeps.ui.virtual_text"] = nil
      package.loaded["pydeps.ui.diagnostics"] = nil
      package.loaded["pydeps.core.jobs"] = nil

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
      require("pydeps.core.state").disable()
    end,
  },
})

local function create_project(lines)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  helpers.create_uv_lock(dir, { requests = "2.31.0" })
  vim.cmd("edit " .. path)
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
