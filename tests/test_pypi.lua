local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

T["pypi get: skips invalid package names"] = function()
  package.loaded["pydeps.providers.pypi"] = nil
  local pypi = require("pydeps.providers.pypi")

  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local jobstart_called = false
  local callback_result = "unset"

  vim.fn.executable = function(cmd)
    if cmd == "curl" then
      return 1
    end
    return 0
  end
  vim.fn.jobstart = function()
    jobstart_called = true
    return 1
  end

  pypi.get("../invalid-name", function(data)
    callback_result = data
  end)

  MiniTest.expect.equality(jobstart_called, false)
  MiniTest.expect.equality(callback_result, nil)

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

T["pypi get: requests valid package names"] = function()
  package.loaded["pydeps.providers.pypi"] = nil
  local pypi = require("pydeps.providers.pypi")

  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local captured_cmd = nil
  local callback_result = nil

  vim.fn.executable = function(cmd)
    if cmd == "curl" then
      return 1
    end
    return 0
  end
  vim.fn.jobstart = function(cmd, opts)
    captured_cmd = cmd
    vim.schedule(function()
      opts.on_stdout(nil, { '{"info":{"version":"1.2.3"' })
      opts.on_stdout(nil, { "}}" })
      opts.on_exit(nil, 0, nil)
    end)
    return 1
  end

  pypi.get("valid-name", function(data)
    callback_result = data
  end)

  vim.wait(200, function()
    return callback_result ~= nil
  end, 10)

  MiniTest.expect.equality(captured_cmd ~= nil, true)
  MiniTest.expect.equality(captured_cmd[1], "curl")
  MiniTest.expect.equality(captured_cmd[3]:match("/valid%-name/json$") ~= nil, true)
  MiniTest.expect.equality(callback_result.info.version, "1.2.3")

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

T["pypi get: keeps decoded payload when stderr has chunks"] = function()
  package.loaded["pydeps.providers.pypi"] = nil
  local pypi = require("pydeps.providers.pypi")

  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local callback_result = "unset"

  vim.fn.executable = function(cmd)
    if cmd == "curl" then
      return 1
    end
    return 0
  end
  vim.fn.jobstart = function(_, opts)
    vim.schedule(function()
      opts.on_stdout(nil, { '{"info":{"version":"1.2.3"}}' })
      opts.on_stderr(nil, { "first error" })
      opts.on_stderr(nil, { "" })
      opts.on_exit(nil, 0, nil)
    end)
    return 1
  end

  pypi.get("valid-name", function(data)
    callback_result = data
  end)

  vim.wait(200, function()
    return callback_result ~= "unset"
  end, 10)

  MiniTest.expect.equality(callback_result ~= nil, true)
  MiniTest.expect.equality(callback_result.info.version, "1.2.3")

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

T["pypi search: returns results and reuses cache"] = function()
  package.loaded["pydeps.providers.pypi"] = nil
  local pypi = require("pydeps.providers.pypi")

  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local jobstart_calls = 0
  local captured_cmd = nil
  local first_results = nil
  local second_results = nil

  vim.fn.executable = function(cmd)
    if cmd == "curl" then
      return 1
    end
    return 0
  end
  vim.fn.jobstart = function(cmd, opts)
    jobstart_calls = jobstart_calls + 1
    captured_cmd = cmd
    vim.schedule(function()
      opts.on_stdout(nil, { '<span class="package-snippet__name">requests</span>' })
      opts.on_stdout(nil, { '<span class="package-snippet__name">requests-toolbelt</span>' })
      opts.on_exit(nil, 0, nil)
    end)
    return 1
  end

  pypi.search("req", function(results)
    first_results = results
  end)

  vim.wait(200, function()
    return first_results ~= nil
  end, 10)

  pypi.search("req", function(results)
    second_results = results
  end)

  MiniTest.expect.equality(jobstart_calls, 1)
  MiniTest.expect.equality(captured_cmd[#captured_cmd]:match("/search/%?q=req") ~= nil, true)
  MiniTest.expect.equality(captured_cmd[#captured_cmd]:match("/simple/") == nil, true)
  MiniTest.expect.equality(vim.deep_equal(first_results, { "requests", "requests-toolbelt" }), true)
  MiniTest.expect.equality(vim.deep_equal(second_results, { "requests", "requests-toolbelt" }), true)

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

T["pypi search: serves all callbacks during in-flight request"] = function()
  package.loaded["pydeps.providers.pypi"] = nil
  local pypi = require("pydeps.providers.pypi")

  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local jobstart_calls = 0
  local first_results = nil
  local second_results = nil

  vim.fn.executable = function(cmd)
    if cmd == "curl" then
      return 1
    end
    return 0
  end
  vim.fn.jobstart = function(_, opts)
    jobstart_calls = jobstart_calls + 1
    vim.schedule(function()
      opts.on_stdout(nil, { '<span class="package-snippet__name">requests</span>' })
      opts.on_stdout(nil, { '<span class="package-snippet__name">requests-toolbelt</span>' })
      opts.on_exit(nil, 0, nil)
    end)
    return 1
  end

  pypi.search("req", function(results)
    first_results = results
  end)
  pypi.search("req", function(results)
    second_results = results
  end)

  vim.wait(200, function()
    return first_results ~= nil and second_results ~= nil
  end, 10)

  MiniTest.expect.equality(jobstart_calls, 1)
  MiniTest.expect.equality(vim.deep_equal(first_results, { "requests", "requests-toolbelt" }), true)
  MiniTest.expect.equality(vim.deep_equal(second_results, { "requests", "requests-toolbelt" }), true)

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

T["pypi search: retries after failure backoff"] = function()
  package.loaded["pydeps.providers.pypi"] = nil
  local util = require("pydeps.util")
  local pypi = require("pydeps.providers.pypi")

  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local original_now = util.now
  local now = 1000
  local jobstart_calls = 0
  local first_results = nil
  local second_results = nil
  local third_results = nil

  util.now = function()
    return now
  end
  vim.fn.executable = function(cmd)
    if cmd == "curl" then
      return 1
    end
    return 0
  end
  vim.fn.jobstart = function(_, opts)
    jobstart_calls = jobstart_calls + 1
    local current_call = jobstart_calls
    vim.schedule(function()
      if current_call == 1 then
        opts.on_stderr(nil, { "temporary error" })
        opts.on_exit(nil, 1, nil)
        return
      end
      opts.on_stdout(nil, { '<span class="package-snippet__name">requests</span>' })
      opts.on_exit(nil, 0, nil)
    end)
    return 1
  end

  pypi.search("req", function(results)
    first_results = results
  end)
  vim.wait(200, function()
    return first_results ~= nil
  end, 10)

  pypi.search("req", function(results)
    second_results = results
  end)

  now = now + 61
  pypi.search("req", function(results)
    third_results = results
  end)
  vim.wait(200, function()
    return third_results ~= nil
  end, 10)

  MiniTest.expect.equality(vim.deep_equal(first_results, {}), true)
  MiniTest.expect.equality(vim.deep_equal(second_results, {}), true)
  MiniTest.expect.equality(vim.deep_equal(third_results, { "requests" }), true)
  MiniTest.expect.equality(jobstart_calls, 2)

  util.now = original_now
  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

return T
