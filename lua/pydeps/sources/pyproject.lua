local M = {}

-- Track if we've notified about missing tree-sitter
local _notified_unavailable = false

-- Try to load Tree-sitter parser
local ok_ts, ts_toml = pcall(require, "pydeps.treesitter.toml")
if not ok_ts then
  ts_toml = nil
end

---Run `fn` on the pyproject buffer, or on a scratch copy of the file when no buffer is given.
---@generic T
---@param path? string
---@param bufnr? integer
---@param fn fun(bufnr: integer): T
---@param empty T Result when neither a buffer nor a readable file is available
---@return T
local function with_toml_buffer(path, bufnr, fn, empty)
  if not ts_toml or not ts_toml.is_available() then
    if not _notified_unavailable then
      vim.notify("pydeps: Tree-sitter TOML parser is required", vim.log.levels.ERROR)
      _notified_unavailable = true
    end
    return empty
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return fn(bufnr)
  end

  if path and vim.fn.filereadable(path) == 1 then
    local tmp = vim.api.nvim_create_buf(false, true)
    local content = vim.fn.readfile(path)
    vim.api.nvim_buf_set_lines(tmp, 0, -1, false, content)
    vim.bo[tmp].filetype = "toml"
    local result = fn(tmp)
    vim.api.nvim_buf_delete(tmp, { force = true })
    return result
  end

  return empty
end

---@param path? string
---@param bufnr? integer
---@return PyDepsDependency[]
function M.parse(path, bufnr)
  return with_toml_buffer(path, bufnr, function(buf)
    return ts_toml.parse_buffer(buf)
  end, {})
end

---@param path? string
---@param bufnr? integer
---@return PyDepsSelectableSections
function M.parse_sections(path, bufnr)
  return with_toml_buffer(path, bufnr, function(buf)
    return ts_toml.parse_sections(buf)
  end, { extras = {}, groups = {}, includes = {} })
end

return M
