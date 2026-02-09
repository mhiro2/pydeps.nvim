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

return T
