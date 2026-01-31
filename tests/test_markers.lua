local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["evaluate markers"] = function()
  local markers = require("pydeps.core.markers")
  local env = {
    python_version = "3.11",
    python_full_version = "3.11.2",
    sys_platform = "linux",
    platform_machine = "arm64",
    os_name = "posix",
    extra = "dev",
  }

  MiniTest.expect.equality(markers.evaluate("", env), true)
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.8'", env), true)
  MiniTest.expect.equality(markers.evaluate("python_full_version < '3.10'", env), false)
  MiniTest.expect.equality(markers.evaluate("sys_platform == 'linux'", env), true)
  MiniTest.expect.equality(markers.evaluate("os_name != 'nt' and sys_platform == 'linux'", env), true)
  MiniTest.expect.equality(markers.evaluate("platform_machine in 'x86_64, arm64'", env), true)
  MiniTest.expect.equality(markers.evaluate("extra == 'dev' or extra == 'docs'", env), true)
  MiniTest.expect.equality(markers.evaluate("extra == 'docs'", env), false)
end

T["evaluate markers - case normalization"] = function()
  local markers = require("pydeps.core.markers")
  local env = {
    sys_platform = "Linux",
    os_name = "PoSiX",
    extra = "DEV",
  }

  MiniTest.expect.equality(markers.evaluate("sys_platform == 'linux'", env), true)
  MiniTest.expect.equality(markers.evaluate("os_name == 'posix'", env), true)
  MiniTest.expect.equality(markers.evaluate("extra == 'dev'", env), true)
  MiniTest.expect.equality(markers.evaluate("sys_platform in 'win32,LINUX'", env), true)
  MiniTest.expect.equality(markers.evaluate("sys_platform not in 'win32,darwin'", env), true)
end

T["evaluate markers with dependency groups"] = function()
  local markers = require("pydeps.core.markers")
  local env_with_group = {
    python_version = "3.11",
    sys_platform = "linux",
    os_name = "posix",
    group = "test",
    dependency_group = "test",
  }

  MiniTest.expect.equality(markers.evaluate("group == 'test'", env_with_group), true)
  MiniTest.expect.equality(markers.evaluate("dependency_group == 'test'", env_with_group), true)
  MiniTest.expect.equality(markers.evaluate("group == 'dev'", env_with_group), false)
  MiniTest.expect.equality(markers.evaluate("dependency_group == 'dev'", env_with_group), false)
  MiniTest.expect.equality(markers.evaluate("group == 'test' and python_version >= '3.8'", env_with_group), true)
end

T["evaluate markers - boundary conditions"] = function()
  local markers = require("pydeps.core.markers")
  local env = {
    python_version = "3.11",
    sys_platform = "linux",
  }

  -- nil marker should return true
  MiniTest.expect.equality(markers.evaluate(nil, env), true)

  -- empty string marker should return true
  MiniTest.expect.equality(markers.evaluate("", env), true)

  -- whitespace-only marker should return true
  MiniTest.expect.equality(markers.evaluate("   ", env), true)

  -- nil env should return nil (evaluation incomplete)
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.8'", nil), nil)

  -- empty env table should return nil (evaluation incomplete)
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.8'", {}), nil)

  -- invalid syntax should return true (graceful degradation)
  MiniTest.expect.equality(markers.evaluate("((((", env), true)

  -- undefined variable in env should return nil (evaluation incomplete)
  MiniTest.expect.equality(markers.evaluate("undefined_var == 'test'", env), nil)

  -- and operator: nil (undefined var) on left, false (known condition) on right should return false (determined by right)
  MiniTest.expect.equality(markers.evaluate("undefined_var == 'test' and sys_platform == 'win32'", env), false)

  -- and operator: nil (undefined var) on left, true (known condition) on right should return nil (undetermined)
  MiniTest.expect.equality(markers.evaluate("undefined_var == 'test' and sys_platform == 'linux'", env), nil)

  -- and operator: nil on both sides should return nil
  MiniTest.expect.equality(markers.evaluate("undefined_var1 == 'test' and undefined_var2 == 'test'", env), nil)

  -- and operator: true (known condition) on left, nil (undefined var) on right should return nil
  MiniTest.expect.equality(markers.evaluate("sys_platform == 'linux' and undefined_var == 'test'", env), nil)

  -- or operator: nil (undefined var) on left, false (known condition) on right should return nil (undetermined)
  MiniTest.expect.equality(markers.evaluate("undefined_var == 'test' or sys_platform == 'win32'", env), nil)

  -- or operator: nil (undefined var) on left, true (known condition) on right should return true (determined by right)
  MiniTest.expect.equality(markers.evaluate("undefined_var == 'test' or sys_platform == 'linux'", env), true)

  -- or operator: nil on both sides should return nil
  MiniTest.expect.equality(markers.evaluate("undefined_var1 == 'test' or undefined_var2 == 'test'", env), nil)

  -- or operator: false (known condition) on left, nil (undefined var) on right should return nil
  MiniTest.expect.equality(markers.evaluate("sys_platform == 'win32' or undefined_var == 'test'", env), nil)
