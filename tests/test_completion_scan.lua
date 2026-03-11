local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.completion.scan"] = nil
    end,
  },
})

T["scan_strings handles escaped and unclosed strings"] = function()
  local scan = require("pydeps.completion.scan")
  local ranges = scan.scan_strings([[dependencies = ["hello \"world\"", 'open]])

  MiniTest.expect.equality(#ranges, 2)
  MiniTest.expect.equality(ranges[1].quote, '"')
  MiniTest.expect.equality(ranges[1].closed, true)
  MiniTest.expect.equality(ranges[2].quote, "'")
  MiniTest.expect.equality(ranges[2].closed, false)
end

T["string_context returns value and bounds inside a string"] = function()
  local scan = require("pydeps.completion.scan")
  local line = 'dependencies = ["requests>=2.0"]'
  local col = line:find("quests")

  local ctx = scan.string_context(line, col)
  MiniTest.expect.no_equality(ctx, nil)
  MiniTest.expect.equality(ctx.value, "requests>=2.0")
  MiniTest.expect.equality(ctx.start_col < ctx.end_col, true)
  MiniTest.expect.equality(scan.string_context(line, 1), nil)
end

T["token_range expands around package and version tokens"] = function()
  local scan = require("pydeps.completion.scan")

  local left_name, right_name = scan.token_range("requests-toolbelt", 9, "[%w%._%-]")
  MiniTest.expect.equality(left_name, 1)
  MiniTest.expect.equality(right_name, #"requests-toolbelt" + 1)

  local version = "requests>=2.1.0"
  local left_version, right_version = scan.token_range(version, version:find("2"), "[%w%._%-%+%*]")
  MiniTest.expect.equality(version:sub(left_version, right_version - 1), "2.1.0")
end

return T
