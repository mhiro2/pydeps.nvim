local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

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
    '  "charset-normalizer>=2",',
    '  "idna>=2.5",',
    "]",
    "",
    "[[package.files]]",
    'path = "requests.whl"',
  }, ".lock")

  local data = lockfile.parse_full(path)
  helpers.cleanup_temp_file(path)

  MiniTest.expect.equality(data.resolved.requests, "2.32.3")
  MiniTest.expect.equality(data.packages.requests.dependencies[1], "charset-normalizer>=2")
  MiniTest.expect.equality(data.packages.requests.dependencies[2], "idna>=2.5")
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
  MiniTest.expect.equality(#result_empty_deps.packages.requests.dependencies, 0)

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

  -- dependency with extras notation
  local extras_path = helpers.write_temp_file({
    "[[package]]",
    'name = "requests"',
    'version = "2.32.3"',
    "dependencies = [",
    '  "requests[security]>=2.0",',
    "  \"package-with-underscore; python_version>='3.8'\",",
    "]",
  }, ".lock")
  local result_extras = lockfile.parse_full(extras_path)
  helpers.cleanup_temp_file(extras_path)
  MiniTest.expect.equality(result_extras.packages.requests.dependencies[1], "requests[security]>=2.0")
  MiniTest.expect.equality(
    result_extras.packages.requests.dependencies[2],
    "package-with-underscore; python_version>='3.8'"
  )
end

T["build_graph - boundary conditions"] = function()
  local lockfile = require("pydeps.sources.lockfile")

  -- nil packages should return empty graph
  local graph_nil = lockfile.build_graph(nil)
  MiniTest.expect.equality(next(graph_nil), nil)

  -- empty packages should return empty graph
  local graph_empty = lockfile.build_graph({})
  MiniTest.expect.equality(next(graph_empty), nil)

  -- packages with no dependencies
  local graph_no_deps = lockfile.build_graph({
    pkg1 = { name = "pkg1", version = "1.0.0", dependencies = {} },
  })
  MiniTest.expect.equality(#graph_no_deps.pkg1, 0)

  -- packages with duplicate dependencies (should be deduplicated)
  local graph_dup = lockfile.build_graph({
    pkg1 = {
      name = "pkg1",
      version = "1.0.0",
      dependencies = { "dep1", "dep2", "dep1", "dep3>=1.0", "dep2>=2.0" },
    },
  })
  MiniTest.expect.equality(#graph_dup.pkg1, 3) -- dep1, dep2, dep3
end

return T