end

T["evaluate markers - escape sequences"] = function()
  local markers = require("pydeps.core.markers")
  local env = {
    python_version = "3.11",
    sys_platform = "linux",
  }

  -- single quotes in double quotes
  MiniTest.expect.equality(markers.evaluate('python_version >= "3.8"', env), true)

  -- double quotes in single quotes
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.8'", env), true)

  -- escaped quotes are treated literally (current behavior)
  MiniTest.expect.equality(markers.evaluate([[python_version >= '3\.8']], env), false)
end

T["evaluate markers - non-semantic versions"] = function()
  local markers = require("pydeps.core.markers")
  local env = {
    python_version = "3.11.0",
  }

  -- Note: Current implementation uses simple string comparison for non-numeric parts
  -- In dictionary order: "0" < "0a1" < "0.dev1" < "0post1" < "0rc1"
  -- This means "3.11.0" < "3.11.0a1" in the current implementation
  -- This differs from PEP 440 but reflects the current behavior

  -- alpha versions (dictionary order: "0" < "0a1")
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.11.0a1'", env), false)
  MiniTest.expect.equality(markers.evaluate("python_version <= '3.11.0a1'", env), true)

  -- rc versions (dictionary order: "0" < "0rc1")
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.11.0rc1'", env), false)
  MiniTest.expect.equality(markers.evaluate("python_version <= '3.11.0rc1'", env), true)

  -- dev versions (dictionary order: "0" < "0.dev1")
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.11.0.dev1'", env), false)
  MiniTest.expect.equality(markers.evaluate("python_version <= '3.11.0.dev1'", env), true)

  -- post releases (dictionary order: "0" < "0post1")
  -- Note: 3.11.0 > 3.10.0.post1 because 11 > 10 at the second position
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.10.0.post1'", env), true)
  MiniTest.expect.equality(markers.evaluate("python_version <= '3.10.0.post1'", env), false)

  -- Test with same version prefix
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.11.0.post1'", env), false)
  MiniTest.expect.equality(markers.evaluate("python_version <= '3.11.0.post1'", env), true)

  -- Final release is greater than pre-releases in PEP 440,
  -- but current implementation uses dictionary order
  -- Testing the actual current behavior
  MiniTest.expect.equality(markers.evaluate("python_version > '3.11.0a1'", env), false)
  MiniTest.expect.equality(markers.evaluate("python_version < '3.11.0a1'", env), true)
  MiniTest.expect.equality(markers.evaluate("python_version > '3.10.0.post1'", env), true)
  MiniTest.expect.equality(markers.evaluate("python_version < '3.10.0.post1'", env), false)
end

T["evaluate markers - complex expressions"] = function()
  local markers = require("pydeps.core.markers")
  local env = {
    python_version = "3.11",
    sys_platform = "linux",
    os_name = "posix",
    extra = "dev",
  }

  -- nested parentheses
  MiniTest.expect.equality(markers.evaluate("((python_version >= '3.8'))", env), true)

  -- multiple and/or
  MiniTest.expect.equality(
    markers.evaluate("python_version >= '3.8' and (sys_platform == 'linux' or sys_platform == 'darwin')", env),
    true
  )

  -- not in operator
  MiniTest.expect.equality(markers.evaluate("sys_platform not in 'win32,darwin'", env), true)

  -- chained comparisons (evaluated as separate conditions)
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.8' and python_version < '4.0'", env), true)
end

T["evaluate markers with extra and group combinations"] = function()
  local markers = require("pydeps.core.markers")

  -- Test with extra only
  local env_extra = {
    python_version = "3.11",
    extra = "dev",
  }
  MiniTest.expect.equality(markers.evaluate("extra == 'dev'", env_extra), true)
  MiniTest.expect.equality(markers.evaluate("extra == 'test'", env_extra), false)
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.8' and extra == 'dev'", env_extra), true)

  -- Test with group only
  local env_group = {
    python_version = "3.11",
    group = "test",
  }
  MiniTest.expect.equality(markers.evaluate("group == 'test'", env_group), true)
  MiniTest.expect.equality(markers.evaluate("group == 'dev'", env_group), false)
  MiniTest.expect.equality(markers.evaluate("python_version >= '3.8' and group == 'test'", env_group), true)

  -- Test with both extra and group
  local env_both = {
    python_version = "3.11",
    extra = "docs",
    group = "test",
  }
  MiniTest.expect.equality(markers.evaluate("extra == 'docs' or group == 'test'", env_both), true)
  MiniTest.expect.equality(markers.evaluate("extra == 'dev' or group == 'dev'", env_both), false)
  MiniTest.expect.equality(
    markers.evaluate("(extra == 'docs' or group == 'test') and python_version >= '3.8'", env_both),
    true
  )

  -- Test without extra or group
  local env_none = {
    python_version = "3.11",
  }
  -- When extra is not set in env, marker evaluation should be incomplete
  MiniTest.expect.equality(markers.evaluate("extra == 'dev'", env_none), nil)
  MiniTest.expect.equality(markers.evaluate("group == 'test'", env_none), nil)
end

return T
