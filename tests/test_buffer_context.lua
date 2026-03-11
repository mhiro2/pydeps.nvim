local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

---@param lines string[]
---@return string
local function create_project(lines)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  helpers.create_uv_lock(dir)
  vim.cmd.edit(path)
  vim.bo[0].filetype = "toml"
  return dir
end

---@param dir string
local function cleanup(dir)
  vim.fn.delete(dir, "rf")
end

---@param path string
---@return integer
local function edit_file(path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

T["buffer_context detects pyproject buffers and returns parsed dependencies"] = function()
  package.loaded["pydeps.core.buffer_context"] = nil
  local buffer_context = require("pydeps.core.buffer_context")

  local dir = create_project({
    "[project]",
    "dependencies = [",
    '  "requests>=2.31",',
    '  "rich>=13",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  local deps = buffer_context.get_deps(bufnr)

  MiniTest.expect.equality(buffer_context.current_buf(), bufnr)
  MiniTest.expect.equality(buffer_context.is_pyproject_buf(bufnr), true)
  MiniTest.expect.equality(#deps, 2)
  MiniTest.expect.equality(deps[1].name, "requests")
  MiniTest.expect.equality(deps[2].name, "rich")

  cleanup(dir)
end

T["buffer_context finds project root and dependency under cursor"] = function()
  package.loaded["pydeps.core.buffer_context"] = nil
  local buffer_context = require("pydeps.core.buffer_context")

  local dir = create_project({
    "[project]",
    "dependencies = [",
    '  "requests>=2.31",',
    '  "rich>=13",',
    "]",
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_cursor(0, { 3, 5 })

  local dep = buffer_context.dep_under_cursor_in_buf(bufnr)
  local root = buffer_context.find_root(bufnr)

  MiniTest.expect.equality(vim.uv.fs_realpath(root), vim.uv.fs_realpath(dir))
  MiniTest.expect.equality(dep ~= nil, true)
  MiniTest.expect.equality(dep.name, "requests")

  cleanup(dir)
end

T["buffer_context returns project dependencies from non-pyproject buffers"] = function()
  package.loaded["pydeps.core.buffer_context"] = nil
  local buffer_context = require("pydeps.core.buffer_context")

  local dir = create_project({
    "[project]",
    "dependencies = [",
    '  "requests>=2.31",',
    '  "rich>=13",',
    "]",
  })
  local script_path = dir .. "/app.py"
  vim.fn.writefile({ "print('hello')" }, script_path)

  local bufnr = edit_file(script_path)
  local deps = buffer_context.get_project_deps(bufnr)

  MiniTest.expect.equality(buffer_context.is_pyproject_buf(bufnr), false)
  MiniTest.expect.equality(#deps, 2)
  MiniTest.expect.equality(deps[1].name, "requests")
  MiniTest.expect.equality(deps[2].name, "rich")

  cleanup(dir)
end

return T
