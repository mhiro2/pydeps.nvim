local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local JOB_ID = 5

local T = helpers.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.providers.uv"] = nil
      require("pydeps.core.jobs")._reset()
      local executable = vim.fn.executable
      helpers.stub(vim.fn, "executable", function(cmd)
        if cmd == "uv" then
          return 1
        end
        return executable(cmd)
      end)
    end,
  },
})

---@param on_start fun(opts: table)
---@return { cmd: string[]?, cwd: string? }
local function stub_jobstart(on_start)
  local captured = {}
  helpers.stub(vim.fn, "jobstart", function(cmd, opts)
    captured.cmd, captured.cwd = cmd, opts.cwd
    vim.schedule(function()
      on_start(opts)
    end)
    return JOB_ID
  end)
  return captured
end

---@return PyDepsUvResolveResult
local function resolve(root)
  local result = nil
  require("pydeps.providers.uv").resolve({
    root = root,
    on_finish = function(value)
      result = value
    end,
  })
  helpers.wait_for(function()
    return result ~= nil
  end, "uv.resolve result")
  return result
end

---@return integer[]
local function jobs_left_to_stop()
  local stopped = {}
  helpers.stub(vim.fn, "jobstop", function(id)
    table.insert(stopped, id)
    return 1
  end)
  local jobs = require("pydeps.core.jobs")
  jobs.stop_all()
  jobs._reset()
  return stopped
end

T["resolve returns success result"] = function()
  local captured = stub_jobstart(function(opts)
    opts.on_exit(JOB_ID, 0, "exit")
  end)

  local result = resolve("/tmp/project")

  MiniTest.expect.equality(result, { ok = true, code = 0 })
  MiniTest.expect.equality(captured, { cmd = { "uv", "lock" }, cwd = "/tmp/project" })
  MiniTest.expect.equality(jobs_left_to_stop(), {})
end

T["resolve returns stderr on failure"] = function()
  stub_jobstart(function(opts)
    opts.on_stderr(JOB_ID, { "lock failed" })
    opts.on_exit(JOB_ID, 2, "exit")
  end)

  local result = resolve()

  MiniTest.expect.equality(result, { ok = false, reason = "exit", code = 2, stderr = "lock failed" })
  MiniTest.expect.equality(jobs_left_to_stop(), {})
end

T["resolve keeps its job tracked until it exits"] = function()
  local running
  stub_jobstart(function(opts)
    running = opts
  end)
  require("pydeps.providers.uv").resolve({ root = "/tmp/project", on_finish = function() end })
  helpers.wait_for(function()
    return running ~= nil
  end, "uv lock job start")

  MiniTest.expect.equality(jobs_left_to_stop(), { JOB_ID })
  running.on_exit(JOB_ID, 143, "exit")
end

T["tree_command returns explicit command payload"] = function()
  local uv = require("pydeps.providers.uv")
  local command = uv.tree_command({
    root = "/tmp/project",
    args = { "tree", "--depth", "2" },
  })

  MiniTest.expect.equality(command, { cmd = { "uv", "tree", "--depth", "2" }, cwd = "/tmp/project" })
end

return T
