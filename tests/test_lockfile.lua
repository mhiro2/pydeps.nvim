local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function package_named(data, name)
  return data.packages[data.by_name[name][1]]
end

T["parse uv.lock packages"] = function()
  local lockfile = require("pydeps.sources.lockfile")
  local path = helpers.write_temp_file({
    "[[package]]",
    'name = "requests"',
    'version = "2.31.0"',
    "",
    "[[package]]",
    'name = "rich"',
    'version = "13.7.0"',
  }, ".lock")

  local resolved = lockfile.parse(path)
  helpers.cleanup_temp_file(path)

  MiniTest.expect.equality(resolved.requests, "2.31.0")
  MiniTest.expect.equality(resolved.rich, "13.7.0")
end

T["parse uv.lock with metadata and subtables"] = function()
  local lockfile = require("pydeps.sources.lockfile")
  local path = helpers.write_temp_file({
    "version = 1",
    "",
    "[metadata]",
    "requires-dist = []",
    "",
    "[[package]]",
    'name = "requests"',
    'version = "2.32.3"',
    "",
    "[[package.files]]",
    'path = "requests.whl"',
    "",
    "[[package]]",
    'version = "13.7.1"',
    'name = "rich"',
    "",
    "[[other]]",
    'name = "ignore"',
    'version = "0.1"',
  }, ".lock")

  local resolved = lockfile.parse(path)
  helpers.cleanup_temp_file(path)

  MiniTest.expect.equality(resolved.requests, "2.32.3")
  MiniTest.expect.equality(resolved.rich, "13.7.1")
  MiniTest.expect.equality(resolved.ignore, nil)
end

T["parse uv.lock dependencies"] = function()
  local lockfile = require("pydeps.sources.lockfile")
  local path = helpers.write_temp_file({
    "[[package]]",
    'name = "requests"',
    'version = "2.32.3"',
    "dependencies = [",
    '  { name = "charset-normalizer" },',
    '  { name = "idna" },',
    "]",
    "",
    "[[package.files]]",
    'path = "requests.whl"',
  }, ".lock")

  local data = lockfile.parse_full(path)
  helpers.cleanup_temp_file(path)

  MiniTest.expect.equality(data.resolved.requests, "2.32.3")
  MiniTest.expect.equality(package_named(data, "requests").dependencies[1].name, "charset-normalizer")
  MiniTest.expect.equality(package_named(data, "requests").dependencies[2].name, "idna")
end

T["parse uv.lock - boundary conditions"] = function()
  local lockfile = require("pydeps.sources.lockfile")

  -- nil path should return empty data
  local result_nil = lockfile.parse_full(nil)
  MiniTest.expect.equality(next(result_nil.resolved), nil)
  MiniTest.expect.equality(next(result_nil.packages), nil)

  -- non-existent file should return empty data
  local result_no_file = lockfile.parse_full("/non/existent/path/uv.lock")
  MiniTest.expect.equality(next(result_no_file.resolved), nil)
  MiniTest.expect.equality(next(result_no_file.packages), nil)

  -- empty file should return empty data
  local empty_path = helpers.write_temp_file({}, ".lock")
  local result_empty = lockfile.parse_full(empty_path)
  helpers.cleanup_temp_file(empty_path)
  MiniTest.expect.equality(next(result_empty.resolved), nil)
  MiniTest.expect.equality(next(result_empty.packages), nil)

  -- file with only comments should return empty data
  local comments_path = helpers.write_temp_file({
    "# This is a comment",
    "# Another comment",
  }, ".lock")
  local result_comments = lockfile.parse_full(comments_path)
  helpers.cleanup_temp_file(comments_path)
  MiniTest.expect.equality(next(result_comments.resolved), nil)
  MiniTest.expect.equality(next(result_comments.packages), nil)
end

