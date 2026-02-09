local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function create_project(lines, packages)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  helpers.create_uv_lock(dir, packages)
  vim.cmd("edit " .. path)
  helpers.setup_buffer(lines)
  return dir, path
end

local function cleanup(dir)
  if dir then
    vim.fn.delete(dir, "rf")
  end
end

T["update rejects @ reference"] = function()
  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["package @ git+https://github.com/user/repo.git"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("direct reference") then
      notified = true
    end
  end

  commands.update("package")

  vim.notify = original_notify
  MiniTest.expect.equality(notified, true)
  cleanup(dir)
end

T["update rejects https URL"] = function()
  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["package @ https://example.com/package.tar.gz"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("direct reference") then
      notified = true
    end
  end

  commands.update("package")

  vim.notify = original_notify
  MiniTest.expect.equality(notified, true)
  cleanup(dir)
end

T["update rejects file:// URL"] = function()
  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["package @ file:///path/to/package"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("direct reference") then
      notified = true
    end
  end

  commands.update("package")

  vim.notify = original_notify
  MiniTest.expect.equality(notified, true)
  cleanup(dir)
end

T["update rejects relative path"] = function()
  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["package @ ./local/package"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("direct reference") then
      notified = true
    end
  end

  commands.update("package")

  vim.notify = original_notify
  MiniTest.expect.equality(notified, true)
  cleanup(dir)
end

T["update allows version spec"] = function()
  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("direct reference") then
      notified = true
    end
  end

  commands.update("requests")

  vim.notify = original_notify
  MiniTest.expect.equality(notified, false)
  cleanup(dir)
end

T["update escapes pattern characters in version spec"] = function()
  local original_commands = package.loaded["pydeps.commands"]
  local original_pypi = package.loaded["pydeps.providers.pypi"]

  package.loaded["pydeps.commands"] = nil
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb({ info = { version = "2.0.0" } })
    end,
  }

  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["pkg==1.0+cpu"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  commands.update("pkg")

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(vim.tbl_contains(lines, 'dependencies = ["pkg==2.0.0"]'), true)
  cleanup(dir)

  package.loaded["pydeps.commands"] = original_commands
  package.loaded["pydeps.providers.pypi"] = original_pypi
end

return T
