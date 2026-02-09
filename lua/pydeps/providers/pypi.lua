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

---@type table<string, PyDepsPyPICacheEntry>
local cache = {}
---@type table<string, fun(data: PyDepsPyPIMeta?)[]
local pending = {}
---@type table<string, uv_timer_t>
local timers = {}
---@type boolean
local notified = false
---@type string[]?
local simple_index_names = nil
---@type number
local simple_index_updated_at = 0
---@type boolean
local simple_index_loading = false
---@type fun(names: string[]?)[]
local simple_index_callbacks = {}

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
        stdout = data
      end
    end,
    on_stderr = function(_, data)
      if data then
        stderr = data
      end
    end,
    on_exit = function(_, code, _)
      local payload = table.concat(stdout or {}, "\n")
      local err = table.concat(stderr or {}, "\n")
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

---@return boolean
local function simple_index_cache_valid()
  if not simple_index_names then
    return false
  end
  local ttl = config.options.pypi_cache_ttl or 3600
  return (util.now() - simple_index_updated_at) <= ttl
end

---@type fun(script: string, args: string[]?, cb: fun(result: table?)): nil
local run_python_json

---@param cb fun(names: string[]?)
---@return nil
local function with_simple_index(cb)
  if simple_index_cache_valid() then
    cb(simple_index_names)
    return
  end

  table.insert(simple_index_callbacks, cb)
  if simple_index_loading then
    return
  end
  simple_index_loading = true

  local script = table.concat({
    "import json,sys,urllib.request",
    "req=urllib.request.Request(sys.argv[1], headers={'Accept': 'application/vnd.pypi.simple.v1+json'})",
    "with urllib.request.urlopen(req) as r:",
    "  data=json.loads(r.read().decode('utf-8'))",
    "projects=data.get('projects') or []",
    "names=sorted({p.get('name') for p in projects if p.get('name')})",
    "print(json.dumps(names))",
  }, "\n")

  run_python_json(script, { "https://pypi.org/simple/" }, function(result)
    local names = nil
    if type(result) == "table" then
      names = result
      simple_index_names = result
      simple_index_updated_at = util.now()
    end

    simple_index_loading = false
    local callbacks = simple_index_callbacks
    simple_index_callbacks = {}
    for _, callback in ipairs(callbacks) do
      callback(names)
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

---@param script string
---@param args? string[]
---@param cb fun(result: table?)
---@return nil
run_python_json = function(script, args, cb)
  local python = nil
  if vim.fn.executable("python3") == 1 then
    python = "python3"
  elseif vim.fn.executable("python") == 1 then
    python = "python"
  end
  if not python then
    notify_once("pydeps: python not found; PyPI search disabled")
    cb(nil)
    return
  end
  local cmd = { python, "-c", script }
  for _, arg in ipairs(args or {}) do
    table.insert(cmd, arg)
  end
  local stdout = {}
  local completed = false
  local timer = nil

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout = data
      end
    end,
    on_exit = function()
      util.safe_close_timer(timer)
      timer = nil

      if not completed then
        completed = true
        local payload = table.concat(stdout or {}, "\n")
        cb(decode_json(payload))
      end
    end,
  })

  if job_id <= 0 then
    vim.notify(
      "pydeps: Failed to execute Python. Please ensure Python is installed and accessible.",
      vim.log.levels.ERROR
    )
    cb(nil)
    return
  end

  -- Set up timeout timer
  timer = uv.new_timer()
  timer:start(REQUEST_TIMEOUT, 0, function()
    util.safe_close_timer(timer)
    timer = nil
    if not completed then
      completed = true
      vim.schedule(function()
        vim.fn.jobstop(job_id)
        cb(nil)
      end)
    end
  end)
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
  elseif vim.fn.executable("python3") == 1 or vim.fn.executable("python") == 1 then
    local python = vim.fn.executable("python3") == 1 and "python3" or "python"
    local script = table.concat({
      "import json,sys,urllib.request",
      "with urllib.request.urlopen(sys.argv[1]) as r:",
      "  data=r.read().decode('utf-8')",
      "print(data)",
    }, "\n")
    run_request({ python, "-c", script, url }, normalized)
  else
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

  with_simple_index(function(names)
    if not names then
      cb({})
      return
    end
    cb(filter_prefix(names, normalized_query, max_results))
  end)
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
