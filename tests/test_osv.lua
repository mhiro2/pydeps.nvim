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

---Install a curl-backed jobstart stub that maps a request URL to a response.
---@param routes { pattern: string, body: string|false }[]
---@return table state -- { urls = string[] }
---@return fun() restore
local function stub_requests(routes)
  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart
  local state = { urls = {} }

  vim.fn.executable = function(cmd)
    return cmd == "curl" and 1 or 0
  end

  vim.fn.jobstart = function(cmd, opts)
    local url = cmd[#cmd]
    table.insert(state.urls, url)

    local body = nil
    local matched = false
    for _, route in ipairs(routes) do
      if url:match(route.pattern) then
        body = type(route.body) == "function" and route.body(cmd) or route.body
        matched = true
        break
      end
    end

    vim.schedule(function()
      if matched and body ~= false then
        opts.on_stdout(nil, { body })
        opts.on_exit(nil, 0, nil)
      else
        -- Simulate a failed request (non-zero exit, no stdout).
        opts.on_exit(nil, 1, nil)
      end
    end)
    return 1
  end

  return state, function()
    vim.fn.executable = original_executable
    vim.fn.jobstart = original_jobstart
  end
end

---@param packages PyDepsAuditPackage[]
---@return PyDepsOSVPackageResult[], string?
local function run_audit(packages)
  local osv = require("pydeps.providers.osv")
  local captured_results = nil
  local captured_error = nil

  osv.audit(packages, function(results, err)
    captured_results = results
    captured_error = err
  end)

  vim.wait(1000, function()
    return captured_results ~= nil
  end, 10)

  return captured_results, captured_error
end

T["audit hydrates vulnerability details from the vulns endpoint"] = function()
  local osv = require("pydeps.providers.osv")
  osv._clear_cache()

  -- querybatch returns id stubs only; details come from /v1/vulns/{id}.
  local state, restore = stub_requests({
    {
      pattern = "querybatch$",
      body = '{"results":[{"vulns":[{"id":"GHSA-0001","modified":"2024-01-01T00:00:00Z"}]},{"vulns":[]}]}',
    },
    {
      pattern = "/vulns/GHSA%-0001$",
      body = '{"id":"GHSA-0001","summary":"test vulnerability","database_specific":{"severity":"HIGH"},'
        .. '"affected":[{"package":{"name":"requests"},"ranges":[{"events":[{"introduced":"0"},{"fixed":"2.31.2"}]}]}]}',
    },
  })

  local results, err = run_audit({
    { name = "requests", version = "2.31.0" },
    { name = "urllib3", version = "2.2.0" },
  })

  restore()

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(#results, 2)
  MiniTest.expect.equality(results[1].name, "requests")
  MiniTest.expect.equality(#results[1].vulnerabilities, 1)

  local vuln = results[1].vulnerabilities[1]
  MiniTest.expect.equality(vuln.id, "GHSA-0001")
  MiniTest.expect.equality(vuln.severity, "HIGH")
  MiniTest.expect.equality(vuln.summary, "test vulnerability")
  MiniTest.expect.equality(vuln.fixed_version, "2.31.2")
  MiniTest.expect.equality(#results[2].vulnerabilities, 0)

  -- One querybatch request plus one hydration request for the single id.
  MiniTest.expect.equality(#state.urls, 2)
  MiniTest.expect.equality(state.urls[1]:match("querybatch$") ~= nil, true)
  MiniTest.expect.equality(state.urls[2]:match("/vulns/GHSA%-0001$") ~= nil, true)
end

T["audit surfaces advisory id when hydration fails"] = function()
  local osv = require("pydeps.providers.osv")
  osv._clear_cache()

  -- querybatch succeeds but the vulns endpoint fails: the advisory must still
  -- surface (with UNKNOWN severity) rather than disappear.
  local _, restore = stub_requests({
    {
      pattern = "querybatch$",
      body = '{"results":[{"vulns":[{"id":"PYSEC-2024-1","modified":"2024-01-01T00:00:00Z"}]}]}',
    },
    { pattern = "/vulns/", body = false },
  })

  local results, err = run_audit({
    { name = "requests", version = "2.31.0" },
  })

  restore()

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(#results, 1)
  MiniTest.expect.equality(#results[1].vulnerabilities, 1)

  local vuln = results[1].vulnerabilities[1]
  MiniTest.expect.equality(vuln.id, "PYSEC-2024-1")
  MiniTest.expect.equality(vuln.severity, "UNKNOWN")
  MiniTest.expect.equality(vuln.summary, "(no summary)")
  MiniTest.expect.equality(vuln.fixed_version, nil)
end

T["audit skips hydration when no vulnerabilities are reported"] = function()
  local osv = require("pydeps.providers.osv")
  osv._clear_cache()

  local state, restore = stub_requests({
    { pattern = "querybatch$", body = '{"results":[{"vulns":[]}]}' },
  })

  local results, err = run_audit({
    { name = "requests", version = "2.31.0" },
  })

  restore()

  MiniTest.expect.equality(err, nil)
  MiniTest.expect.equality(#results, 1)
  MiniTest.expect.equality(#results[1].vulnerabilities, 0)
  -- No vulns means no hydration requests are issued.
  MiniTest.expect.equality(#state.urls, 1)
end

T["audit reuses the hydrated result without re-requesting"] = function()
  local osv = require("pydeps.providers.osv")
  osv._clear_cache()

  local state, restore = stub_requests({
    {
      pattern = "querybatch$",
      body = '{"results":[{"vulns":[{"id":"GHSA-0001","modified":"2024-01-01T00:00:00Z"}]}]}',
    },
    {
      pattern = "/vulns/GHSA%-0001$",
      body = '{"id":"GHSA-0001","summary":"test vulnerability","database_specific":{"severity":"HIGH"}}',
    },
  })

  run_audit({ { name = "requests", version = "2.31.0" } })
  -- querybatch + one hydration request.
  MiniTest.expect.equality(#state.urls, 2)

  local results = run_audit({ { name = "requests", version = "2.31.0" } })

  restore()

  -- Fully hydrated results are cached, so the second audit issues no requests.
  MiniTest.expect.equality(#state.urls, 2)
  MiniTest.expect.equality(results[1].vulnerabilities[1].severity, "HIGH")
end

T["audit reuses cache for same package/version"] = function()
  local osv = require("pydeps.providers.osv")
  osv._clear_cache()

  local state, restore = stub_requests({
    { pattern = "querybatch$", body = '{"results":[{"vulns":[]}]}' },
  })

  run_audit({ { name = "requests", version = "2.31.0" } })
  run_audit({ { name = "requests", version = "2.31.0" } })

  restore()

  -- Second audit is served from cache, so only one request is made.
  MiniTest.expect.equality(#state.urls, 1)
end

T["audit skips invalid package names"] = function()
  local osv = require("pydeps.providers.osv")
  osv._clear_cache()

  local state, restore = stub_requests({
    { pattern = "querybatch$", body = '{"results":[{"vulns":[]}]}' },
  })

  local results, err = run_audit({
    { name = "../invalid", version = "1.0.0" },
  })

  restore()

  MiniTest.expect.equality(#state.urls, 0)
  MiniTest.expect.equality(#results, 0)
  MiniTest.expect.equality(err, nil)
end

T["failed audits retain their reason during backoff"] = function()
  local state, restore = stub_requests({ { pattern = "querybatch$", body = false } })
  local packages = { { name = "demo", version = "1" } }
  local first, first_error = run_audit(packages)
  local second, second_error = run_audit(packages)
  restore()
  MiniTest.expect.equality(#state.urls, 1)
  MiniTest.expect.equality(first[1].status, "failed")
  MiniTest.expect.equality(second[1].status, "failed")
  MiniTest.expect.equality(second_error, first_error)
  MiniTest.expect.equality(type(second_error), "string")
  MiniTest.expect.equality(second[1].error, first_error)
end

T["malformed batch results never become clean results"] = function()
  for _, body in ipairs({
    '{"results":[]}',
    '{"results":[null]}',
    '{"results":[[]]}',
    '{"results":[42]}',
    '{"results":[{"vulns":{}}]}',
    '{"results":[{"vulns":[{}]}]}',
    '{"results":[{},{}]}',
    '{"results":{}}',
  }) do
    require("pydeps.providers.osv")._clear_cache()
    local _, restore = stub_requests({ { pattern = "querybatch$", body = body } })
    local results, err = run_audit({ { name = "demo", version = "1" } })
    restore()
    MiniTest.expect.equality(results[1].status, "failed")
    MiniTest.expect.equality(type(err), "string")
  end
end

T["partial batch failures preserve successful scans and continue"] = function()
  local calls = 0
  local _, restore = stub_requests({
    {
      pattern = "querybatch$",
      body = function()
        calls = calls + 1
        if calls == 1 then
          return "invalid json"
        end
        return '{"results":[{}]}'
      end,
    },
  })
  local packages = {}
  for i = 1, 101 do
    packages[i] = { name = "demo" .. i, version = "1" }
  end
  local results, err = run_audit(packages)
  restore()
  MiniTest.expect.equality(calls, 2)
  MiniTest.expect.equality(type(err), "string")
  MiniTest.expect.equality(results[1].status, "failed")
  MiniTest.expect.equality(results[101].status, "clean")
end

T["audit report excludes failed packages from scanned totals"] = function()
  local output = require("pydeps.ui.output")
  local original_show = output.show
  local lines
  output.show = function(_, content)
    lines = content
  end
  local summary = require("pydeps.ui.security_audit").show({
    { name = "a", version = "1", status = "clean", vulnerabilities = {} },
    { name = "b", version = "1", status = "failed", error = "offline", vulnerabilities = {} },
    { name = "c", version = "1", status = "not_scanned", vulnerabilities = {} },
  })
  output.show = original_show
  MiniTest.expect.equality(summary.scanned_packages, 1)
  MiniTest.expect.equality(summary.failed_packages, 1)
  MiniTest.expect.equality(summary.not_scanned_packages, 1)
  MiniTest.expect.equality(table.concat(lines, "\n"):find("No known vulnerabilities", 1, true), nil)
end

T["CVSS vectors remain unknown and retain original evaluations"] = function()
  for _, evaluation in ipairs({
    { type = "CVSS_V2", score = "AV:N/AC:L/Au:N/C:C/I:C/A:C" },
    { type = "CVSS_V3", score = "CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H" },
    { type = "CVSS_V4", score = "CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N" },
  }) do
    require("pydeps.providers.osv")._clear_cache()
    local _, restore = stub_requests({
      { pattern = "querybatch$", body = '{"results":[{"vulns":[{"id":"TEST-1"}]}]}' },
      { pattern = "/vulns/", body = vim.json.encode({ id = "TEST-1", severity = { evaluation } }) },
    })
    local results = run_audit({ { name = "demo", version = "1" } })
    restore()
    MiniTest.expect.equality(results[1].vulnerabilities[1].severity, "UNKNOWN")
    MiniTest.expect.equality(results[1].vulnerabilities[1].severity_scores, { evaluation })
  end
end

T["severity aggregation keeps highest recognized evaluation regardless of order"] = function()
  for _, scores in ipairs({ { "8.0", "3.0" }, { "3.0", "8.0" } }) do
    require("pydeps.providers.osv")._clear_cache()
    local _, restore = stub_requests({
      { pattern = "querybatch$", body = '{"results":[{"vulns":[{"id":"TEST-1"}]}]}' },
      {
        pattern = "/vulns/",
        body = vim.json.encode({
          id = "TEST-1",
          database_specific = { severity = "LOW" },
          severity = {
            { type = "CVSS_V3", score = scores[1] },
            { type = "CVSS_V3", score = scores[2] },
            { type = "CVSS_V4", score = "CVSS:4.0/AV:N" },
            { type = "OTHER", score = "10.0" },
          },
        }),
      },
    })
    local results = run_audit({ { name = "demo", version = "1" } })
    restore()
    MiniTest.expect.equality(results[1].vulnerabilities[1].severity, "HIGH")
  end
end

return T
