local M = {}

-- Track if we've notified about missing tree-sitter
local _notified_unavailable = false

-- Try to load Tree-sitter parser
local ok_ts, ts_toml = pcall(require, "pydeps.treesitter.toml")
if not ok_ts then
  ts_toml = nil
end

---@param path? string
---@param lines? string[]
---@param bufnr? integer
---@return PyDepsDependency[]
function M.parse(path, lines, bufnr)
  if not ts_toml or not ts_toml.is_available() then
    if not _notified_unavailable then
      vim.notify("pydeps: nvim-treesitter toml parser is required", vim.log.levels.ERROR)
      _notified_unavailable = true
    end
    return {}
  end

  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return ts_toml.parse_buffer(bufnr)
  end

  if lines then
    local tmp = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(tmp, 0, -1, false, lines)
    vim.bo[tmp].filetype = "toml"
    local deps = ts_toml.parse_buffer(tmp)
    vim.api.nvim_buf_delete(tmp, { force = true })
    return deps
  end

  if path and vim.fn.filereadable(path) == 1 then
    local tmp = vim.api.nvim_create_buf(false, true)
    local content = vim.fn.readfile(path)
    vim.api.nvim_buf_set_lines(tmp, 0, -1, false, content)
    vim.bo[tmp].filetype = "toml"
    local deps = ts_toml.parse_buffer(tmp)
    vim.api.nvim_buf_delete(tmp, { force = true })
    return deps
  end

  return {}
end

return M
