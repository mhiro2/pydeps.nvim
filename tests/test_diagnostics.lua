local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function stub_env()
  helpers.stub_module("pydeps.core.env", {
    get = function()
      return {
        python_version = "3.11",
        sys_platform = "linux",
        os_name = "posix",
      }
    end,
  })
end

local function stub_pypi()
  local cache = {
    yankedpkg = {
      releases = {
        ["1.0.0"] = {
          { yanked = true },
        },
      },
    },
  }

  helpers.stub_module("pydeps.providers.pypi", {
    get_cached = function(name)
      return cache[name]
    end,
    get = function(name, cb)
      if not cache[name] then
        cache[name] = { releases = {} }
      end
      cb(cache[name])
    end,
    is_yanked = function(data, version)
      if not data or not version then
        return false
      end
      local releases = data.releases and data.releases[version]
      if not releases then
        return false
      end
      for _, file in ipairs(releases) do
        if file.yanked then
          return true
        end
      end
      return false
    end,
  })
end

---@param bufnr integer
---@return { lnum: integer, message: string, severity: integer }[]
local function pydeps_diagnostics(bufnr)
  local result = {}
  for _, item in ipairs(vim.diagnostic.get(bufnr)) do
    if item.source == "pydeps" then
      table.insert(result, { lnum = item.lnum, message = item.message, severity = item.severity })
    end
  end
  table.sort(result, function(a, b)
    return a.lnum < b.lnum or (a.lnum == b.lnum and a.message < b.message)
  end)
  return result
end

---@param lines string[]
---@return integer, PyDepsDependency[]
local function render_buffer(lines)
  helpers.setup_buffer(lines)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  return bufnr, require("pydeps.sources.pyproject").parse(nil, nil, bufnr)
end

---@return table
local function require_diagnostics()
  stub_env()
  helpers.stub_module("pydeps.providers.pypi", {
    get_cached = function()
      return { releases = {} }
    end,
    get = function(_, cb)
      cb({ releases = {} })
    end,
    is_yanked = function()
      return false
    end,
  })
  package.loaded["pydeps.ui.diagnostics"] = nil
  return require("pydeps.ui.diagnostics")
end

local severity = vim.diagnostic.severity

T["diagnostics for marker, lock diff, pinned, yanked"] = function()
  stub_env()
  stub_pypi()
  require("pydeps.config").setup({
    diagnostic_severity = { yanked = severity.ERROR, marker = severity.INFO, lock = severity.HINT },
  })
  package.loaded["pydeps.ui.diagnostics"] = nil
  local diagnostics = require("pydeps.ui.diagnostics")
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    "  \"markerpkg; sys_platform == 'win32'\",",
    '  "pinnedpkg==1.0.0",',
    '  "missingpkg>=2",',
    '  "yankedpkg",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = {
    markerpkg = "0.1.0",
    pinnedpkg = "1.1.0",
    yankedpkg = "1.0.0",
  }

  diagnostics.render(bufnr, deps, resolved, { lockfile_missing = false })

  -- Each rule reports with its own configured severity, and nothing else is reported.
  MiniTest.expect.equality(pydeps_diagnostics(bufnr), {
    {
      lnum = 2,
      message = "marker evaluates to false, but lockfile has a resolved version",
      severity = severity.INFO,
    },
    { lnum = 3, message = "lock mismatch: pinned 1.0.0 but resolved 1.1.0", severity = severity.HINT },
    { lnum = 4, message = "declared in pyproject.toml but missing in uv.lock", severity = severity.HINT },
    { lnum = 5, message = "resolved version is yanked on PyPI", severity = severity.ERROR },
  })
end

T["diagnostics for pin not found on PyPI"] = function()
  stub_env()
  local cache = {
    notfoundpkg = {
      releases = {
        ["1.0.0"] = {},
        ["1.2.0"] = {},
        ["2.0.0"] = {},
      },
    },
  }

  helpers.stub_module("pydeps.providers.pypi", {
    get_cached = function(name)
      return cache[name]
    end,
    get = function(name, cb)
      if not cache[name] then
        cache[name] = { releases = {} }
      end
      cb(cache[name])
    end,
    is_yanked = function()
      return false
    end,
  })
  package.loaded["pydeps.ui.diagnostics"] = nil
  local diagnostics = require("pydeps.ui.diagnostics")
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "notfoundpkg==1.1.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local resolved = {
    notfoundpkg = "1.1.0",
  }

  diagnostics.render(bufnr, deps, resolved, { lockfile_missing = false })

  MiniTest.expect.equality(pydeps_diagnostics(bufnr), {
    { lnum = 2, message = "pinned version 1.1.0 not found on public PyPI", severity = severity.WARN },
  })
