local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["limiter caps concurrency and starts queued work in order"] = function()
  local limiter = require("pydeps.core.rate_limit").new(2)
  local started = {}
  local done = {}
  for i = 1, 4 do
    limiter:enqueue(function(finish)
      table.insert(started, i)
      done[i] = finish
    end)
  end

  MiniTest.expect.equality(started, { 1, 2 })
  MiniTest.expect.equality(limiter.active, 2)

  done[2]()
  MiniTest.expect.equality(started, { 1, 2, 3 })
  MiniTest.expect.equality(limiter.active, 2)

  done[1]()
  done[3]()
  MiniTest.expect.equality(started, { 1, 2, 3, 4 })
  MiniTest.expect.equality(limiter.active, 1)

  done[4]()
  MiniTest.expect.equality(limiter.active, 0)
  MiniTest.expect.equality(limiter.queue, {})
end

T["limiter runs work that finishes synchronously back to back"] = function()
  local limiter = require("pydeps.core.rate_limit").new(1)
  local order = {}
  for i = 1, 3 do
    limiter:enqueue(function(finish)
      table.insert(order, i)
      finish()
    end)
  end

  MiniTest.expect.equality(order, { 1, 2, 3 })
  MiniTest.expect.equality(limiter.active, 0)
end

return T
