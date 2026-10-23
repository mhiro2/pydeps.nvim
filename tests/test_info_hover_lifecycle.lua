local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local info_helpers = require("tests.info_helpers")

local T = helpers.create_test_set()

---@return integer[]
local function float_wins()
  local wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      table.insert(wins, win)
    end
  end
  return wins
end

---@param info table
---@param show fun()
local function expect_hover_replaced(info, show)
  show()
  local first_win = info.get_hover_win()
  MiniTest.expect.no_equality(first_win, nil)
  local first_buf = vim.api.nvim_win_get_buf(first_win)

  show()
  local second_win = info.get_hover_win()
  MiniTest.expect.no_equality(second_win, nil)
  MiniTest.expect.no_equality(second_win, first_win)
  MiniTest.expect.equality(vim.api.nvim_win_is_valid(first_win), false)
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(first_buf), false)
  MiniTest.expect.equality(float_wins(), { second_win })
  MiniTest.expect.equality(info_helpers.hover_lines()[1]:match("testpkg$") ~= nil, true)

  info.close_hover()
  MiniTest.expect.equality(float_wins(), {})
  MiniTest.expect.equality(#vim.api.nvim_list_wins(), 1)
end

---@param bufnr integer
---@param lhs string
---@return table?
local function get_keymap(bufnr, lhs)
  local normalized = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if vim.api.nvim_replace_termcodes(keymap.lhs, true, true, true) == normalized then
      return keymap
    end
  end
  return nil
end

---@return { provenance: string[], tree: table[] }
local function stub_commands()
  local calls = { provenance = {}, tree = {} }
  helpers.stub_module("pydeps.commands", {
    provenance = function(name)
      table.insert(calls.provenance, name)
    end,
    tree = function(...)
      table.insert(calls.tree, { ... })
    end,
  })
  return calls
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

  expect_hover_replaced(info, function()
    info.show(dep, "1.0.0", {})
  end)
end

T["hover_lifecycle show_at_cursor replaces an existing hover"] = function()
  local info = setup_info()
  vim.api.nvim_win_set_cursor(0, { 2, 5 })

  expect_hover_replaced(info, info.show_at_cursor)
end

T["hover_lifecycle installs Enter and gT keymaps for show"] = function()
  local info = setup_info()
  local bufnr = vim.api.nvim_get_current_buf()

  info.show(info_helpers.dep(), "1.0.0", {})

  MiniTest.expect.equality(info_helpers.has_keymap(bufnr, "<CR>", "PyDeps: Show why this dependency is needed"), true)
  MiniTest.expect.equality(info_helpers.has_keymap(bufnr, "gT", "PyDeps: Show dependency tree"), true)
  info.close_hover()
end

T["hover_lifecycle Enter keeps the hover and asks why the shown package is needed"] = function()
  local info = setup_info()
  local calls = stub_commands()
  local bufnr = vim.api.nvim_get_current_buf()

  info.show(info_helpers.dep({ name = "otherpkg" }), "1.0.0", {})
  get_keymap(bufnr, "<CR>").callback()

  MiniTest.expect.equality(calls.provenance, { "otherpkg" })
  MiniTest.expect.equality(calls.tree, {})
  MiniTest.expect.no_equality(info.get_hover_win(), nil)
  info.close_hover()
end

T["hover_lifecycle gT closes the hover before opening the tree"] = function()
  local info = setup_info()
  local calls = stub_commands()
  local bufnr = vim.api.nvim_get_current_buf()

  info.show(info_helpers.dep(), "1.0.0", {})
  get_keymap(bufnr, "gT").callback()

  MiniTest.expect.equality(calls.tree, { { "", false, { mode = "float", anchor = "cursor" } } })
  MiniTest.expect.equality(calls.provenance, {})
  MiniTest.expect.equality(info.get_hover_win(), nil)
  MiniTest.expect.equality(get_keymap(bufnr, "gT"), nil)
end

T["hover_lifecycle removes temporary keymaps on close"] = function()
  local info = setup_info()
  local bufnr = vim.api.nvim_get_current_buf()

  info.show(info_helpers.dep(), "1.0.0", {})
  info.close_hover()

  MiniTest.expect.equality(info_helpers.has_keymap(bufnr, "<CR>", "PyDeps: Show why this dependency is needed"), false)
  MiniTest.expect.equality(info_helpers.has_keymap(bufnr, "gT", "PyDeps: Show dependency tree"), false)
end

T["hover_lifecycle restores pre-existing keymaps"] = function()
  local info = setup_info()
  local bufnr = vim.api.nvim_get_current_buf()

  local original_cr = function() end
  vim.keymap.set("n", "<CR>", original_cr, {
    buffer = bufnr,
    desc = "original-CR-mapping",
    script = true,
  })
  vim.keymap.set("n", "gT", "v:lua.tostring(1)", {
    buffer = bufnr,
    desc = "original-gT-mapping",
    expr = true,
    remap = true,
  })

  info.show(info_helpers.dep(), "1.0.0", {})
  MiniTest.expect.equality(get_keymap(bufnr, "<CR>").desc, "PyDeps: Show why this dependency is needed")
  info.close_hover()

  local cr = get_keymap(bufnr, "<CR>")
  MiniTest.expect.equality(cr.desc, "original-CR-mapping")
  MiniTest.expect.equality(cr.script, 1)
  MiniTest.expect.equality(cr.callback, original_cr)

  local gt = get_keymap(bufnr, "gT")
  MiniTest.expect.equality(gt.desc, "original-gT-mapping")
  MiniTest.expect.equality(gt.rhs, "v:lua.tostring(1)")
  MiniTest.expect.equality(gt.expr, 1)
  MiniTest.expect.equality(gt.noremap, 0)
end

T["hover_lifecycle show_at_cursor installs keymaps"] = function()
  local info = setup_info()
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 2, 5 })

  info.show_at_cursor()

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

  MiniTest.expect.no_equality(info.get_hover_win(), nil)
  local lines = table.concat(info_helpers.hover_lines(), "\n")
  MiniTest.expect.equality(lines:match("[^\n]*latest[^\n]*%(not found%)") ~= nil, true)
  MiniTest.expect.equality(lines:match("[^\n]*pypi[^\n]*not found on public PyPI") ~= nil, true)
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

  local lines = info_helpers.hover_lines()
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*lock[^\n]*%(loading%.%.%.%)") ~= nil, true)
  MiniTest.expect.equality(table.concat(lines, "\n"):match("[^\n]*status[^\n]*Loading") ~= nil, true)

  info.close_hover()
  vim.fn.delete(dir, "rf")
