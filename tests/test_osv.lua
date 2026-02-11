local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.providers.osv"] = nil
      require("pydeps.config").setup({
        osv_url = "https://api.osv.dev/v1/querybatch",
        osv_cache_ttl = 3600,
      })
    end,
  },
})

T["osv audit: requests and parses vulnerabilities"] = function()
  local osv = require("pydeps.providers.osv")
  osv._clear_cache()

  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local captured_cmd = nil
  local captured_results = nil
  local captured_error = nil

  vim.fn.executable = function(cmd)
    if cmd == "curl" then
      return 1
    end
    return 0
  end

  vim.fn.jobstart = function(cmd, opts)
    captured_cmd = cmd
    vim.schedule(function()
      opts.on_stdout(nil, {
        '{"results":[{"vulns":[{"id":"GHSA-0001","summary":"test vulnerability","database_specific":{"severity":"HIGH"},"affected":[{"package":{"name":"requests"},"ranges":[{"events":[{"introduced":"0"},{"fixed":"2.31.2"}]}]}]}]},{"vulns":[]}]}',
      })
      opts.on_exit(nil, 0, nil)
    end)
    return 1
  end

  osv.audit({
    { name = "requests", version = "2.31.0" },
    { name = "urllib3", version = "2.2.0" },
  }, function(results, err)
    captured_results = results
    captured_error = err
  end)

  vim.wait(500, function()
    return captured_results ~= nil
  end, 10)

  MiniTest.expect.equality(captured_cmd ~= nil, true)
  MiniTest.expect.equality(captured_cmd[1], "curl")
  MiniTest.expect.equality(captured_cmd[#captured_cmd]:match("querybatch$") ~= nil, true)
  MiniTest.expect.equality(captured_error, nil)
  MiniTest.expect.equality(#captured_results, 2)
  MiniTest.expect.equality(captured_results[1].name, "requests")
  MiniTest.expect.equality(#captured_results[1].vulnerabilities, 1)
  MiniTest.expect.equality(captured_results[1].vulnerabilities[1].severity, "HIGH")
  MiniTest.expect.equality(captured_results[1].vulnerabilities[1].fixed_version, "2.31.2")

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

T["osv audit: reuses cache for same package/version"] = function()
  local osv = require("pydeps.providers.osv")
  osv._clear_cache()

  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local jobstart_calls = 0
  local first_done = false
  local second_done = false

  vim.fn.executable = function(cmd)
    if cmd == "curl" then
      return 1
    end
    return 0
  end

  vim.fn.jobstart = function(_, opts)
    jobstart_calls = jobstart_calls + 1
    vim.schedule(function()
      opts.on_stdout(nil, { '{"results":[{"vulns":[]}]}' })
      opts.on_exit(nil, 0, nil)
    end)
    return 1
  end

  osv.audit({
    { name = "requests", version = "2.31.0" },
  }, function()
    first_done = true
  end)

  vim.wait(500, function()
    return first_done
  end, 10)

  osv.audit({
    { name = "requests", version = "2.31.0" },
  }, function()
    second_done = true
  end)

  vim.wait(500, function()
    return second_done
  end, 10)

  MiniTest.expect.equality(jobstart_calls, 1)

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

T["osv audit: skips invalid package names"] = function()
  local osv = require("pydeps.providers.osv")
  osv._clear_cache()

  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local jobstart_called = false
  local captured_results = nil
  local captured_error = "unset"

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

  osv.audit({
    { name = "../invalid", version = "1.0.0" },
  }, function(results, err)
    captured_results = results
    captured_error = err
  end)

  MiniTest.expect.equality(jobstart_called, false)
  MiniTest.expect.equality(#captured_results, 0)
  MiniTest.expect.equality(captured_error, nil)

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

return T
