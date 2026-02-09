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
      opts.on_stdout(nil, { '{"info":{"version":"1.2.3"}}' })
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

T["pypi search: uses simple api and caches index"] = function()
  package.loaded["pydeps.providers.pypi"] = nil
  local pypi = require("pydeps.providers.pypi")

  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local jobstart_calls = 0
  local captured_script = nil
  local first_results = nil
  local second_results = nil

  vim.fn.executable = function(cmd)
    if cmd == "python3" then
      return 1
    end
    return 0
  end
  vim.fn.jobstart = function(cmd, opts)
    jobstart_calls = jobstart_calls + 1
    captured_script = cmd[3]
    vim.schedule(function()
      opts.on_stdout(nil, { '["pytest","requests","requests-toolbelt","rich"]' })
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

  pypi.search("requ", function(results)
    second_results = results
  end)
  vim.wait(200, function()
    return second_results ~= nil
  end, 10)

  MiniTest.expect.equality(jobstart_calls, 1)
  MiniTest.expect.equality(captured_script:match("application/vnd.pypi.simple.v1%+json") ~= nil, true)
  MiniTest.expect.equality(captured_script:match("xmlrpc%.client") == nil, true)
  MiniTest.expect.equality(vim.deep_equal(first_results, { "requests", "requests-toolbelt" }), true)
  MiniTest.expect.equality(vim.deep_equal(second_results, { "requests", "requests-toolbelt" }), true)

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

return T
