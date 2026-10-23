local M = {}

---Replace a dependency string in place, keeping its quote style and the rest of the line.
---@param bufnr integer
---@param dep PyDepsDependency
---@param spec string
---@return boolean
function M.replace_dependency(bufnr, dep, spec)
  if not dep or not dep.line then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, dep.line - 1, dep.line, false)[1] or ""
  local quote = line:sub(dep.col_start, dep.col_start)
  if quote ~= '"' and quote ~= "'" then
    quote = '"'
  end
  local new_text = quote .. spec .. quote
  vim.api.nvim_buf_set_text(bufnr, dep.line - 1, dep.col_start - 1, dep.line - 1, dep.col_end, { new_text })
  return true
end

return M
