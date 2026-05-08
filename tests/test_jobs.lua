local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.core.jobs"] = nil
    end,
  },
})

T["track / untrack with positive job id"] = function()
  local jobs = require("pydeps.core.jobs")
  jobs._reset()

  jobs.track(42)
  jobs.untrack(42)
  MiniTest.expect.equality(jobs.is_stopping(), false)
end

T["track ignores non-positive job ids"] = function()
  local jobs = require("pydeps.core.jobs")
  jobs._reset()

  -- Should not error and should leave state untouched
  MiniTest.expect.no_error(function()
    jobs.track(0)
    jobs.track(-1)
    jobs.track(nil)
    jobs.track("not a number")
  end)
  MiniTest.expect.equality(jobs.is_stopping(), false)
end

T["stop_all flips is_stopping and calls jobstop"] = function()
  local jobs = require("pydeps.core.jobs")
  jobs._reset()

  local stopped = {}
  local original = vim.fn.jobstop
  vim.fn.jobstop = function(id)
    table.insert(stopped, id)
    return 1
  end

  jobs.track(101)
  jobs.track(202)
  jobs.stop_all()

  vim.fn.jobstop = original

  table.sort(stopped)
  MiniTest.expect.equality(stopped, { 101, 202 })
  MiniTest.expect.equality(jobs.is_stopping(), true)
end

T["track after stop_all immediately stops the new job"] = function()
  local jobs = require("pydeps.core.jobs")
  jobs._reset()

  local original = vim.fn.jobstop
  jobs.stop_all()

  local stopped = {}
  vim.fn.jobstop = function(id)
    table.insert(stopped, id)
    return 1
  end

  jobs.track(303)

  vim.fn.jobstop = original
  MiniTest.expect.equality(stopped, { 303 })
end

T["untrack after stop_all is a safe no-op"] = function()
  local jobs = require("pydeps.core.jobs")
  jobs._reset()

  jobs.track(404)
  jobs.stop_all()

  MiniTest.expect.no_error(function()
    -- Simulates on_exit firing for a job that was just stopped.
    jobs.untrack(404)
    -- Untracking an unknown id should also be safe.
    jobs.untrack(999)
  end)
  MiniTest.expect.equality(jobs.is_stopping(), true)
end

return T
