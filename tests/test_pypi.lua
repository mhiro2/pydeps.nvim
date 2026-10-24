local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local JOB_ID = 7

---@return table
local function fresh_pypi()
  package.loaded["pydeps.providers.pypi"] = nil
  package.loaded["pydeps.providers.pypi.metadata"] = nil
  package.loaded["pydeps.providers.pypi.search"] = nil
  return require("pydeps.providers.pypi")
end

-- Pretend curl exists and route every job through `handler`, which receives
-- the command, the job options and the job id returned to the caller.
---@param handler fun(cmd: string[], opts: table, job_id: integer, call: integer)
---@return { calls: string[][] }
local function stub_curl(handler)
  local spy = { calls = {} }
  helpers.stub(vim.fn, "executable", function(cmd)
    return cmd == "curl" and 1 or 0
  end)
  helpers.stub(vim.fn, "jobstart", function(cmd, opts)
    table.insert(spy.calls, cmd)
    local call = #spy.calls
    local job_id = JOB_ID + call - 1
    vim.schedule(function()
      handler(cmd, opts, job_id, call)
    end)
    return job_id
  end)
  return spy
end

---@return integer[]
local function stopped_jobs_after_stop_all()
  local jobs = require("pydeps.core.jobs")
  local stopped = {}
  helpers.stub(vim.fn, "jobstop", function(id)
    table.insert(stopped, id)
    return 1
  end)
  jobs.stop_all()
  jobs._reset()
  return stopped
end

---@return { msg: string, level: integer }[]
local function capture_notify()
  local notifications = {}
  helpers.stub(vim, "notify", function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end)
  return notifications
end

T["pypi get: skips invalid package names"] = function()
  local pypi = fresh_pypi()
  local spy = stub_curl(function() end)
  local callback_result = "unset"

  pypi.get("../invalid-name", function(data)
    callback_result = data
  end)

  MiniTest.expect.equality(spy.calls, {})
  MiniTest.expect.equality(callback_result, nil)
end

