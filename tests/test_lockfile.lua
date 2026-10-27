local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function package_named(data, name)
  return data.packages[data.by_name[name][1]]
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

  local resolved = lockfile.parse_full(path).resolved
  helpers.cleanup_temp_file(path)

  MiniTest.expect.equality(resolved, { requests = "2.32.3", rich = "13.7.1" })
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

---@return table[] messages
local function capture_notify()
  local messages = {}
  helpers.stub(vim, "notify_once", function(msg, level)
    messages[#messages + 1] = { msg = msg, level = level }
  end)
  return messages
end

---@param lines string[]
---@return string path
local function unreadable_lock(lines)
  local path = helpers.write_temp_file(lines, ".lock")
  vim.fn.setfperm(path, "---------")
  helpers.defer(function()
    helpers.cleanup_temp_file(path)
  end)
  return path
end

T["parse_full reports a lockfile it cannot open"] = function()
  local lockfile = require("pydeps.sources.lockfile")
  local messages = capture_notify()

  MiniTest.expect.equality(lockfile.parse_full("/non/existent/path/uv.lock").resolved, {})
  helpers.drain(20)
  MiniTest.expect.equality(messages, {})

  local path = unreadable_lock({ "[[package]]", 'name = "requests"', 'version = "1.0"' })
  MiniTest.expect.equality(lockfile.parse_full(path).resolved, {})
  helpers.wait_for(function()
    return #messages > 0
  end, "lockfile read failure notification")
  MiniTest.expect.equality(messages[1].level, vim.log.levels.ERROR)
  MiniTest.expect.equality(messages[1].msg:find(path, 1, true) ~= nil, true)

  -- A directory without search permission hides the file from fs_stat too.
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "version = 1" }, dir .. "/uv.lock")
  vim.fn.setfperm(dir, "rw-------")
  helpers.defer(function()
    vim.fn.setfperm(dir, "rwx------")
    vim.fn.delete(dir, "rf")
  end)
  MiniTest.expect.equality(lockfile.parse_full(dir .. "/uv.lock").resolved, {})
  helpers.wait_for(function()
    return #messages > 1
  end, "notification for a lockfile behind an unsearchable directory")
  MiniTest.expect.equality(messages[2].msg:find(dir, 1, true) ~= nil, true)
end

---@param path string
---@return { data: PyDepsLockfileData?, err: string? }
local function parse_async_result(path)
  local result
  require("pydeps.sources.lockfile").parse_async(path, function(data, err)
    result = { data = data, err = err }
  end)
  helpers.wait_for(function()
    return result ~= nil
  end, "parse_async callback")
  return result
end

---@return table<integer, integer> opened fd -> close count
local function track_file_descriptors()
  local uv = vim.uv
  local opened = {}
  local original_open, original_close = uv.fs_open, uv.fs_close
  helpers.stub(uv, "fs_open", function(path, flags, mode, cb)
    return original_open(path, flags, mode, function(err, fd)
      if fd then
        opened[fd] = 0
      end
      cb(err, fd)
    end)
  end)
  helpers.stub(uv, "fs_close", function(fd, ...)
    if opened[fd] then
      opened[fd] = opened[fd] + 1
    end
    return original_close(fd, ...)
  end)
  return opened
end

---@param opened table<integer, integer>
local function expect_all_closed_once(opened)
  MiniTest.expect.equality(vim.tbl_count(opened) > 0, true)
  for fd, closes in pairs(opened) do
    MiniTest.expect.equality({ fd = fd, closes = closes }, { fd = fd, closes = 1 })
    opened[fd] = nil
  end
end

