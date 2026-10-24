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
  local new_text
  -- Keep a literal string when the spec still fits one; otherwise write a
  -- basic string with the characters TOML requires escaped.
  if line:sub(dep.col_start, dep.col_start) == "'" and not spec:find("[%c']") then
    new_text = "'" .. spec .. "'"
  else
    local escaped = spec:gsub('[\\"]', "\\%0"):gsub("%c", function(char)
      return string.format("\\u%04X", char:byte())
    end)
    new_text = '"' .. escaped .. '"'
  end
  vim.api.nvim_buf_set_text(bufnr, dep.line - 1, dep.col_start - 1, dep.line - 1, dep.col_end, { new_text })
  return true
end

return M
