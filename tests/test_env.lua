local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local ENV_JSON = '{"python_version": "3.12", "sys_platform": "linux"}'

---@return string root
local function create_root()
  local root = vim.fn.resolve(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  helpers.defer(function()
    vim.fn.delete(root, "rf")
  end)
  return root
end

---@param venv string
---@return string python
local function create_venv(venv)
  vim.fn.mkdir(venv .. "/bin", "p")
  local python = venv .. "/bin/python"
  vim.fn.writefile({ "#!/bin/sh" }, python)
  vim.fn.setfperm(python, "rwxr-xr-x")
  return python
end

---@param job { opts: table, id: integer, exited?: boolean }
---@param code integer
---@param stdout? string
local function finish_job(job, code, stdout)
  if stdout then
    job.opts.on_stdout(job.id, { stdout, "" })
  end
  job.exited = true
  job.opts.on_exit(job.id, code, "exit")
end

---Capture python jobs instead of spawning them. Jobs a case leaves running
---exit before the stubs are restored, which also closes their timeout timers.
---@return { cmd: string[], opts: table, id: integer, exited?: boolean }[] jobs
---@return integer[] stopped
local function capture_jobs()
  local started, stopped = {}, {}
  helpers.stub(vim.fn, "jobstart", function(cmd, opts)
    local id = 100 + #started
    table.insert(started, { cmd = cmd, opts = opts, id = id })
    return id
  end)
  helpers.stub(vim.fn, "jobstop", function(id)
    table.insert(stopped, id)
    return 1
  end)
  helpers.defer(function()
    for _, job in ipairs(started) do
      if not job.exited then
        finish_job(job, 1)
      end
    end
  end)
  return started, stopped
end

---@return table[]
local function record_env_events()
  local events = {}
  local id = vim.api.nvim_create_autocmd("User", {
    pattern = "PyDepsEnvUpdated",
    callback = function(args)
      table.insert(events, args.data)
    end,
  })
  helpers.defer(function()
    vim.api.nvim_del_autocmd(id)
  end)
  return events
end

T["get uses the VIRTUAL_ENV interpreter and caches its environment"] = function()
  local env = require("pydeps.core.env")
  local root = create_root()
  local venv = root .. "/active-venv"
  local python = create_venv(venv)
  helpers.stub(vim.env, "VIRTUAL_ENV", venv)
  local jobs = capture_jobs()
  local events = record_env_events()

  MiniTest.expect.equality(env.get(root), { python = python, venv = venv })
  -- A second lookup while the first is in flight must not spawn another job.
  env.get(root)
  MiniTest.expect.equality(#jobs, 1)
  MiniTest.expect.equality(jobs[1].cmd[1], python)

  finish_job(jobs[1], 0, ENV_JSON)
  helpers.wait_for(function()
    return #events == 1
  end, "PyDepsEnvUpdated")
  MiniTest.expect.equality(events[1], { root = root })

  local current = env.get(root)
  MiniTest.expect.equality(current.python_version, "3.12")
  MiniTest.expect.equality(current.sys_platform, "linux")
  MiniTest.expect.equality(current.python, python)
  MiniTest.expect.equality(current.venv, venv)
  MiniTest.expect.equality(#jobs, 1)
end

T["get finds a project .venv when VIRTUAL_ENV is unset"] = function()
  local env = require("pydeps.core.env")
  local root = create_root()
  local python = create_venv(root .. "/.venv")
  helpers.stub(vim.env, "VIRTUAL_ENV", nil)
  local jobs = capture_jobs()

  MiniTest.expect.equality(env.get(root), { python = python, venv = root .. "/.venv" })
  MiniTest.expect.equality(jobs[1].cmd[1], python)
end

T["get refetches after the TTL but keeps serving the stale environment"] = function()
  local env = require("pydeps.core.env")
  local root = create_root()
  create_venv(root .. "/.venv")
  helpers.stub(vim.env, "VIRTUAL_ENV", nil)
  local clock = 1000000
  helpers.stub(vim.uv, "now", function()
    return clock
  end)
  local jobs = capture_jobs()

  env.get(root)
  finish_job(jobs[1], 0, ENV_JSON)

  clock = clock + 299 * 1000
  env.get(root)
  MiniTest.expect.equality(#jobs, 1)

  clock = clock + 2 * 1000
  MiniTest.expect.equality(env.get(root).python_version, "3.12")
  MiniTest.expect.equality(#jobs, 2)
end

T["get retries after a failed interpreter run"] = function()
  local env = require("pydeps.core.env")
  local root = create_root()
  create_venv(root .. "/.venv")
  helpers.stub(vim.env, "VIRTUAL_ENV", nil)
  local jobs = capture_jobs()
  local events = record_env_events()

  env.get(root)
  finish_job(jobs[1], 1, ENV_JSON)
  helpers.drain(20)
  MiniTest.expect.equality(#events, 0)
  MiniTest.expect.equality(env.get(root).python_version, nil)
  MiniTest.expect.equality(#jobs, 2)
end

T["get stops a hanging interpreter after the timeout"] = function()
  local env = require("pydeps.core.env")
  local root = create_root()
  create_venv(root .. "/.venv")
  helpers.stub(vim.env, "VIRTUAL_ENV", nil)
  local jobs, stopped = capture_jobs()

  -- Fire the timeout immediately instead of waiting for the real delay.
  local new_timer = vim.uv.new_timer
  helpers.stub(vim.uv, "new_timer", function()
    local timer = new_timer()
    local start = timer.start
    return setmetatable({
      start = function(_, _, repeat_ms, cb)
        return start(timer, 0, repeat_ms, cb)
      end,
    }, {
      __index = function(_, key)
        local value = timer[key]
        if type(value) == "function" then
          return function(_, ...)
            return value(timer, ...)
          end
        end
        return value
      end,
    })
  end)

  env.get(root)
  helpers.wait_for(function()
    return #stopped == 1
  end, "jobstop on timeout")
  MiniTest.expect.equality(stopped, { jobs[1].id })

  env.get(root)
  MiniTest.expect.equality(#jobs, 2)
  helpers.wait_for(function()
    return #stopped == 2
  end, "jobstop of the retried job")
end

T["get reports a failed job start and allows a retry"] = function()
  local env = require("pydeps.core.env")
  local root = create_root()
  create_venv(root .. "/.venv")
  helpers.stub(vim.env, "VIRTUAL_ENV", nil)
  local starts = 0
  helpers.stub(vim.fn, "jobstart", function()
    starts = starts + 1
    return 0
  end)
  local messages = {}
  helpers.stub(vim, "notify", function(msg, level)
    table.insert(messages, { msg = msg, level = level })
  end)

  env.get(root)
  MiniTest.expect.equality(#messages, 1)
  MiniTest.expect.equality(messages[1].level, vim.log.levels.ERROR)
  MiniTest.expect.equality(messages[1].msg:find("Python environment", 1, true) ~= nil, true)

  env.get(root)
  MiniTest.expect.equality(starts, 2)
end

return T
