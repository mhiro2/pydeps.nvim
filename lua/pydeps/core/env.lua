---@class PyDepsEnv
---@field python_version? string
---@field python_full_version? string
---@field sys_platform? string
---@field platform_system? string
---@field platform_machine? string
---@field platform_release? string
---@field platform_version? string
---@field implementation_name? string
---@field os_name? string
---@field python? string
---@field venv? string
---@field extra? string
---@field group? string
---@field dependency_group? string

---@class PyDepsEnvCacheEntry
---@field value PyDepsEnv
---@field time number

local M = {}

---@type table<string, PyDepsEnvCacheEntry>
local cache = {}
local cache_ttl = 300
---@type table<string, boolean>
local fetching = {}
---@type table<string, uv_timer_t>
local timers = {}

local uv = vim.uv

-- Request timeout in milliseconds
local REQUEST_TIMEOUT = 5000

---@param root string
local function emit_env_update(root)
  if not root or root == "" then
    return
  end
  vim.schedule(function()
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "PyDepsEnvUpdated",
      data = { root = root },
    })
  end)
end

---@param timer uv_timer_t
local function safe_close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

---@return number
local function now()
  return uv.now() / 1000
end

---@param path? string
---@return boolean
local function is_dir(path)
  return path and vim.fn.isdirectory(path) == 1
end

---@param path? string
---@return boolean
local function is_file(path)
  return path and vim.fn.filereadable(path) == 1
end

---@param root? string
---@return string?
local function find_venv(root)
  if vim.env.VIRTUAL_ENV and vim.env.VIRTUAL_ENV ~= "" then
    return vim.env.VIRTUAL_ENV
  end
  local start = root or uv.cwd()
  local found = vim.fs.find({ ".venv", "venv", ".env" }, { path = start, upward = true, type = "directory" })[1]
  if found and is_dir(found) then
    return found
  end
  return nil
end

---@param venv? string
---@return string?
local function python_from_venv(venv)
  if not venv then
    return nil
  end
  local candidates = {
    vim.fs.joinpath(venv, "bin", "python"),
    vim.fs.joinpath(venv, "bin", "python3"),
    vim.fs.joinpath(venv, "Scripts", "python.exe"),
    vim.fs.joinpath(venv, "Scripts", "python"),
  }
  for _, path in ipairs(candidates) do
    if is_file(path) and vim.fn.executable(path) == 1 then
      return path
    end
  end
  return nil
end

---@param root? string
---@return string?, string?
local function find_python(root)
  local venv = find_venv(root)
  local python = python_from_venv(venv)
  if python then
    return python, venv
  end
  if vim.fn.executable("python3") == 1 then
    return "python3", venv
  end
  if vim.fn.executable("python") == 1 then
    return "python", venv
  end
  return nil, venv
end

---@param python? string
---@param venv? string
---@param key string
local function fetch_env_async(python, venv, key)
  if not python then
    fetching[key] = false
    return
  end
  local script = table.concat({
    "import json,sys,platform,os",
    "data={",
    "'python_version': f\"{sys.version_info.major}.{sys.version_info.minor}\",",
    "'python_full_version': platform.python_version(),",
    "'sys_platform': sys.platform,",
    "'platform_system': platform.system(),",
    "'platform_machine': platform.machine(),",
    "'platform_release': platform.release(),",
    "'platform_version': platform.version(),",
    "'implementation_name': platform.python_implementation().lower(),",
    "'os_name': os.name,",
    "}",
    "print(json.dumps(data))",
  }, "\n")

  local stdout = {}
  local job_id = vim.fn.jobstart({ python, "-c", script }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        stdout = data
      end
    end,
    on_exit = function(_, code, _)
      -- Clear timeout timer
      safe_close_timer(timers[key])
      timers[key] = nil

      fetching[key] = false
      if code ~= 0 then
        return
      end
      local output = table.concat(stdout or {}, "\n")
      local ok, decoded = pcall(vim.json.decode, output)
      if ok and decoded then
        decoded.python = python
        decoded.venv = venv
        cache[key] = { value = decoded, time = now() }
        emit_env_update(key)
      end
    end,
  })

  -- Set up timeout timer
  if job_id > 0 then
    timers[key] = uv.new_timer()
    timers[key]:start(REQUEST_TIMEOUT, 0, function()
      safe_close_timer(timers[key])
      timers[key] = nil

      -- Kill the job
      vim.fn.jobstop(job_id)
      fetching[key] = false
    end)
  else
    -- jobstart failed
    vim.notify(
      "pydeps: Failed to detect Python environment. Please ensure Python is installed and accessible.",
      vim.log.levels.ERROR
    )
    fetching[key] = false
  end
end

---Get the Python environment for the given root directory.
---On first call, returns a partial PyDepsEnv with only `python` and `venv` fields.
---Subsequent calls (after async fetch completes) return the complete PyDepsEnv.
---@param root? string
---@return PyDepsEnv env (may be partial on first call, with only `python` and `venv` fields)
function M.get(root)
  local key = root or uv.cwd()
  local cached = cache[key]

  -- Return cached value if still valid
  if cached and (now() - cached.time) < cache_ttl then
    return cached.value
  end

  -- Start async fetch if not already fetching
  if not fetching[key] then
    fetching[key] = true
    local python, venv = find_python(root)
    fetch_env_async(python, venv, key)
  end

  -- Return cached value if available (even if expired), or empty env
  if cached then
    return cached.value
  end

  local python, venv = find_python(root)
  return { python = python, venv = venv }
end

return M