T["pypi get: requests valid package names"] = function()
  local pypi = fresh_pypi()
  require("pydeps.core.jobs")._reset()
  local spy = stub_curl(function(_, opts, job_id)
    opts.on_stdout(job_id, { '{"info":{"version":"1.2.3"' })
    opts.on_stdout(job_id, { "}}" })
    opts.on_exit(job_id, 0, "exit")
  end)
  local callback_result = nil

  pypi.get("valid-name", function(data)
    callback_result = data
  end)
  helpers.wait_for(function()
    return callback_result ~= nil
  end, "pypi.get callback")

  MiniTest.expect.equality(#spy.calls, 1)
  MiniTest.expect.equality(spy.calls[1][1], "curl")
  MiniTest.expect.equality(spy.calls[1][#spy.calls[1]], "https://pypi.org/pypi/valid-name/json")
  MiniTest.expect.equality(callback_result.info.version, "1.2.3")
  -- The finished job was untracked, so shutdown has nothing left to stop.
  MiniTest.expect.equality(stopped_jobs_after_stop_all(), {})
end

T["pypi get: keeps the request job tracked until it exits"] = function()
  local pypi = fresh_pypi()
  require("pydeps.core.jobs")._reset()
  local running
  stub_curl(function(_, opts, job_id)
    running = { opts = opts, id = job_id }
  end)

  pypi.get("slow-package", function() end)
  helpers.wait_for(function()
    return running ~= nil
  end, "curl job start")

  MiniTest.expect.equality(stopped_jobs_after_stop_all(), { running.id })
  -- Exit the stopped job so its timeout timer is closed.
  running.opts.on_exit(running.id, 143, "exit")
end

T["pypi get: keeps decoded payload when the process also writes stderr"] = function()
  local pypi = fresh_pypi()
  require("pydeps.core.jobs")._reset()
  -- Run a real process in place of curl so stdout/stderr buffering and the
  -- job id passed to on_exit come from Neovim itself.
  local jobstart = vim.fn.jobstart
  helpers.stub(vim.fn, "executable", function(cmd)
    return cmd == "curl" and 1 or 0
  end)
  helpers.stub(vim.fn, "jobstart", function(_, opts)
    return jobstart({
      "sh",
      "-c",
      [[printf '{"info":{"version":"1.2.3"}}'; printf 'first error\n' >&2]],
    }, opts)
  end)
  local callback_result = "unset"

  pypi.get("valid-name", function(data)
    callback_result = data
  end)
  helpers.wait_for(function()
    return callback_result ~= "unset"
  end, "pypi.get callback", 5000)

  MiniTest.expect.equality(callback_result, { info = { version = "1.2.3" } })
  MiniTest.expect.equality(stopped_jobs_after_stop_all(), {})
end

T["pypi search: returns results and reuses cache"] = function()
  local pypi = fresh_pypi()
  local spy = stub_curl(function(_, opts, job_id)
    opts.on_stdout(job_id, { '<span class="package-snippet__name">requests</span>' })
    opts.on_stdout(job_id, { '<span class="package-snippet__name">requests-toolbelt</span>' })
    opts.on_exit(job_id, 0, "exit")
  end)
  local first_results = nil
  local second_results = nil

  pypi.search("req", function(results)
    first_results = results
  end)
  helpers.wait_for(function()
    return first_results ~= nil
  end, "first search")

  pypi.search("req", function(results)
    second_results = results
  end)

  MiniTest.expect.equality(#spy.calls, 1)
  local url = spy.calls[1][#spy.calls[1]]
  MiniTest.expect.equality(url:match("/search/%?q=req") ~= nil, true)
  MiniTest.expect.equality(url:match("/simple/") == nil, true)
  MiniTest.expect.equality(first_results, { "requests", "requests-toolbelt" })
  MiniTest.expect.equality(second_results, { "requests", "requests-toolbelt" })
end

T["pypi search: serves all callbacks during in-flight request"] = function()
  local pypi = fresh_pypi()
  local spy = stub_curl(function(_, opts, job_id)
    opts.on_stdout(job_id, { '<span class="package-snippet__name">requests</span>' })
    opts.on_stdout(job_id, { '<span class="package-snippet__name">requests-toolbelt</span>' })
    opts.on_exit(job_id, 0, "exit")
  end)
  local first_results = nil
  local second_results = nil

  pypi.search("req", function(results)
    first_results = results
  end)
  pypi.search("req", function(results)
    second_results = results
  end)
  helpers.wait_for(function()
    return first_results ~= nil and second_results ~= nil
  end, "both search callbacks")

  MiniTest.expect.equality(#spy.calls, 1)
  MiniTest.expect.equality(first_results, { "requests", "requests-toolbelt" })
  MiniTest.expect.equality(second_results, { "requests", "requests-toolbelt" })
end

T["pypi search: retries after failure backoff"] = function()
  local util = require("pydeps.util")
  local now = 1000
  helpers.stub(util, "now", function()
    return now
  end)
  local pypi = fresh_pypi()
  capture_notify()
  local spy = stub_curl(function(_, opts, job_id, call)
    if call == 1 then
      opts.on_stderr(job_id, { "temporary error" })
      opts.on_exit(job_id, 1, "exit")
      return
    end
    opts.on_stdout(job_id, { '<span class="package-snippet__name">requests</span>' })
    opts.on_exit(job_id, 0, "exit")
  end)
  local first_results = nil
  local second_results = nil
  local third_results = nil

  pypi.search("req", function(results)
    first_results = results
  end)
  helpers.wait_for(function()
    return first_results ~= nil
  end, "first search")

  pypi.search("req", function(results)
    second_results = results
  end)

  now = now + 61
  pypi.search("req", function(results)
    third_results = results
  end)
  helpers.wait_for(function()
    return third_results ~= nil
  end, "retried search")

  MiniTest.expect.equality(first_results, {})
  MiniTest.expect.equality(second_results, {})
  MiniTest.expect.equality(third_results, { "requests" })
  MiniTest.expect.equality(#spy.calls, 2)
end

T["pypi search: warns once per session and degrades on failure"] = function()
  local pypi = fresh_pypi()
  local notifications = capture_notify()
  local spy = stub_curl(function(_, opts, job_id)
    opts.on_stderr(job_id, { "network error" })
    opts.on_exit(job_id, 1, "exit")
  end)
  local results = {}

  for _, query in ipairs({ "req", "rich" }) do
    pypi.search(query, function(res)
      table.insert(results, res)
    end)
    helpers.wait_for(function()
      return #results == #spy.calls
    end, "search callback for " .. query)
  end

  -- Each failed search degrades to an empty result, but the warning is
  -- only shown for the first one.
  MiniTest.expect.equality(#spy.calls, 2)
  MiniTest.expect.equality(results, { {}, {} })
  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(notifications[1].msg:match("PyPI name search is unavailable") ~= nil, true)
  MiniTest.expect.equality(notifications[1].level, vim.log.levels.WARN)
end

T["pypi search: treats unparseable payload as failure"] = function()
  local pypi = fresh_pypi()
  local notifications = capture_notify()
  stub_curl(function(_, opts, job_id)
    -- HTTP succeeded but the markup is unrecognized (e.g. PyPI layout change).
    opts.on_stdout(job_id, { "<html><body>no recognizable package markup</body></html>" })
    opts.on_exit(job_id, 0, "exit")
  end)
  local results = nil

  pypi.search("req", function(res)
    results = res
  end)
  helpers.wait_for(function()
    return results ~= nil
  end, "search callback")

  -- A successful fetch that parses to nothing is treated as a failure: it
  -- degrades to an empty result and warns once instead of caching silence.
  MiniTest.expect.equality(results, {})
  MiniTest.expect.equality(#notifications, 1)
  MiniTest.expect.equality(notifications[1].msg:match("PyPI name search is unavailable") ~= nil, true)
end

T["pypi get: failed fetch enters backoff instead of re-requesting"] = function()
  local pypi = fresh_pypi()
  local spy = stub_curl(function(_, opts, job_id)
    opts.on_exit(job_id, 22, "exit")
  end)
  local first_result = "unset"
  local second_result = "unset"

  pypi.get("missing-pkg", function(data)
    first_result = data
  end)
  helpers.wait_for(function()
    return first_result ~= "unset"
  end, "first get")

  local cached, unavailable = pypi.get_cached("missing-pkg")
  pypi.get("missing-pkg", function(data)
    second_result = data
  end)

  MiniTest.expect.equality(first_result, nil)
  MiniTest.expect.equality(cached, nil)
  MiniTest.expect.equality(unavailable, true)
  MiniTest.expect.equality(second_result, nil)
  MiniTest.expect.equality(#spy.calls, 1)
  MiniTest.expect.equality(select(2, pypi.get_cached("../invalid-name")), true)
end

---@param time? string
---@param yanked? boolean
---@return table
local function file(time, yanked)
  return { upload_time_iso_8601 = time, yanked = yanked }
end

T["sorted_versions orders releases by their newest upload"] = function()
  local pypi = require("pydeps.providers.pypi")
  local meta = {
    releases = {
      -- A late wheel makes 1.0.0 newer than 1.1.0 even though its sdist is older.
      ["1.0.0"] = { file("2024-01-01T00:00:00"), file("2024-06-01T00:00:00") },
      ["1.1.0"] = { file("2024-03-01T00:00:00") },
      ["2.0.0"] = { file("2024-09-01T00:00:00") },
      -- Same upload time: higher version first, compared as PEP 440.
      ["9.0.0"] = { file("2024-12-01T00:00:00") },
      ["10.0.0"] = { file("2024-12-01T00:00:00") },
      -- A postrelease outranks its base, which a ">" specifier would not say.
      ["3.0"] = { file("2025-01-01T00:00:00") },
      ["3.0.post1"] = { file("2025-01-01T00:00:00") },
      ["4.0"] = { file("2025-02-01T00:00:00") },
      ["4.0.post2"] = { file("2025-02-01T00:00:00") },
      ["5.0.post1"] = { file("2025-03-01T00:00:00") },
      ["5.0"] = { file("2025-03-01T00:00:00") },
      -- Releases without files (or upload times) sort last.
      ["0.9.0"] = {},
      ["0.10.0"] = { file(nil) },
    },
  }

  MiniTest.expect.equality(pypi.sorted_versions(meta), {
    "5.0.post1",
    "5.0",
    "4.0.post2",
    "4.0",
    "3.0.post1",
    "3.0",
    "10.0.0",
    "9.0.0",
    "2.0.0",
    "1.0.0",
    "1.1.0",
    "0.10.0",
    "0.9.0",
  })
  MiniTest.expect.equality(pypi.sorted_versions(nil), {})
  MiniTest.expect.equality(pypi.sorted_versions({ info = {} }), {})
end

T["is_yanked reports a release with any yanked file"] = function()
  local pypi = require("pydeps.providers.pypi")
  local meta = {
    releases = {
      ["1.0.0"] = { file("2024-01-01T00:00:00", false), file("2024-01-02T00:00:00", true) },
      ["1.1.0"] = { file("2024-02-01T00:00:00", false) },
      ["1.2.0"] = {},
    },
  }

  MiniTest.expect.equality(pypi.is_yanked(meta, "1.0.0"), true)
  MiniTest.expect.equality(pypi.is_yanked(meta, "1.1.0"), false)
  MiniTest.expect.equality(pypi.is_yanked(meta, "1.2.0"), false)
  MiniTest.expect.equality(pypi.is_yanked(meta, "9.9.9"), false)
  MiniTest.expect.equality(pypi.is_yanked(meta, nil), false)
  MiniTest.expect.equality(pypi.is_yanked(nil, "1.0.0"), false)
end

return T
