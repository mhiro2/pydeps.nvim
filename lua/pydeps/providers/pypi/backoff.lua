local M = {}

---@class PyDepsBackoffEntry
---@field value any
---@field time number
---@field failed? boolean
---@field retry_after? number

---@param store table<string, PyDepsBackoffEntry>
---@param key string
---@param opts { now: number, ttl?: number }
---@return any, boolean
function M.get(store, key, opts)
  local entry = store[key]
  if not entry then
    return nil, false
  end
  if entry.failed and entry.retry_after and opts.now < entry.retry_after then
    return nil, true
  end
  if entry.failed and entry.retry_after and opts.now >= entry.retry_after then
    store[key] = nil
    return nil, false
  end
  if opts.ttl and (opts.now - entry.time) > opts.ttl then
    store[key] = nil
    return nil, false
  end
  return entry.value, false
end

---@param store table<string, PyDepsBackoffEntry>
---@param key string
---@param value any
---@param opts { now: number, failed?: boolean, backoff?: number }
---@return nil
function M.set(store, key, value, opts)
  local entry = {
    value = value,
    time = opts.now,
  }
  if opts.failed then
    entry.failed = true
    entry.retry_after = opts.now + (opts.backoff or 0)
  end
  store[key] = entry
end

return M
