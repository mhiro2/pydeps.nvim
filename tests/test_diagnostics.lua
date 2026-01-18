local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function stub_env()
  package.loaded["pydeps.core.env"] = {
    get = function()
      return {
        python_version = "3.11",
        sys_platform = "linux",
        os_name = "posix",
      }
    end,
  }
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

  package.loaded["pydeps.providers.pypi"] = {
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
  }
end

T["diagnostics for marker, lock diff, pinned, yanked"] = function()
  stub_env()
  stub_pypi()
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
  local items = vim.diagnostic.get(bufnr)
  local messages = {}
  for _, item in ipairs(items) do
    if item.source == "pydeps" then
      messages[item.message] = true
    end
  end

  MiniTest.expect.equality(messages["marker evaluates to false, but lockfile has a resolved version"] ~= nil, true)
  MiniTest.expect.equality(messages["lock mismatch: pinned 1.0.0 but resolved 1.1.0"] ~= nil, true)
  MiniTest.expect.equality(messages["declared in pyproject.toml but missing in uv.lock"] ~= nil, true)
  MiniTest.expect.equality(messages["resolved version is yanked on PyPI"] ~= nil, true)
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

  package.loaded["pydeps.providers.pypi"] = {
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
  }
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
  local items = vim.diagnostic.get(bufnr)
  local messages = {}
  for _, item in ipairs(items) do
    if item.source == "pydeps" then
      messages[item.message] = true
    end
  end

  MiniTest.expect.equality(messages["pinned version 1.1.0 not found on public PyPI"] ~= nil, true)
end

T["diagnostic range uses exclusive end_col"] = function()
  stub_env()
  package.loaded["pydeps.providers.pypi"] = {
    get_cached = function()
      return { releases = {} }
    end,
    get = function(_, cb)
      cb({ releases = {} })
    end,
    is_yanked = function()
      return false
    end,
  }
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

return T
