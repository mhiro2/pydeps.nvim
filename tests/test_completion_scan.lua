local MiniTest = require("mini.test")

local T = MiniTest.new_set()

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
  local open_quote, close_quote = 17, 31
  local expected = { value = "requests>=2.0", start_col = open_quote, end_col = close_quote, quote = '"' }

  -- the cursor is inside from just after the opening quote up to the closing quote
  MiniTest.expect.equality(scan.string_context(line, open_quote), nil)
  MiniTest.expect.equality(scan.string_context(line, open_quote + 1), expected)
  MiniTest.expect.equality(scan.string_context(line, close_quote), expected)
  MiniTest.expect.equality(scan.string_context(line, close_quote + 1), nil)
  MiniTest.expect.equality(scan.string_context(line, 1), nil)

  -- an unterminated string runs to the end of the line
  MiniTest.expect.equality(
    scan.string_context("dependencies = ['req", 21),
    { value = "req", start_col = 17, end_col = 21, quote = "'" }
  )
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

T["token_range returns an empty range when no token touches the cursor"] = function()
  local scan = require("pydeps.completion.scan")
  local name_pattern = "[%w%._%-]"

  local left, right = scan.token_range("", 1, name_pattern)
  MiniTest.expect.equality({ left, right }, { 1, 1 })

  left, right = scan.token_range("requests>=", 11, "[%w%._%-%+%*]")
  MiniTest.expect.equality({ left, right }, { 11, 11 })

  left, right = scan.token_range("requests[", 10, name_pattern)
  MiniTest.expect.equality({ left, right }, { 10, 10 })

  left, right = scan.token_range("requests[]", 10, name_pattern)
  MiniTest.expect.equality({ left, right }, { 10, 10 })
end

T["token_range keeps the token when the cursor is at its end"] = function()
  local scan = require("pydeps.completion.scan")
  local left, right = scan.token_range("requ", 5, "[%w%._%-]")
  MiniTest.expect.equality({ left, right }, { 1, 5 })
end

return T
