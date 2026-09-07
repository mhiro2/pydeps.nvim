local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local T = helpers.create_test_set()
local version = require("pydeps.core.version")

T["PEP 440 normalized release ordering"] = function()
  local ordered = {
    "1.0.dev1",
    "1.0a0",
    "1.0a1",
    "1.0b1.dev1",
    "1.0b1",
    "1.0rc1",
    "1.0",
    "1.0.post0.dev1",
    "1.0.post0",
    "1.0.post1",
    "1.1",
    "1!0.1",
  }
  for i, value in ipairs(ordered) do
    for j, spec in ipairs(ordered) do
      MiniTest.expect.equality(version.matches(value, ">=", spec), i >= j)
      MiniTest.expect.equality(version.matches(value, "<=", spec), i <= j)
    end
  end
  for _, pair in ipairs({
    { "v01.002.0", "1.2" },
    { "1.0-alpha", "1.0a0" },
    { "1.0C1", "1.0rc1" },
    { "1.0-2", "1.0.post2" },
    { "1.0REV", "1.0.post0" },
    { "1.0_DEV", "1.0.dev0" },
    { "1.0+ABC_01", "1.0+abc.1" },
  }) do
    MiniTest.expect.equality(version.matches(pair[1], "==", pair[2]), true)
  end
end

T["PEP 440 specifiers distinguish comparison from simple ordering"] = function()
  local cases = {
    { "1.0rc1", "<", "1.0", false },
    { "1.0.post1", ">", "1.0", false },
    { "1.0+local", ">", "1.0", false },
    { "1.0+local", "==", "1.0", true },
    { "1.0+1", "==", "1.0+01", true },
    { "1.0+local", "!=", "1.0", false },
    { "1.4.9", "~=", "1.4.5", true },
    { "1.5", "~=", "1.4.5", false },
    { "1.9", "~=", "1.4", true },
    { "2.0", "~=", "1.4", false },
    { "1.0rc1", "==", "1.*", true },
    { "1", "==", "1.0.*", true },
    { "1!1.0", "==", "1.*", false },
    { "1.0", "===", "1.0.0", false },
    { "legacy", "===", "LEGACY", true },
  }
  for _, case in ipairs(cases) do
    MiniTest.expect.equality(version.matches(case[1], case[2], case[3]), case[4])
  end
end

T["invalid versions and specifiers remain undetermined"] = function()
  for _, value in ipairs({ "", "1..0", "1.", "1.0+", "1.0+a..b", "1.0dev1post1", "1.0junk", "foo" }) do
    MiniTest.expect.equality(version.matches(value, "==", "1.0"), nil)
    MiniTest.expect.equality(version.matches("1.0", "==", value), nil)
  end
  for _, case in ipairs({
    { "~=", "1" },
    { ">=", "1.0+local" },
    { "==", "1.0.dev1.*" },
    { "==", "1.0+local.*" },
    { ">", "1.*" },
  }) do
    MiniTest.expect.equality(version.matches("1.0", case[1], case[2]), nil)
  end
end

return T
