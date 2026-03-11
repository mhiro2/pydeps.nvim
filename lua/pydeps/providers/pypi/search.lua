local config = require("pydeps.config")
local backoff = require("pydeps.providers.pypi.backoff")
local shared = require("pydeps.providers.pypi.shared")
local util = require("pydeps.util")

local uv = vim.uv

local M = {}

---@param opts? { notify_once?: fun(msg: string) }
---@return { search: fun(query: string?, cb: fun(results: string[])) }
function M.new(opts)
  opts = opts or {}

  ---@type table<string, PyDepsBackoffEntry>
  local cache = {}
  ---@type table<string, boolean>
  local loading = {}
  ---@type table<string, uv_timer_t>
  local timers = {}
  ---@type table<string, fun(results: string[])[]>
  local pending = {}

  ---@param query string
  ---@return string[]?, boolean
  local function cached_entry(query)
    return backoff.get(cache, query, {
      now = util.now(),
      ttl = shared.pypi_cache_ttl(),
    })
  end

  ---@param query string
  ---@param results string[]
  ---@param failed? boolean
  ---@return nil
  local function set_cache(query, results, failed)
    backoff.set(cache, query, results, {
      now = util.now(),
      failed = failed,
      backoff = shared.SEARCH_FAILURE_BACKOFF,
    })
  end

  ---@param query string
  ---@param results string[]
  ---@return nil
  local function flush_callbacks(query, results)
    local callbacks = pending[query] or {}
    pending[query] = nil
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
    local prefix = shared.normalize(query)

    for _, name in ipairs(names) do
      if shared.normalize(name):find(prefix, 1, true) == 1 then
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
    local normalized = shared.normalize(util.trim(name))
    if normalized == "" or seen[normalized] then
      return
    end
    if not shared.is_valid_package_name(normalized) then
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
  local function run_request(cmd, query)
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
      util.safe_close_timer(timers[query])
      timers[query] = nil
      loading[query] = nil
      set_cache(query, results, failed)
      flush_callbacks(query, results)
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
      loading[query] = nil
      set_cache(query, {}, true)
      flush_callbacks(query, {})
      vim.notify("pydeps: Failed to execute PyPI search command.", vim.log.levels.ERROR)
      return
    end

    timers[query] = uv.new_timer()
    timers[query]:start(shared.REQUEST_TIMEOUT, 0, function()
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
  local function refresh(query)
    if loading[query] then
      return
    end
    loading[query] = true

    local url = shared.search_url(query)
    if not url then
      loading[query] = nil
      set_cache(query, {}, false)
      flush_callbacks(query, {})
      return
    end

    if vim.fn.executable("curl") == 1 then
      run_request({ "curl", "-fsSL", url }, query)
      return
    end

    local python = shared.resolve_python()
    if python then
      local script = table.concat({
        "import sys,urllib.request",
        "with urllib.request.urlopen(sys.argv[1]) as r:",
        "  data=r.read().decode('utf-8', errors='ignore')",
        "print(data)",
      }, "\n")
      run_request({ python, "-c", script, url }, query)
      return
    end

    loading[query] = nil
    if opts.notify_once then
      opts.notify_once("pydeps: curl/python not found; PyPI search disabled")
    end
    set_cache(query, {}, true)
    flush_callbacks(query, {})
  end

  local client = {}

  ---@param query? string
  ---@param cb fun(results: string[])
  ---@return nil
  function client.search(query, cb)
    if not query or query == "" then
      cb({})
      return
    end

    local normalized = shared.normalize(query)
    if not shared.is_valid_package_name(normalized) then
      cb({})
      return
    end

    local max_results = config.options.completion and config.options.completion.max_results or 30
    local cached, is_backoff = cached_entry(normalized)
    if cached then
      cb(filter_prefix(cached, normalized, max_results))
      return
    end
    if is_backoff then
      cb({})
      return
    end

    pending[normalized] = pending[normalized] or {}
    table.insert(pending[normalized], function(results)
      cb(filter_prefix(results, normalized, max_results))
    end)
    refresh(normalized)
  end

  return client
end

return M
