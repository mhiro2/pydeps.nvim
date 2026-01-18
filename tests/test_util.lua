local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["parse_requirement_name extracts name"] = function()
  local util = require("pydeps.util")
  MiniTest.expect.equality(util.parse_requirement_name("requests>=2.0"), "requests")
  MiniTest.expect.equality(util.parse_requirement_name("Foo-Bar[extra]>=1.0; python_version>='3.11'"), "foo-bar")
  MiniTest.expect.equality(util.parse_requirement_name(""), nil)
end

T["parse_requirement_extras extracts extras"] = function()
  local util = require("pydeps.util")
  MiniTest.expect.equality(util.parse_requirement_extras("requests[security, socks]>=2.0"), { "security", "socks" })
  MiniTest.expect.equality(util.parse_requirement_extras("Foo-Bar[extra]>=1.0; python_version>='3.11'"), { "extra" })
  MiniTest.expect.equality(util.parse_requirement_extras("requests>=2.0"), {})
  MiniTest.expect.equality(util.parse_requirement_extras(""), {})
end

return T
