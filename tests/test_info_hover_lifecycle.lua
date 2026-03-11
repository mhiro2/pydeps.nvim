local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local info_helpers = require("tests.info_helpers")

local T = helpers.create_test_set()

local function hover_count()
  local count = 0
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      count = count + 1
    end
  end
  return count
end

local function setup_info()
  info_helpers.stub_pypi()
  info_helpers.stub_cache()
  info_helpers.setup_project_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })
  return info_helpers.require_info()
end

---@param lines string[]
---@return string
local function create_named_project(lines)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = "toml"
  return dir
end

T["hover_lifecycle show replaces an existing hover"] = function()
  local info = setup_info()
  local dep = info_helpers.dep()

  info.show(dep, "1.0.0", {})
  vim.wait(50)
  info.show(dep, "1.0.0", {})
  vim.wait(50)

  MiniTest.expect.equality(hover_count(), 1)
  info.close_hover()
end

T["hover_lifecycle show_at_cursor replaces an existing hover"] = function()
  local info = setup_info()
  vim.api.nvim_win_set_cursor(0, { 2, 5 })

  info.show_at_cursor()
  vim.wait(50)
  info.show_at_cursor()
  vim.wait(50)

  MiniTest.expect.equality(hover_count(), 1)
  info.close_hover()
end

T["hover_lifecycle installs Enter and gT keymaps for show"] = function()
  local info = setup_info()
  local bufnr = vim.api.nvim_get_current_buf()

  info.show(info_helpers.dep(), "1.0.0", {})
  vim.wait(50)

  MiniTest.expect.equality(info_helpers.has_keymap(bufnr, "<CR>", "PyDeps: Show why this dependency is needed"), true)
  MiniTest.expect.equality(info_helpers.has_keymap(bufnr, "gT", "PyDeps: Show dependency tree"), true)
  info.close_hover()
end

T["hover_lifecycle removes temporary keymaps on close"] = function()
  local info = setup_info()
  local bufnr = vim.api.nvim_get_current_buf()

  info.show(info_helpers.dep(), "1.0.0", {})
  vim.wait(50)
  info.close_hover()

  MiniTest.expect.equality(info_helpers.has_keymap(bufnr, "<CR>", "PyDeps: Show why this dependency is needed"), false)
  MiniTest.expect.equality(info_helpers.has_keymap(bufnr, "gT", "PyDeps: Show dependency tree"), false)
end

T["hover_lifecycle restores pre-existing keymaps"] = function()
  local info = setup_info()
  local bufnr = vim.api.nvim_get_current_buf()

  vim.keymap.set("n", "<CR>", function() end, {
    buffer = bufnr,
    desc = "original-CR-mapping",
    script = true,
  })

  info.show(info_helpers.dep(), "1.0.0", {})
  vim.wait(50)
  info.close_hover()

  local restored = false
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if keymap.lhs == "<CR>" and keymap.desc == "original-CR-mapping" and keymap.script == 1 then
      restored = true
      break
    end
  end

  MiniTest.expect.equality(restored, true)
end

T["hover_lifecycle show_at_cursor installs keymaps"] = function()
  local info = setup_info()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 2, 5 })

  info.show_at_cursor()
  vim.wait(50)

  MiniTest.expect.equality(info_helpers.has_keymap(bufnr, "<CR>", "PyDeps: Show why this dependency is needed"), true)
  MiniTest.expect.equality(info_helpers.has_keymap(bufnr, "gT", "PyDeps: Show dependency tree"), true)
  info.close_hover()
end

T["hover_lifecycle keeps hover available when PyPI metadata is missing"] = function()
  info_helpers.stub_pypi_not_found()
  info_helpers.stub_cache()
  info_helpers.setup_project_buffer({
    "[project]",
    'dependencies = ["unknownpkg>=1.0"]',
  })

  local info = info_helpers.require_info()
  local dep = info_helpers.dep({
    name = "unknownpkg",
    col_end = 12,
  })

  info.show(dep, "1.0.0", {})
  vim.wait(50)

  MiniTest.expect.equality(hover_count(), 1)
  info.close_hover()
end

T["hover_lifecycle show_at_cursor keeps loading state while lockfile refreshes"] = function()
  info_helpers.stub_pypi_not_found()
  info_helpers.stub_cache({
    lock_data = {
      resolved = {},
      packages = {},
    },
    lockfile_loading = true,
  })

  local dir = create_named_project({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })
  local info = info_helpers.require_info()

  vim.api.nvim_win_set_cursor(0, { 2, 5 })
  info.show_at_cursor()
  vim.wait(50)

  local lines = info_helpers.hover_lines()
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*lock[^\n]*%(loading%.%.%.%)") ~= nil, true)
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*status[^\n]*Loading") ~= nil, true)

  info.close_hover()
  vim.fn.delete(dir, "rf")
end

T["hover_lifecycle exposes suspend and resume close state"] = function()
  local info = setup_info()

  MiniTest.expect.equality(info.should_close_hover(), true)
  info.suspend_close()
  MiniTest.expect.equality(info.should_close_hover(), false)
  info.resume_close()
  MiniTest.expect.equality(info.should_close_hover(), true)
end

return T
