local M = {}

local uv = vim.uv

---@param bufnr integer
---@return string?
function M.find_root(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local start = bufname ~= "" and vim.fs.dirname(bufname) or uv.cwd()
  local match = vim.fs.find({ "pyproject.toml", "uv.lock" }, { upward = true, path = start })[1]
  if not match then
    return nil
  end
  return vim.fs.dirname(match)
end

---@param root? string
---@param filename string
---@return string?
function M.find_file(root, filename)
  if not root then
    return nil
  end
  local candidate = vim.fs.joinpath(root, filename)
  if vim.fn.filereadable(candidate) == 1 then
    return candidate
  end
  return nil
end

return M