T["parse_async reports open failures without a missing-file notification"] = function()
  local messages = capture_notify()

  local missing = parse_async_result("/non/existent/path/uv.lock")
  MiniTest.expect.equality(missing.data, nil)
  MiniTest.expect.equality(vim.startswith(missing.err, "ENOENT"), true)

  local path = unreadable_lock({ "[[package]]", 'name = "requests"', 'version = "1.0"' })
  local denied = parse_async_result(path)
  MiniTest.expect.equality(denied.data, nil)
  MiniTest.expect.equality(vim.startswith(denied.err, "EACCES"), true)
  helpers.wait_for(function()
    return #messages > 0
  end, "lockfile read failure notification")
  MiniTest.expect.equality(#messages, 1)
  MiniTest.expect.equality(messages[1].msg:find(path, 1, true) ~= nil, true)
end

T["parse_async closes the file on empty, stat and read failures"] = function()
  local uv = vim.uv
  local path = helpers.write_temp_file({ "[[package]]", 'name = "requests"', 'version = "1.0"' }, ".lock")
  local empty_path = helpers.write_temp_file({}, ".lock")
  helpers.defer(function()
    helpers.cleanup_temp_file(path)
    helpers.cleanup_temp_file(empty_path)
  end)

  local opened = track_file_descriptors()
  local empty = parse_async_result(empty_path)
  MiniTest.expect.equality(empty.data.packages, {})
  MiniTest.expect.equality(empty.data.resolved, {})
  expect_all_closed_once(opened)

  local original_fstat = uv.fs_fstat
  helpers.stub(uv, "fs_fstat", function(_, cb)
    cb("EBADF: bad file descriptor")
  end)
  MiniTest.expect.equality(parse_async_result(path), { err = "EBADF: bad file descriptor" })
  expect_all_closed_once(opened)
  uv.fs_fstat = original_fstat

  helpers.stub(uv, "fs_read", function(_, _, _, cb)
    cb("EIO: i/o error")
  end)
  MiniTest.expect.equality(parse_async_result(path), { err = "EIO: i/o error" })
  expect_all_closed_once(opened)
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

  -- package without version: kept as an identity, but never resolved
  local no_version_path = helpers.write_temp_file({
    "[[package]]",
    'name = "requests"',
  }, ".lock")
  local result_no_version = lockfile.parse_full(no_version_path)
  helpers.cleanup_temp_file(no_version_path)
  MiniTest.expect.equality(next(result_no_version.resolved), nil)
  MiniTest.expect.equality(#result_no_version.by_name.requests, 1)
  MiniTest.expect.equality(package_named(result_no_version, "requests").version, nil)

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
  -- the package survives; the array never closes, so its entries are dropped
  MiniTest.expect.equality(result_unclosed.resolved.requests, "2.32.3")
  MiniTest.expect.equality(package_named(result_unclosed, "requests").dependencies, {})
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
  MiniTest.expect.equality(result_special_name.resolved["my-awesome-package"], "1.0.0")
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

T["multi-line arrays decode once and ignore brackets inside strings"] = function()
  local lockfile = require("pydeps.sources.lockfile")
  local value = require("pydeps.sources.lock_value")
  local lines = {
    "[[package]]",
    'name = "app"',
    'version = "1.0"',
    "dependencies = [",
  }
  for i = 1, 200 do
    lines[#lines + 1] = string.format('  { name = "dep%d", marker = "extra == \'a]{\'" },', i)
  end
  vim.list_extend(lines, {
    "]",
    "",
    "[package.optional-dependencies]",
    "speed = [",
    '  { name = "dep1", extra = ["fast"] },',
    "]",
  })
  local path = helpers.write_temp_file(lines, ".lock")

  local original_parse = value.parse
  local calls = 0
  value.parse = function(text)
    calls = calls + 1
    return original_parse(text)
  end
  local ok, data = pcall(lockfile.parse_full, path)
  value.parse = original_parse
  helpers.cleanup_temp_file(path)

  MiniTest.expect.equality(ok, true)
  local app = package_named(data, "app")
  MiniTest.expect.equality(#app.dependencies, 201)
  MiniTest.expect.equality(app.dependencies[200].name, "dep200")
  MiniTest.expect.equality(app.dependencies[200].marker, "extra == 'a]{'")
  MiniTest.expect.equality(app.dependencies[201].group, "speed")
  MiniTest.expect.equality(app.dependencies[201].extra, { "fast" })
  -- One decode per key, not one per accumulated line.
  MiniTest.expect.equality(calls, 4)
end

T["projections are reused per lock data and environment"] = function()
  local lockfile = require("pydeps.sources.lockfile")
  local data = lockfile.parse_full("tests/fixtures/fork.uv.lock")
  local linux = lockfile.project(data, { sys_platform = "linux" })
  MiniTest.expect.equality(lockfile.project(data, { sys_platform = "linux" }) == linux, true)
  MiniTest.expect.equality(lockfile.project(data, { sys_platform = "win32" }) == linux, false)
  local reparsed = lockfile.parse_full("tests/fixtures/fork.uv.lock")
  MiniTest.expect.equality(lockfile.project(reparsed, { sys_platform = "linux" }) == linux, false)
end

T["projections enable the project's extras and groups the context selects"] = function()
  local lockfile = require("pydeps.sources.lockfile")
  local data = lockfile.parse_full(helpers.write_temp_file({
    "version = 1",
    "",
    "[[package]]",
    'name = "app"',
    'version = "0.1.0"',
    'source = { editable = "." }',
    'dependencies = [{ name = "base" }]',
    "",
    "[package.optional-dependencies]",
    'postgres = [{ name = "orm", extra = ["asyncio"] }]',
    "",
    "[package.dev-dependencies]",
    'test = [{ name = "pytest" }]',
    "",
    "[[package]]",
    'name = "base"',
    'version = "1.0"',
    'source = { registry = "https://pypi.org/simple" }',
    "",
    "[[package]]",
    'name = "orm"',
    'version = "2.0"',
    'source = { registry = "https://pypi.org/simple" }',
    "",
    "[package.optional-dependencies]",
    'asyncio = [{ name = "greenlet" }]',
    'other = [{ name = "base" }]',
    "",
    "[[package]]",
    'name = "greenlet"',
    'version = "3.0"',
    'source = { registry = "https://pypi.org/simple" }',
    "",
    "[[package]]",
    'name = "pytest"',
    'version = "8.0"',
    'source = { registry = "https://pypi.org/simple" }',
  }, ".lock"))

  -- Unfiltered, every extra and group of the project is followed, but other
  -- packages only enable the extras someone requests.
  local all = lockfile.project(data, {})
  MiniTest.expect.equality(all.graph.app, { "base", "orm", "pytest" })
  MiniTest.expect.equality(all.graph.orm, { "greenlet" })

  local none = lockfile.project(data, { extras = {}, dependency_groups = {} })
  MiniTest.expect.equality(none.graph.app, { "base" })
  MiniTest.expect.equality(none.graph.orm, {})

  local selected = lockfile.project(data, { extras = { "postgres" }, dependency_groups = { "test" } })
  MiniTest.expect.equality(selected.graph.app, { "base", "orm", "pytest" })
  MiniTest.expect.equality(selected.graph.orm, { "greenlet" })
end

return T
