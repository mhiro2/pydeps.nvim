local lockfile = require("pydeps.sources.lockfile")
local project = require("pydeps.core.project")
local pyproject = require("pydeps.sources.pyproject")
local util = require("pydeps.util")
local uv = vim.uv

local M = {}

---@class PyDepsPyprojectCacheEntry
---@field tick integer
---@field deps PyDepsDependency[]

---@class PyDepsLockfileCacheEntry
---@field mtime integer
---@field size integer
---@field data PyDepsLockfileData

---@type table<integer, PyDepsPyprojectCacheEntry>
local buf_cache = {}

---@type table<string, PyDepsLockfileCacheEntry>
local lock_cache = {}

---@type table<string, PyDepsResolved>
local lock_snapshots = {}

---@type table<string, boolean>
local lock_pending = {}

---@param stat? table
---@return integer?, integer?
local function stat_key(stat)
  if not stat or not stat.mtime or not stat.mtime.sec then
    return nil, nil
  end
  local nsec = stat.mtime.nsec or 0
  local mtime = (stat.mtime.sec * 1000000000) + nsec
  return mtime, stat.size
end

---@param mtime1? integer
---@param size1? integer
---@param mtime2? integer
---@param size2? integer
---@return boolean
local function stat_matches(mtime1, size1, mtime2, size2)
  return mtime1 and mtime2 and mtime1 == mtime2 and size1 and size2 and size1 == size2
end

---@param root string
---@param path string
local function emit_lockfile_update(root, path)
  if not root or root == "" then
    return
  end
  util.emit_user_autocmd("PyDepsLockfileUpdated", { root = root, path = path })
end

---@param root string
---@param path string
local function schedule_lockfile_parse(root, path)
  if lock_pending[path] then
    return
  end
  lock_pending[path] = true
  lockfile.parse_async(path, function(data)
    lock_pending[path] = nil
    if data then
      data.graph = lockfile.build_graph(data.packages)
      local stat = uv.fs_stat(path)
      local mtime, size = stat_key(stat)
      lock_cache[path] = { mtime = mtime or 0, size = size or 0, data = data }
    end
    emit_lockfile_update(root, path)
  end)
end

---@param bufnr integer
---@return PyDepsDependency[]
function M.get_pyproject(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = buf_cache[bufnr]

  -- Return cached data if buffer hasn't changed
  if cached and cached.tick == tick then
    return cached.deps
  end

  -- Parse and cache fresh data
  local path = vim.api.nvim_buf_get_name(bufnr)
  local deps = pyproject.parse(path, nil, bufnr)
  buf_cache[bufnr] = { tick = tick, deps = deps }

  return deps
end

---@param bufnr integer
function M.invalidate_pyproject(bufnr)
  buf_cache[bufnr] = nil
end

---@param root string
---@return PyDepsLockfileData, boolean
---@param root string
---@param opts? { sync?: boolean }
---@return PyDepsLockfileData, boolean, boolean
function M.get_lockfile(root, opts)
  local path = project.find_file(root, "uv.lock")
  if not path then
    return { resolved = {}, packages = {}, graph = {} }, true, false
  end

  local stat = uv.fs_stat(path)
  if not stat then
    return { resolved = {}, packages = {}, graph = {} }, true, false
  end
  local mtime, size = stat_key(stat)
  local cached = lock_cache[path]

  -- Return cached data if file hasn't changed
  if cached and stat_matches(cached.mtime, cached.size, mtime, size) then
    return cached.data, false, false
  end

  if opts and opts.sync then
    local data = lockfile.parse_full(path)
    data.graph = lockfile.build_graph(data.packages)
    lock_cache[path] = { mtime = mtime or 0, size = size or 0, data = data }
    return data, false, false
  end

  -- Parse and cache fresh data asynchronously
  schedule_lockfile_parse(root, path)

  if cached then
    return cached.data, false, true
  end

  return { resolved = {}, packages = {}, graph = {} }, false, true
end

---@param root string
function M.invalidate_lockfile(root)
  local path = project.find_file(root, "uv.lock")
  if path then
    lock_cache[path] = nil
    lock_pending[path] = nil
  end
end

---@param root string
---@return PyDepsResolved?
function M.get_lock_snapshot(root)
  return lock_snapshots[root]
end

---@param root string
---@param resolved PyDepsResolved
function M.set_lock_snapshot(root, resolved)
  lock_snapshots[root] = resolved
end

return M