end

T["diagnostic range uses exclusive end_col"] = function()
  stub_env()
  helpers.stub_module("pydeps.providers.pypi", {
    get_cached = function()
      return { releases = {} }
    end,
    get = function(_, cb)
      cb({ releases = {} })
    end,
    is_yanked = function()
      return false
    end,
  })
  package.loaded["pydeps.ui.diagnostics"] = nil
  local diagnostics = require("pydeps.ui.diagnostics")
  local pyproject = require("pydeps.sources.pyproject")

  helpers.setup_buffer({
    "[project]",
    "dependencies = [",
    '  "pinnedpkg==1.0.0",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  local deps = pyproject.parse(nil, nil, bufnr)
  local dep = deps[1]
  local resolved = {
    pinnedpkg = "1.1.0",
  }

  diagnostics.render(bufnr, deps, resolved, { lockfile_missing = false })
  local items = vim.diagnostic.get(bufnr)
  local target = nil
  for _, item in ipairs(items) do
    if item.message == "lock mismatch: pinned 1.0.0 but resolved 1.1.0" then
      target = item
      break
    end
  end

  MiniTest.expect.equality(target ~= nil, true)
  MiniTest.expect.equality(target.end_col, dep.col_end)
end

T["diagnostics report invalid and unknown markers"] = function()
  local diagnostics = require_diagnostics()
  local bufnr, deps = render_buffer({
    "[project]",
    "dependencies = [",
    "  \"badpkg; python_version >>> '3'\",",
    "  \"oddpkg; no_such_field == 'x'\",",
    "]",
  })

  diagnostics.render(bufnr, deps, { badpkg = "1.0.0", oddpkg = "1.0.0" }, { lockfile_missing = false })

  MiniTest.expect.equality(pydeps_diagnostics(bufnr), {
    { lnum = 2, message = "invalid marker", severity = severity.WARN },
    { lnum = 3, message = "unknown marker field", severity = severity.WARN },
  })
end

T["diagnostics stay quiet while the lockfile is loading"] = function()
  local diagnostics = require_diagnostics()
  local bufnr, deps = render_buffer({
    "[project]",
    "dependencies = [",
    '  "missingpkg>=2",',
    "  \"markerpkg; sys_platform == 'linux'\",",
    "]",
  })

  diagnostics.render(bufnr, deps, {}, { lockfile_missing = false, lockfile_loading = true })

  MiniTest.expect.equality(pydeps_diagnostics(bufnr), {})
end

T["diagnostics do not report packages missing from an absent or ambiguous lock"] = function()
  local diagnostics = require_diagnostics()
  local bufnr, deps = render_buffer({
    "[project]",
    "dependencies = [",
    '  "missingpkg>=2",',
    "  \"markerpkg; sys_platform == 'linux'\",",
    "]",
  })

  diagnostics.render(bufnr, deps, {}, { lockfile_missing = true })
  MiniTest.expect.equality(pydeps_diagnostics(bufnr), {})

  diagnostics.render(bufnr, deps, {}, {
    lockfile_missing = false,
    lockfile_ambiguous = { missingpkg = true, markerpkg = true },
  })
  MiniTest.expect.equality(pydeps_diagnostics(bufnr), {})

  -- Positive control: the same buffer is reported once the lock is known and unambiguous.
  diagnostics.render(bufnr, deps, {}, { lockfile_missing = false })
  MiniTest.expect.equality(pydeps_diagnostics(bufnr), {
    { lnum = 2, message = "declared in pyproject.toml but missing in uv.lock", severity = severity.WARN },
    { lnum = 3, message = "marker evaluates to true, but lockfile is missing the package", severity = severity.WARN },
  })
end

return T
