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

---@return number
local function now()
  return uv.now() / 1000
end

---@param timer uv_timer_t
---@return nil
local function safe_close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@param name? string
---@return string
local function normalize(name)
  return (name or ""):lower()
end

---@param name string
---@return nil
local function emit_update(name)
  if not name or name == "" then
    return
  end
  vim.schedule(function()
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "PyDepsPyPIUpdated",
      data = { name = normalize(name) },
    })
  end)
end

---@param name string
---@return PyDepsPyPIMeta?, boolean
local function cached_entry(name)
  local entry = cache[normalize(name)]
  if not entry then
    return nil, false
  end
  -- If failed entry has retry_after in the future, it's in backoff period
  if entry.failed and entry.retry_after and now() < entry.retry_after then
    return nil, true -- Indicates that it's in backoff period
  end
  -- Check TTL for successful entries
  if not entry.failed and (now() - entry.time) > (config.options.pypi_cache_ttl or 3600) then
    cache[normalize(name)] = nil
    return nil, false
  end
  -- If retry_after has passed for failed entry, retry is allowed
  if entry.failed and entry.retry_after and now() >= entry.retry_after then
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
  local entry = { data = data, time = now() }
  if failed then
    entry.failed = true
    entry.retry_after = now() + 60 -- 60 second backoff
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

    safe_close_timer(timers[normalized])
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
---@return string
local function request_url(name)
  local base = config.options.pypi_url or "https://pypi.org/pypi"
  return string.format("%s/%s/json", base, name)
end

---@param script string
---@param args? string[]
---@param cb fun(result: table?)
---@return nil
local function run_python_json(script, args, cb)
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

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout = data
      end
    end,
    on_exit = function()
      if not completed then
        completed = true
        local payload = table.concat(stdout or {}, "\n")
        cb(decode_json(payload))
      end
    end,
  })

  -- Set up timeout timer
  if job_id > 0 then
    local timer = uv.new_timer()
    timer:start(REQUEST_TIMEOUT, 0, function()
      safe_close_timer(timer)
      if not completed then
        completed = true
        vim.fn.jobstop(job_id)
        cb(nil)
      end
    end)
  else
    -- jobstart failed
    vim.notify(
      "pydeps: Failed to execute Python. Please ensure Python is installed and accessible.",
      vim.log.levels.ERROR
    )
    cb(nil)
  end
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
  local max_results = 30
  if config.options.completion and config.options.completion.max_results then
    max_results = config.options.completion.max_results
  end
  local script = table.concat({
    "import json,sys,xmlrpc.client",
    "client=xmlrpc.client.ServerProxy('https://pypi.org/pypi')",
    "hits=client.search({'name': sys.argv[1]}, 'or')",
    "names=sorted({h.get('name') for h in hits if h.get('name')})",
    "limit=int(sys.argv[2]) if len(sys.argv) > 2 else 30",
    "print(json.dumps(names[:limit]))",
  }, "\n")
  run_python_json(script, { query, tostring(max_results) }, function(result)
    cb(result or {})
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
