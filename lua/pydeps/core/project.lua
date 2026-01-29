local M = {}

local uv = vim.uv

--- Per-buffer cache for find_root results.
--- `false` is the sentinel for "looked up but not found" (distinguishes from
--- "never looked up" which is `nil`).
---@type table<integer, string|false>
local buf_root_cache = {}

---@param bufnr integer
---@return string?
function M.find_root(bufnr)
  local cached = buf_root_cache[bufnr]
  if cached ~= nil then
    -- false means "previously looked up, not found"
    return cached or nil
  end

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local start = bufname ~= "" and vim.fs.dirname(bufname) or uv.cwd()
  local match = vim.fs.find({ "pyproject.toml", "uv.lock" }, { upward = true, path = start })[1]
  if not match then
    buf_root_cache[bufnr] = false
    return nil
  end

  local root = vim.fs.dirname(match)
  buf_root_cache[bufnr] = root
  return root
end

---Clear the cached root for a single buffer.
---@param bufnr integer
function M.clear_cache(bufnr)
  buf_root_cache[bufnr] = nil
end

---Clear the entire root cache (all buffers).
function M.clear_all_caches()
  buf_root_cache = {}
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