end

T["hover_lifecycle show_at_cursor shows the locked version from lock package records"] = function()
  info_helpers.stub_pypi()
  info_helpers.stub_cache({
    lock_data = info_helpers.lock_data(
      vim.list_extend({ "version = 1", "" }, info_helpers.lock_package_lines("testpkg", "1.4.2"))
    ),
  })
  local dir = create_named_project({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })
  local info = info_helpers.require_info()

  vim.api.nvim_win_set_cursor(0, { 2, 20 })
  info.show_at_cursor()

  local lock_line = table.concat(info_helpers.hover_lines(), "\n"):match("[^\n]*lock[^\n]*")
  MiniTest.expect.equality(lock_line:match("1%.4%.2") ~= nil, true)
  info.close_hover()
  vim.fn.delete(dir, "rf")
end

T["hover_lifecycle discards PyPI metadata that arrives after close"] = function()
  local requests = info_helpers.stub_pypi_deferred()
  info_helpers.stub_cache()
  info_helpers.setup_project_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })
  local info = info_helpers.require_info()

  info.show(info_helpers.dep(), "1.0.0", {})
  local hover_buf = info_helpers.find_hover_buf()
  info.close_hover()

  MiniTest.expect.equality(#requests, 1)
  MiniTest.expect.no_error(function()
    requests[1].resolve({ info = { version = "9.9.9", summary = "Late summary" }, releases = {} })
  end)
  MiniTest.expect.equality(info.get_hover_win(), nil)
  MiniTest.expect.equality(float_wins(), {})
  MiniTest.expect.equality(vim.api.nvim_buf_is_valid(hover_buf), false)
end

T["hover_lifecycle ignores metadata for a package it no longer shows"] = function()
  local requests = info_helpers.stub_pypi_deferred()
  info_helpers.stub_cache()
  info_helpers.setup_project_buffer({
    "[project]",
    'dependencies = ["alpha>=1.0", "beta>=1.0"]',
  })
  local info = info_helpers.require_info()

  info.show(info_helpers.dep({ name = "alpha" }), "1.0.0", {})
  info.show(info_helpers.dep({ name = "beta" }), "1.0.0", {})
  MiniTest.expect.equality(#requests, 2)

  requests[1].resolve({ info = { version = "1.0.0", summary = "Alpha summary" }, releases = {} })
  local lines = info_helpers.hover_lines()
  MiniTest.expect.equality(lines[1]:match("beta$") ~= nil, true)
  MiniTest.expect.equality(vim.tbl_contains(lines, "Alpha summary"), false)

  requests[2].resolve({ info = { version = "1.0.0", summary = "Beta summary" }, releases = {} })
  MiniTest.expect.equality(vim.tbl_contains(info_helpers.hover_lines(), "Beta summary"), true)
  info.close_hover()
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