T["parse uv.lock - malformed toml"] = function()
  local lockfile = require("pydeps.sources.lockfile")

  -- package without name
  local no_name_path = helpers.write_temp_file({
    "[[package]]",
    'version = "2.32.3"',
  }, ".lock")
  local result_no_name = lockfile.parse_full(no_name_path)
  helpers.cleanup_temp_file(no_name_path)
  MiniTest.expect.equality(next(result_no_name.resolved), nil)

  -- package without version
  local no_version_path = helpers.write_temp_file({
    "[[package]]",
    'name = "requests"',
  }, ".lock")
  local result_no_version = lockfile.parse_full(no_version_path)
  helpers.cleanup_temp_file(no_version_path)
  MiniTest.expect.equality(next(result_no_version.resolved), nil)

  -- package with empty dependencies array
  local empty_deps_path = helpers.write_temp_file({
    "[[package]]",
    'name = "requests"',
    'version = "2.32.3"',
    "dependencies = []",
  }, ".lock")
  local result_empty_deps = lockfile.parse_full(empty_deps_path)
  helpers.cleanup_temp_file(empty_deps_path)
  MiniTest.expect.equality(result_empty_deps.resolved.requests, "2.32.3")
  MiniTest.expect.equality(#package_named(result_empty_deps, "requests").dependencies, 0)

  -- unclosed dependencies array (graceful handling)
  local unclosed_path = helpers.write_temp_file({
    "[[package]]",
    'name = "requests"',
    'version = "2.32.3"',
    "dependencies = [",
    '  "dep1"',
  }, ".lock")
  local result_unclosed = lockfile.parse_full(unclosed_path)
  helpers.cleanup_temp_file(unclosed_path)
  -- should parse the package and dependencies found
  MiniTest.expect.equality(result_unclosed.resolved.requests, "2.32.3")
end

T["parse uv.lock - special characters"] = function()
  local lockfile = require("pydeps.sources.lockfile")

  -- package with underscores and hyphens in name
  local special_name_path = helpers.write_temp_file({
    "[[package]]",
    'name = "my_awesome-package"',
    'version = "1.0.0"',
  }, ".lock")
  local result_special_name = lockfile.parse_full(special_name_path)
  helpers.cleanup_temp_file(special_name_path)
  MiniTest.expect.equality(result_special_name.resolved["my_awesome-package"], "1.0.0")
end

T["universal forks preserve identities and project only a known environment"] = function()
  local lockfile = require("pydeps.sources.lockfile")
  local data = lockfile.parse_full("tests/fixtures/fork.uv.lock")
  MiniTest.expect.equality(#data.by_name.demo, 2)
  MiniTest.expect.equality(data.resolved.demo, nil)
  local linux = lockfile.project(data, { sys_platform = "linux" })
  local windows = lockfile.project(data, { sys_platform = "win32" })
  MiniTest.expect.equality(linux.resolved.demo, "1.0")
  MiniTest.expect.equality(windows.resolved.demo, "2.0")
  MiniTest.expect.equality(lockfile.project(data, {}).ambiguous.demo, true)
  MiniTest.expect.equality(linux.graph.app, { "demo" })
  MiniTest.expect.equality(windows.graph.app, { "demo" })
  MiniTest.expect.equality(linux.graph.demo, {})
  MiniTest.expect.equality(lockfile.project(data, { sys_platform = "linux", extra = "speed" }).graph.demo, { "child" })
  MiniTest.expect.equality(lockfile.project(data, { sys_platform = "linux", group = "test" }).graph.demo, { "tester" })
  MiniTest.expect.equality(data.by_name["2.0"], nil)
  MiniTest.expect.equality(data.by_name.sys_platform, nil)
  MiniTest.expect.equality(#data.by_name.same, 2)
  MiniTest.expect.equality(data.resolved.same, nil)
  local edge = package_named(data, "app").dependencies[1]
  MiniTest.expect.equality(edge.version, "1.0")
  MiniTest.expect.equality(edge.source.registry, "https://pypi.org/simple")
  MiniTest.expect.equality(edge.marker, "sys_platform == 'linux'")
end

T["uv generated fork parses synchronously and asynchronously"] = function()
  local lockfile = require("pydeps.sources.lockfile")
  local path = "tests/fixtures/generated-fork.uv.lock"
  local data = lockfile.parse_full(path)
  MiniTest.expect.equality(#data.by_name.demo, 2)
  MiniTest.expect.equality(lockfile.snapshot(data).demo, "1.0, 2.0")
  MiniTest.expect.equality(lockfile.project(data, { sys_platform = "linux" }).resolved.demo, "1.0")
  MiniTest.expect.equality(lockfile.project(data, { sys_platform = "win32" }).resolved.demo, "2.0")
  MiniTest.expect.equality(lockfile.project(data, { sys_platform = "linux" }).graph["fork-app"], { "demo" })
  MiniTest.expect.equality(lockfile.project(data, { sys_platform = "linux" }).graph.demo, { "child" })
  local async_data
  lockfile.parse_async(path, function(result)
    async_data = result
  end)
  vim.wait(1000, function()
    return async_data ~= nil
  end)
  MiniTest.expect.equality(async_data, data)
end

T["lock values preserve escaped quotes and Unicode in source identities"] = function()
  local value = require("pydeps.sources.lock_value")
  MiniTest.expect.equality(value.parse([["\U00000022"]]), '"')
  MiniTest.expect.equality(value.parse([["\\u0022"]]), [[\u0022]])
  MiniTest.expect.equality(value.parse([["\u0022"]]), '"')
  MiniTest.expect.equality(value.parse([[{ directory = "folder\\name", marker = "os_name == 'posix'" }]]), {
    directory = [[folder\name]],
    marker = "os_name == 'posix'",
  })
end

return T
