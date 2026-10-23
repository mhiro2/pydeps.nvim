local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

---@type integer[]
local stopped

local T = helpers.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.core.jobs"] = nil
      stopped = {}
      helpers.stub(vim.fn, "jobstop", function(id)
        table.insert(stopped, id)
        return 1
      end)
    end,
  },
})

T["untrack removes only the given job from the stop set"] = function()
  local jobs = require("pydeps.core.jobs")
  jobs._reset()

  jobs.track(42)
  jobs.track(43)
  jobs.untrack(42)
  jobs.stop_all()

  MiniTest.expect.equality(stopped, { 43 })
end

T["track ignores non-positive job ids"] = function()
  local jobs = require("pydeps.core.jobs")
  jobs._reset()

  MiniTest.expect.no_error(function()
    jobs.track(0)
    jobs.track(-1)
    jobs.track(nil)
    jobs.track("not a number")
  end)
  jobs.stop_all()

  MiniTest.expect.equality(stopped, {})
end

T["stop_all flips is_stopping and calls jobstop"] = function()
  local jobs = require("pydeps.core.jobs")
  jobs._reset()

  jobs.track(101)
  jobs.track(202)
  MiniTest.expect.equality(jobs.is_stopping(), false)
  jobs.stop_all()

  table.sort(stopped)
  MiniTest.expect.equality(stopped, { 101, 202 })
  MiniTest.expect.equality(jobs.is_stopping(), true)
end

T["track after stop_all immediately stops the new job"] = function()
  local jobs = require("pydeps.core.jobs")
  jobs._reset()

  jobs.stop_all()
  jobs.track(303)

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
