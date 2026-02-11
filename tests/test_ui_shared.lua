local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["extract_marker returns marker section"] = function()
  local shared = require("pydeps.ui.shared")
  MiniTest.expect.equality(shared.extract_marker("requests>=2.0; python_version >= '3.11'"), "python_version >= '3.11'")
  MiniTest.expect.equality(shared.extract_marker("requests>=2.0"), nil)
  MiniTest.expect.equality(shared.extract_marker(nil), nil)
end

T["with_extra_env adds optional and dependency_group"] = function()
  local shared = require("pydeps.ui.shared")

  local base = { python_version = "3.11" }
  local optional_dep = { group = "optional:dev" }
  local group_dep = { group = "group:test" }

  local optional_env = shared.with_extra_env(base, optional_dep)
  MiniTest.expect.equality(optional_env.python_version, "3.11")
  MiniTest.expect.equality(optional_env.extra, "dev")

  local group_env = shared.with_extra_env(base, group_dep)
  MiniTest.expect.equality(group_env.python_version, "3.11")
  MiniTest.expect.equality(group_env.group, "test")
  MiniTest.expect.equality(group_env.dependency_group, "test")
end

T["is_version_in_releases checks release existence"] = function()
  local shared = require("pydeps.ui.shared")

  MiniTest.expect.equality(shared.is_version_in_releases(nil, "1.0.0"), true)
  MiniTest.expect.equality(shared.is_version_in_releases({ releases = nil }, "1.0.0"), true)
  MiniTest.expect.equality(shared.is_version_in_releases({ releases = { ["1.0.0"] = {} } }, "1.0.0"), true)
  MiniTest.expect.equality(shared.is_version_in_releases({ releases = { ["1.2.0"] = {} } }, "1.0.0"), false)
end

T["new_buffer_debouncer coalesces duplicate schedules"] = function()
  local shared = require("pydeps.ui.shared")
  local debouncer = shared.new_buffer_debouncer(10)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local count = 0

  debouncer.schedule(bufnr, function()
    count = count + 1
  end)
  debouncer.schedule(bufnr, function()
    count = count + 10
  end)

  local ok = vim.wait(200, function()
    return count > 0
  end)
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(count, 1)

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

T["new_buffer_debouncer clear cancels pending callback"] = function()
  local shared = require("pydeps.ui.shared")
  local debouncer = shared.new_buffer_debouncer(50)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local called = false

  debouncer.schedule(bufnr, function()
    called = true
  end)
  debouncer.clear(bufnr)

  vim.wait(120)
  MiniTest.expect.equality(called, false)

  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

return T
