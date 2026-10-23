local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local JOB_ID = 17

local T = helpers.new_set({
  hooks = {
    pre_case = function()
      helpers.close_extra_windows()
      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_set_current_buf(bufnr)
      require("pydeps.core.jobs")._reset()
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

T["output run_command: collects stdout chunks"] = function()
  package.loaded["pydeps.ui.output"] = nil
  local output = require("pydeps.ui.output")
  local shown_lines = nil
  helpers.stub(output, "show", function(_, lines)
    shown_lines = lines
  end)
  local captured = stub_jobstart(function(opts)
    opts.on_stdout(JOB_ID, { "first line" })
    opts.on_stdout(JOB_ID, { "second line", "" })
    opts.on_exit(JOB_ID, 0)
  end)

  output.run_command({ "dummy" }, { title = "dummy", cwd = "/tmp/project" })
  helpers.wait_for(function()
    return shown_lines ~= nil
  end, "output.show")

  MiniTest.expect.equality(shown_lines, { "first line", "second line" })
  MiniTest.expect.equality(captured, { cmd = { "dummy" }, cwd = "/tmp/project" })
  MiniTest.expect.equality(jobs_left_to_stop(), {})
end

T["output run_command: keeps its job tracked until it exits"] = function()
  package.loaded["pydeps.ui.output"] = nil
  local output = require("pydeps.ui.output")
  helpers.stub(output, "show", function() end)
  helpers.stub(vim, "notify", function() end)
  local running
  stub_jobstart(function(opts)
    running = opts
  end)

  output.run_command({ "dummy" }, { title = "dummy" })
  helpers.wait_for(function()
    return running ~= nil
  end, "command job start")

  MiniTest.expect.equality(jobs_left_to_stop(), { JOB_ID })
  running.on_exit(JOB_ID, 143)
end

T["output run_command: collects stderr chunks for error message"] = function()
  package.loaded["pydeps.ui.output"] = nil
  local output = require("pydeps.ui.output")
  local notified_message = nil
  helpers.stub(vim, "notify", function(msg)
    notified_message = msg
  end)
  stub_jobstart(function(opts)
    opts.on_stderr(JOB_ID, { "first error" })
    opts.on_stderr(JOB_ID, { "second error", "" })
    opts.on_exit(JOB_ID, 1)
  end)

  output.run_command({ "dummy" }, { title = "dummy" })
  helpers.wait_for(function()
    return notified_message ~= nil
  end, "failure notification")

  MiniTest.expect.equality(notified_message, "pydeps: command failed\nfirst error\nsecond error")
  MiniTest.expect.equality(jobs_left_to_stop(), {})
end

return T
