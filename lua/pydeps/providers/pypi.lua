---@class PyDepsPyPIMeta
---@field info? PyDepsPyPIInfo
---@field releases? table<string, PyDepsPyPIRelease[]>

---@class PyDepsPyPIInfo
---@field summary? string
---@field home_page? string
---@field project_urls? table<string, string>
---@field version? string
---@field provides_extra? string[]
---@field requires_dist? string[]

---@class PyDepsPyPIRelease
---@field yanked? boolean
---@field upload_time_iso_8601? string

---@class PyDepsPyPICacheEntry
---@field data PyDepsPyPIMeta?
---@field time number
---@field failed? boolean
---@field retry_after? number

local config = require("pydeps.config")
local util = require("pydeps.util")

local M = {}

local uv = vim.uv

-- Request timeout in milliseconds
local REQUEST_TIMEOUT = 10000
-- Search failure backoff in seconds
local SEARCH_FAILURE_BACKOFF = 60

---@type table<string, PyDepsPyPICacheEntry>
local cache = {}
---@type table<string, fun(data: PyDepsPyPIMeta?)[]
local pending = {}
---@type table<string, uv_timer_t>
local timers = {}
---@type boolean
local notified = false

---@class PyDepsPyPISearchCacheEntry
---@field results string[]
---@field time number
---@field failed? boolean
---@field retry_after? number

---@type table<string, PyDepsPyPISearchCacheEntry>
local search_cache = {}
---@type table<string, boolean>
local search_loading = {}
---@type table<string, uv_timer_t>
local search_timers = {}
---@type table<string, fun(results: string[])[]>
local search_pending = {}

---@param name? string
---@return string
local function normalize(name)
  return (name or ""):lower()
end

---@param name string
---@return boolean
local function is_valid_package_name(name)
  return name:match("^[a-z0-9][a-z0-9%._-]*$") ~= nil
end

---@param name string
---@return nil
local function emit_update(name)
  if not name or name == "" then
    return
  end
  util.emit_user_autocmd("PyDepsPyPIUpdated", { name = normalize(name) })
end

---@param name string
---@return PyDepsPyPIMeta?, boolean
local function cached_entry(name)
  local entry = cache[normalize(name)]
  if not entry then
    return nil, false
  end
  -- If failed entry has retry_after in the future, it's in backoff period
  if entry.failed and entry.retry_after and util.now() < entry.retry_after then
    return nil, true -- Indicates that it's in backoff period
  end
  -- Check TTL for successful entries
  if not entry.failed and (util.now() - entry.time) > (config.options.pypi_cache_ttl or 3600) then
    cache[normalize(name)] = nil
    return nil, false
  end
  -- If retry_after has passed for failed entry, retry is allowed
  if entry.failed and entry.retry_after and util.now() >= entry.retry_after then
    cache[normalize(name)] = nil
    return nil, false
  end
  return entry.data, false
end

---@param name string
---@param data? PyDepsPyPIMeta
---@param failed? boolean
---@return nil
local function set_cache(name, data, failed)
  local entry = { data = data, time = util.now() }
  if failed then
    entry.failed = true
    entry.retry_after = util.now() + 60 -- 60 second backoff
  end
  cache[normalize(name)] = entry
end

---@param msg string
---@return nil
local function notify_once(msg)
  if notified then
    return
  end
  notified = true
  vim.notify(msg, vim.log.levels.WARN)
end

---@return string?
local function resolve_python()
  if vim.fn.executable("python3") == 1 then
    return "python3"
  end
  if vim.fn.executable("python") == 1 then
    return "python"
  end
  return nil
end

---@param payload string
---@return table?
local function decode_json(payload)
  local ok, decoded = pcall(vim.json.decode, payload)
  if ok then
    return decoded
  end
  vim.notify(
    "pydeps: Failed to fetch package info from PyPI. Please check your internet connection.",
    vim.log.levels.WARN
  )
  return nil
end

---@param cmd string[]
---@param name string
---@return nil
local function run_request(cmd, name)
  local normalized = normalize(name)
  local stdout = {}
  local stderr = {}
  local completed = false

  ---@param decoded? table
  ---@param had_error boolean
  local function finish(decoded, had_error)
    if completed then
      return
    end
    completed = true

    util.safe_close_timer(timers[normalized])
    timers[normalized] = nil

    if decoded then
      set_cache(name, decoded, false)
    elseif had_error then
      -- Cache the failure and apply backoff
      set_cache(name, nil, true)
    end
    local callbacks = pending[normalized] or {}
    pending[normalized] = nil
    vim.schedule(function()
      for _, cb in ipairs(callbacks) do
        cb(decoded)
      end
      emit_update(name)
    end)
  end

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr, data)
      end
    end,
    on_exit = function(_, code, _)
      local payload = table.concat(stdout, "\n")
      local err = table.concat(stderr, "\n")
      local decoded = nil
      if payload ~= "" then
        decoded = decode_json(payload)
      end
      finish(decoded, code ~= 0 or err ~= "")
    end,
  })

  -- Set up timeout timer
  if job_id > 0 then
    timers[normalized] = uv.new_timer()
    timers[normalized]:start(REQUEST_TIMEOUT, 0, function()
      if completed then
        return
      end

      -- Kill the job (must be scheduled to avoid fast event context error)
      vim.schedule(function()
        vim.fn.jobstop(job_id)
      end)

      -- Handle timeout as failure
      finish(nil, true)
    end)
  else
    -- jobstart failed
    vim.notify(
      string.format("pydeps: Failed to fetch package '%s' from PyPI. Please check your internet connection.", name),
      vim.log.levels.ERROR
    )
    finish(nil, true)
  end
