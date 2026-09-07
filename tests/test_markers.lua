local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local T = helpers.create_test_set()
local markers = require("pydeps.core.markers")
local env = {
  python_version = "3.11",
  python_full_version = "3.11.2",
  implementation_version = "3.11.2",
  platform_release = "14.5.0",
  platform_version = "#1 SMP Linux",
  sys_platform = "linux",
  platform_machine = "arm64",
  platform_python_implementation = "CPython",
  os_name = "posix",
  extra = "Dev_Test",
  group = "test",
  dependency_group = "test",
  extras = { "Dev_Test", "docs" },
  dependency_groups = { "test" },
}

T["standard comparisons and group selectors"] = function()
  local cases = {
    { "", true },
    { "   ", true },
    { "python_version >= '3.8'", true },
    { "python_full_version < '3.10'", false },
    { "'3.9' < python_version", true },
    { "python_version === '3.11'", true },
    { "python_version === '3.11.0'", false },
    { "python_version ~= '3.10'", true },
    { "python_version ~= '3.10.0'", false },
    { "implementation_version >= '3.11'", true },
    { "platform_release > '9.0'", true },
    { "sys_platform == 'linux'", true },
    { "sys_platform == 'Linux'", false },
    { "sys_platform == ' linux '", false },
    { "platform_python_implementation == 'CPython'", true },
    { "sys_platform < 'win32'", false },
    { "sys_platform <= 'linux'", true },
    { "sys_platform >= 'darwin'", false },
    { "sys_platform != 'win32'", true },
    { "extra == 'dev.test'", true },
    { "'dev-test' == extra", true },
    { "group == 'test'", true },
    { "dependency_group == 'dev'", false },
  }
  MiniTest.expect.equality(markers.evaluate(nil, env), true)
  for _, case in ipairs(cases) do
    MiniTest.expect.equality({ markers.evaluate(case[1], env) }, { case[2] })
  end
end

T["membership is case sensitive substring matching or normalized set membership"] = function()
  local cases = {
    { "sys_platform in 'win32'", false },
    { "sys_platform in 'linux'", true },
    { "sys_platform not in 'win32'", true },
    { "sys_platform not in 'linux'", false },
    { "sys_platform in 'LINUX'", false },
    { "'lin' in sys_platform", true },
    { "'nux' in sys_platform", true },
    { "'' in sys_platform", true },
    { "'arm' in platform_machine", true },
    { "platform_machine in 'x86_64, arm64'", true },
    { "'SMP' in platform_version", true },
    { "'dev.test' in extras", true },
    { "'dev' in extras", false },
    { "'test' not in dependency_groups", false },
  }
  for _, case in ipairs(cases) do
    MiniTest.expect.equality({ markers.evaluate(case[1], env) }, { case[2] })
  end
end

T["PEP 440 ordering handles prereleases epochs local labels and wildcard matching"] = function()
  local cases = {
    { "python_version > '3.11.0a1'", true },
    { "python_version < '3.11.0a1'", false },
    { "python_version >= '3.11.0rc1'", true },
    { "python_version <= '3.11.0rc1'", false },
    { "python_version >= '3.11.0.dev1'", true },
    { "python_version <= '3.11.0.dev1'", false },
    { "python_version > '3.10.0.post1'", true },
    { "python_version < '3.11.0.post1'", true },
    { "python_version == '3.11.0'", true },
    { "python_version == '3.*'", true },
    { "python_version != '3.11.*'", false },
    { "python_version < '1!1.0'", true },
  }
  for _, case in ipairs(cases) do
    MiniTest.expect.equality({ markers.evaluate(case[1], env) }, { case[2] })
  end
  MiniTest.expect.equality(markers.evaluate("python_version == '3.11'", { python_version = "3.11+vendor.1" }), true)
end

T["parser rejects incomplete input unsupported tokens and unknown fields"] = function()
  for _, expr in ipairs({
    "((((",
    "python_version",
    "'literal'",
    "python_version = '3.11'",
    "python_version >=",
    "python_version == '3.11",
    "(python_version == '3.11'",
    "python_version == '3.11')",
    "python_version == '3.11' garbage",
    "python_version == '3.11' and",
    "python_version == '3.11' @",
    "python_version == '3.11' == '3.11'",
    "python_version == python_full_version",
    "'3.11' == '3.11'",
    "python_version ~= '3'",
    "python_version >= 'not-a-version'",
    "sys_platform ~= 'linux'",
    "python_version in '3.11'",
    "extras == 'docs'",
    "extras in 'docs'",
  }) do
    MiniTest.expect.equality({ markers.evaluate(expr, env) }, { nil, "invalid" })
  end
  MiniTest.expect.equality(
    { markers.evaluate("sys_platform == 'linux'", { sys_platform = false }) },
    { nil, "invalid" }
  )
  MiniTest.expect.equality({ markers.evaluate("unknown == 'value'", { unknown = "value" }) }, { nil, "unknown" })
  MiniTest.expect.equality(
    { markers.evaluate("unknown == 'value' or sys_platform == 'linux'", env) },
    { nil, "unknown" }
  )
end

T["boolean expressions preserve pending values and require valid whole syntax"] = function()
  MiniTest.expect.equality({ markers.evaluate("python_version >= '3.8'", {}) }, { nil, "pending" })
  local partial = { sys_platform = "linux" }
  local cases = {
    { "python_version >= '3.8' and sys_platform == 'win32'", false },
    { "sys_platform == 'win32' and python_version >= '3.8'", false },
    { "python_version >= '3.8' or sys_platform == 'linux'", true },
    { "sys_platform == 'linux' or python_version >= '3.8'", true },
  }
  for _, case in ipairs(cases) do
    MiniTest.expect.equality({ markers.evaluate(case[1], partial) }, { case[2] })
  end
  for _, expr in ipairs({
    "python_version >= '3.8' and sys_platform == 'linux'",
    "python_version >= '3.8' or sys_platform == 'win32'",
  }) do
    MiniTest.expect.equality({ markers.evaluate(expr, partial) }, { nil, "pending" })
  end
  MiniTest.expect.equality(
    markers.evaluate("((python_version >= '3.8'))and(sys_platform == 'linux' or group == 'dev')", env),
    true
  )
  MiniTest.expect.equality({ markers.evaluate("sys_platform == 'linux' or (", env) }, { nil, "invalid" })
  MiniTest.expect.equality(
    { markers.evaluate("sys_platform == 'linux' or python_version ~= '3'", env) },
    { nil, "invalid" }
  )
end

return T
