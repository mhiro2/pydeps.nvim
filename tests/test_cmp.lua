local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local T = helpers.create_test_set()

T["cmp translates named byte coordinates before completion"] = function()
  local core = require("pydeps.completion.core")
  local original_complete = core.complete
  local original_source = package.loaded["pydeps.completion.cmp"]
  package.loaded["pydeps.completion.cmp"] = nil
  local seen, result
  core.complete = function(bufnr, cursor, callback)
    seen = { bufnr, cursor }
    callback({ items = { { label = "requests" } }, isIncomplete = false })
  end
  local ok, err = pcall(function()
    local source = require("pydeps.completion.cmp").new()
    source:complete(
      { context = { bufnr = 12, cursor = { row = 2, col = 20, line = 1, character = 15 } } },
      function(value)
        result = value
      end
    )
    MiniTest.expect.equality(seen, { 12, { 2, 19 } })
    MiniTest.expect.equality(result.items[1].label, "requests")
    MiniTest.expect.equality(result.isIncomplete, false)
    source:complete(
      { context = { bufnr = 12, cursor = { row = 1, col = 1, line = 0, character = 0 } } },
      function() end
    )
    MiniTest.expect.equality(seen, { 12, { 1, 0 } })
  end)
  core.complete = original_complete
  package.loaded["pydeps.completion.cmp"] = original_source
  if not ok then
    error(err)
  end
end

return T