end

---@param name string
---@return string?
local function request_url(name)
  if not is_valid_package_name(name) then
    return nil
  end
  local base = config.options.pypi_url or "https://pypi.org/pypi"
  return string.format("%s/%s/json", base, name)
end

---@return number
local function pypi_cache_ttl()
  return config.options.pypi_cache_ttl or 3600
end

---@param value string
---@return string
local function url_encode(value)
  return (value:gsub("[^%w%-%._~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

---@return string
local function pypi_base_url()
  local configured = config.options.pypi_url or "https://pypi.org/pypi"
  local base = configured:gsub("/pypi/?$", "")
  base = base:gsub("/+$", "")
  if base == "" then
    return "https://pypi.org"
  end
  return base
end

---@param query string
---@return string?
local function search_url(query)
  if not is_valid_package_name(query) then
    return nil
  end
  return string.format("%s/search/?q=%s", pypi_base_url(), url_encode(query))
end

---@param query string
---@return string[]?, boolean
local function cached_search_entry(query)
  local entry = search_cache[query]
  if not entry then
    return nil, false
  end
  if entry.failed and entry.retry_after and util.now() < entry.retry_after then
    return nil, true
  end
  if entry.failed and entry.retry_after and util.now() >= entry.retry_after then
    search_cache[query] = nil
    return nil, false
  end
  if (util.now() - entry.time) > pypi_cache_ttl() then
    search_cache[query] = nil
    return nil, false
  end
  return entry.results, false
end

---@param query string
---@param results string[]
---@param failed? boolean
---@return nil
local function set_search_cache(query, results, failed)
  local now = util.now()
  search_cache[query] = {
    results = results,
    time = now,
    failed = failed == true or nil,
    retry_after = failed and (now + SEARCH_FAILURE_BACKOFF) or nil,
  }
end

---@param query string
---@param results string[]
---@return nil
local function flush_search_callbacks(query, results)
  local callbacks = search_pending[query] or {}
  search_pending[query] = nil
  if #callbacks == 0 then
    return
  end
  vim.schedule(function()
    for _, callback in ipairs(callbacks) do
      callback(results)
    end
  end)
end

---@param names string[]
---@param query string
---@param limit integer
---@return string[]
local function filter_prefix(names, query, limit)
  local results = {}
  local prefix = normalize(query)

  for _, name in ipairs(names) do
    if normalize(name):find(prefix, 1, true) == 1 then
      table.insert(results, name)
      if #results >= limit then
        break
      end
    end
  end

  return results
end

---@param names string[]
---@param seen table<string, boolean>
---@param name string
---@return nil
local function add_search_name(names, seen, name)
  local normalized = normalize(util.trim(name))
  if normalized == "" then
    return
  end
  if not is_valid_package_name(normalized) or seen[normalized] then
    return
  end
  seen[normalized] = true
  table.insert(names, normalized)
end

---@param payload string
---@return string[]
local function parse_search_payload(payload)
  local names = {}
  local seen = {}

  for name in payload:gmatch("package%-snippet__name[^>]*>%s*([^<]+)%s*<") do
    add_search_name(names, seen, name)
  end

  if #names == 0 then
    for name in payload:gmatch("/project/([%w%._%-]+)/") do
      add_search_name(names, seen, name)
    end
  end

  return names
end

---@param cmd string[]
---@param query string
---@return nil
local function run_search_request(cmd, query)
  local normalized_query = normalize(query)
  local stdout = {}
  local stderr = {}
  local completed = false

  ---@param results string[]
  ---@param failed? boolean
  ---@return nil
  local function finish(results, failed)
    if completed then
      return
    end
    completed = true
    util.safe_close_timer(search_timers[normalized_query])
    search_timers[normalized_query] = nil
    search_loading[normalized_query] = nil
    set_search_cache(normalized_query, results, failed)
    flush_search_callbacks(normalized_query, results)
  end

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr, data)
      end
    end,
    on_exit = function(_, code)
      local err = util.trim(table.concat(stderr, "\n"))
      if code ~= 0 or err ~= "" then
        finish({}, true)
        return
      end

      local payload = table.concat(stdout, "\n")
      if payload == "" then
        finish({}, true)
        return
      end

      finish(parse_search_payload(payload), false)
    end,
  })

  if job_id <= 0 then
    search_loading[normalized_query] = nil
    set_search_cache(normalized_query, {}, true)
    flush_search_callbacks(normalized_query, {})
    vim.notify("pydeps: Failed to execute PyPI search command.", vim.log.levels.ERROR)
    return
  end

  search_timers[normalized_query] = uv.new_timer()
  search_timers[normalized_query]:start(REQUEST_TIMEOUT, 0, function()
    if completed then
      return
    end
    vim.schedule(function()
      vim.fn.jobstop(job_id)
    end)
    finish({}, true)
  end)
