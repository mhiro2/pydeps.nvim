local util = require("pydeps.util")

local M = {}

---@return table
local function get_cache()
  return require("pydeps.core.cache")
end

---@return table
local function get_project()
  return require("pydeps.core.project")
end

---@param bufnr? integer
---@return integer
function M.current_buf(bufnr)
  return bufnr or vim.api.nvim_get_current_buf()
end

---@param bufnr integer
---@return boolean
function M.is_pyproject_buf(bufnr)
  return util.is_pyproject(vim.api.nvim_buf_get_name(bufnr))
end

---@param bufnr integer
---@return PyDepsDependency[]
function M.get_deps(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  return get_cache().get_pyproject(bufnr)
end

---@param deps PyDepsDependency[]
---@return PyDepsDependency?
function M.dep_under_cursor(deps)
  return util.dep_under_cursor(deps)
end

---@param bufnr integer
---@return PyDepsDependency?
function M.dep_under_cursor_in_buf(bufnr)
  if not M.is_pyproject_buf(bufnr) then
    return nil
  end
  return M.dep_under_cursor(M.get_deps(bufnr))
end

---@param bufnr integer
---@return string?
function M.find_root(bufnr)
  return get_project().find_root(bufnr)
end

return M
