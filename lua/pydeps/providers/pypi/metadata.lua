local backoff = require("pydeps.providers.pypi.backoff")
local shared = require("pydeps.providers.pypi.shared")
local util = require("pydeps.util")

local uv = vim.uv

local M = {}

---@param opts? { notify_once?: fun(msg: string), on_update?: fun(name: string) }
---@return { get_cached: fun(name: string): PyDepsPyPIMeta?, get: fun(name: string, cb?: fun(data: PyDepsPyPIMeta?)) }
function M.new(opts)
  opts = opts or {}

  ---@type table<string, PyDepsBackoffEntry>
  local cache = {}
  ---@type table<string, fun(data: PyDepsPyPIMeta?)[]
  local pending = {}
  ---@type table<string, uv_timer_t>
  local timers = {}

  ---@param name string
  ---@return PyDepsPyPIMeta?, boolean
  local function cached_entry(name)
    return backoff.get(cache, shared.normalize(name), {
      now = util.now(),
      ttl = shared.pypi_cache_ttl(),
    })
  end

  ---@param name string
  ---@param data? PyDepsPyPIMeta
  ---@param failed? boolean
  ---@return nil
  local function set_cache(name, data, failed)
    backoff.set(cache, shared.normalize(name), data, {
      now = util.now(),
      failed = failed,
      backoff = shared.SEARCH_FAILURE_BACKOFF,
    })
  end

  ---@param name string
  ---@return nil
  local function emit_update(name)
    if not opts.on_update or name == "" then
      return
    end
    opts.on_update(shared.normalize(name))
  end

  ---@param cmd string[]
  ---@param name string
  ---@return nil
  local function run_request(cmd, name)
    local normalized = shared.normalize(name)
    local stdout = {}
    local stderr = {}
    local completed = false

    ---@param decoded? table
    ---@param had_error boolean
    ---@return nil
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
        set_cache(name, nil, true)
      end

      local callbacks = pending[normalized] or {}
      pending[normalized] = nil
      vim.schedule(function()
        for _, callback in ipairs(callbacks) do
          callback(decoded)
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
          decoded = shared.decode_json(payload)
        end
        finish(decoded, code ~= 0 or err ~= "")
      end,
    })

    if job_id > 0 then
      timers[normalized] = uv.new_timer()
      timers[normalized]:start(shared.REQUEST_TIMEOUT, 0, function()
        if completed then
          return
        end
        vim.schedule(function()
          vim.fn.jobstop(job_id)
        end)
        finish(nil, true)
      end)
      return
    end

    vim.notify(
      string.format("pydeps: Failed to fetch package '%s' from PyPI. Please check your internet connection.", name),
      vim.log.levels.ERROR
    )
    finish(nil, true)
  end

  local client = {}

  ---@param name string
  ---@return PyDepsPyPIMeta?
  function client.get_cached(name)
    local data, _ = cached_entry(name)
    return data
  end

  ---@param name string
  ---@param cb? fun(data: PyDepsPyPIMeta?)
  ---@return nil
  function client.get(name, cb)
    local normalized = shared.normalize(name)
    if normalized == "" or not shared.is_valid_package_name(normalized) then
      if cb then
        cb(nil)
      end
      return
    end

    local cached, is_backoff = cached_entry(normalized)
    if cached then
      if cb then
        cb(cached)
      end
      return
    end
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

    local url = shared.request_url(normalized)
    if not url then
      local callbacks = pending[normalized] or {}
      pending[normalized] = nil
      for _, callback in ipairs(callbacks) do
        callback(nil)
      end
      return
    end

    if vim.fn.executable("curl") == 1 then
      run_request({ "curl", "-fsSL", url }, normalized)
      return
    end

    local python = shared.resolve_python()
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

    if opts.notify_once then
      opts.notify_once("pydeps: curl/python not found; PyPI features disabled")
    end
    local callbacks = pending[normalized] or {}
    pending[normalized] = nil
    for _, callback in ipairs(callbacks) do
      callback(nil)
    end
  end

  return client
end

return M