end

---@param query string
---@return nil
local function refresh_search_cache(query)
  local normalized_query = normalize(query)
  if search_loading[normalized_query] then
    return
  end
  search_loading[normalized_query] = true

  local url = search_url(normalized_query)
  if not url then
    search_loading[normalized_query] = nil
    set_search_cache(normalized_query, {}, false)
    flush_search_callbacks(normalized_query, {})
    return
  end

  if vim.fn.executable("curl") == 1 then
    run_search_request({ "curl", "-fsSL", url }, normalized_query)
    return
  end

  local python = resolve_python()
  if python then
    local script = table.concat({
      "import sys,urllib.request",
      "with urllib.request.urlopen(sys.argv[1]) as r:",
      "  data=r.read().decode('utf-8', errors='ignore')",
      "print(data)",
    }, "\n")
    run_search_request({ python, "-c", script, url }, normalized_query)
    return
  end

  search_loading[normalized_query] = nil
  notify_once("pydeps: curl/python not found; PyPI search disabled")
  set_search_cache(normalized_query, {}, true)
  flush_search_callbacks(normalized_query, {})
end

---@param name string
---@return PyDepsPyPIMeta?
function M.get_cached(name)
  local data, _ = cached_entry(name)
  return data
end

---@param name string
---@param cb? fun(data: PyDepsPyPIMeta?)
---@return nil
function M.get(name, cb)
  local normalized = normalize(name)
  if normalized == "" then
    if cb then
      cb(nil)
    end
    return
  end
  if not is_valid_package_name(normalized) then
    if cb then
      cb(nil)
    end
    return
  end
  local cached, is_backoff = cached_entry(name)
  if cached then
    if cb then
      cb(cached)
    end
    return
  end
  -- Don't retry if in backoff period
  if is_backoff then
    if cb then
      cb(nil)
    end
    return
  end
  if pending[normalized] then
    if cb then
      table.insert(pending[normalized], cb)
    end
    return
  end
  pending[normalized] = cb and { cb } or {}

  local url = request_url(normalized)
  if not url then
    local callbacks = pending[normalized] or {}
    pending[normalized] = nil
    for _, cbf in ipairs(callbacks) do
      cbf(nil)
    end
    return
  end
  if vim.fn.executable("curl") == 1 then
    run_request({ "curl", "-fsSL", url }, normalized)
  else
    local python = resolve_python()
    if python then
      local script = table.concat({
        "import json,sys,urllib.request",
        "with urllib.request.urlopen(sys.argv[1]) as r:",
        "  data=r.read().decode('utf-8')",
        "print(data)",
      }, "\n")
      run_request({ python, "-c", script, url }, normalized)
      return
    end
    notify_once("pydeps: curl/python not found; PyPI features disabled")
    local callbacks = pending[normalized] or {}
    pending[normalized] = nil
    for _, cbf in ipairs(callbacks) do
      cbf(nil)
    end
  end
end

---@param query? string
---@param cb fun(results: string[])
---@return nil
function M.search(query, cb)
  if not query or query == "" then
    cb({})
    return
  end

  local normalized_query = normalize(query)
  if not is_valid_package_name(normalized_query) then
    cb({})
    return
  end

  local max_results = 30
  if config.options.completion and config.options.completion.max_results then
    max_results = config.options.completion.max_results
  end

  local cached, is_backoff = cached_search_entry(normalized_query)
  if cached then
    cb(filter_prefix(cached, normalized_query, max_results))
    return
  end
  if is_backoff then
    cb({})
    return
  end

  if not search_pending[normalized_query] then
    search_pending[normalized_query] = {}
  end
  table.insert(search_pending[normalized_query], function(results)
    cb(filter_prefix(results, normalized_query, max_results))
  end)
  refresh_search_cache(normalized_query)
end

---@param data? PyDepsPyPIMeta
---@param version? string
---@return boolean
function M.is_yanked(data, version)
  if not data or not version then
    return false
  end
  local releases = data.releases and data.releases[version]
  if not releases then
    return false
  end
  for _, file in ipairs(releases) do
    if file.yanked then
      return true
    end
  end
  return false
end

---@param data? PyDepsPyPIMeta
---@return string[]
function M.sorted_versions(data)
  if not data or not data.releases then
    return {}
  end
  local versions = {}
  for version, files in pairs(data.releases) do
    local latest = nil
    for _, file in ipairs(files) do
      if file.upload_time_iso_8601 then
        if not latest or file.upload_time_iso_8601 > latest then
          latest = file.upload_time_iso_8601
        end
      end
    end
    table.insert(versions, { version = version, time = latest or "" })
  end
  table.sort(versions, function(a, b)
    if a.time == b.time then
      return a.version > b.version
    end
    return a.time > b.time
  end)
  local result = {}
  for _, item in ipairs(versions) do
    table.insert(result, item.version)
  end
  return result
end

return M
