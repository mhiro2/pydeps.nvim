---@class PyDepsAuditPackage
---@field name string
---@field version string

---@class PyDepsOSVVulnerability
---@field id string
---@field summary string
---@field severity string
---@field fixed_version? string
---@field aliases string[]

---@class PyDepsOSVCacheEntry
---@field data PyDepsOSVVulnerability[]
---@field time number
---@field failed? boolean
---@field retry_after? number

---@class PyDepsOSVPackageResult
---@field name string
---@field version string
---@field vulnerabilities PyDepsOSVVulnerability[]

local config = require("pydeps.config")
local util = require("pydeps.util")

local M = {}

local uv = vim.uv

local REQUEST_TIMEOUT = 15000
local RETRY_BACKOFF_SECONDS = 60
local OSV_BATCH_SIZE = 100

---@type table<string, PyDepsOSVCacheEntry>
local cache = {}

---@param name? string
---@return string?
local function normalize_name(name)
  local normalized = util.parse_requirement_name(name)
  if not normalized then
    return nil
  end
  return normalized:lower()
end

---@param version any
---@return string?
local function normalize_version(version)
  if version == nil then
    return nil
  end
  local v = util.trim(tostring(version))
  if v == "" then
    return nil
  end
  return v
end

---@param name string
---@return boolean
local function is_valid_package_name(name)
  return name:match("^[a-z0-9][a-z0-9%._-]*$") ~= nil
end

---@param name string
---@param version string
---@return string
local function cache_key(name, version)
  return string.format("%s@%s", name, version)
end

---@param name string
---@param version string
---@return PyDepsOSVVulnerability[]?, boolean
local function cached_entry(name, version)
  local key = cache_key(name, version)
  local entry = cache[key]
  if not entry then
    return nil, false
  end
  if entry.failed and entry.retry_after and util.now() < entry.retry_after then
    return nil, true
  end
  if not entry.failed and (util.now() - entry.time) > (config.options.osv_cache_ttl or 3600) then
    cache[key] = nil
    return nil, false
  end
  if entry.failed and entry.retry_after and util.now() >= entry.retry_after then
    cache[key] = nil
    return nil, false
  end
  return entry.data or {}, false
end

---@param name string
---@param version string
---@param vulnerabilities PyDepsOSVVulnerability[]?
---@param failed? boolean
---@return nil
local function set_cache(name, version, vulnerabilities, failed)
  local entry = { data = vulnerabilities or {}, time = util.now() }
  if failed then
    entry.failed = true
    entry.retry_after = util.now() + RETRY_BACKOFF_SECONDS
  end
  cache[cache_key(name, version)] = entry
end

---@param score? string
---@return string?
local function severity_from_score(score)
  if not score or score == "" then
    return nil
  end
  local numeric = tonumber(score:match("%d+%.?%d*"))
  if not numeric then
    return nil
  end
  if numeric >= 9.0 then
    return "CRITICAL"
  end
  if numeric >= 7.0 then
    return "HIGH"
  end
  if numeric >= 4.0 then
    return "MEDIUM"
  end
  if numeric > 0.0 then
    return "LOW"
  end
  return "UNKNOWN"
end

---@param fixed any
---@param seen table<string, boolean>
---@param versions string[]
---@return nil
local function add_fixed_values(fixed, seen, versions)
  if type(fixed) == "string" then
    local value = util.trim(fixed)
    if value ~= "" and not seen[value] then
      seen[value] = true
      table.insert(versions, value)
    end
    return
  end
  if type(fixed) ~= "table" then
    return
  end
  for _, value in ipairs(fixed) do
    if type(value) == "string" then
      local normalized = util.trim(value)
      if normalized ~= "" and not seen[normalized] then
        seen[normalized] = true
        table.insert(versions, normalized)
      end
    end
  end
end

---@param vulnerability table
---@param package_name string
---@return string?
local function extract_fixed_version(vulnerability, package_name)
  local versions = {}
  local seen = {}

  local db_specific = vulnerability.database_specific
  if type(db_specific) == "table" then
    add_fixed_values(db_specific.fixed, seen, versions)
  end

  local affected = vulnerability.affected
  if type(affected) == "table" then
    for _, affected_item in ipairs(affected) do
      local same_package = true
      if type(affected_item.package) == "table" and affected_item.package.name then
        same_package = normalize_name(affected_item.package.name) == package_name
      end
      if same_package and type(affected_item.ranges) == "table" then
        for _, range in ipairs(affected_item.ranges) do
          if type(range.events) == "table" then
            for _, event in ipairs(range.events) do
              add_fixed_values(event.fixed, seen, versions)
            end
          end
        end
      end
    end
  end

  table.sort(versions)
  if #versions == 0 then
    return nil
  end
  return table.concat(versions, ", ")
end

---@param vulnerability table
---@return string
local function extract_severity(vulnerability)
  local db_specific = vulnerability.database_specific
  if type(db_specific) == "table" and type(db_specific.severity) == "string" and db_specific.severity ~= "" then
    return db_specific.severity:upper()
  end

  local best = nil
  local severity_items = vulnerability.severity
  if type(severity_items) == "table" then
    for _, item in ipairs(severity_items) do
      if type(item) == "table" then
        local from_score = severity_from_score(item.score)
        if from_score then
          best = from_score
          if best == "CRITICAL" then
            break
          end
        elseif type(item.type) == "string" and item.type ~= "" then
          best = item.type:upper()
        end
      end
    end
  end

  return best or "UNKNOWN"
end

---@param vulnerability table
---@param package_name string
---@return PyDepsOSVVulnerability
local function normalize_vulnerability(vulnerability, package_name)
  local aliases = {}
  if type(vulnerability.aliases) == "table" then
    for _, alias in ipairs(vulnerability.aliases) do
      if type(alias) == "string" and alias ~= "" then
        table.insert(aliases, alias)
      end
    end
  end

  local id = vulnerability.id
  if type(id) ~= "string" or id == "" then
    id = aliases[1] or "UNKNOWN"
  end

  local summary = util.trim(vulnerability.summary or "")
  if summary == "" and type(vulnerability.details) == "string" then
    summary = util.trim(vulnerability.details:match("^[^\n]+") or vulnerability.details)
  end
  if summary == "" then
    summary = "(no summary)"
  end

  return {
    id = id,
    summary = summary,
    severity = extract_severity(vulnerability),
    fixed_version = extract_fixed_version(vulnerability, package_name),
    aliases = aliases,
  }
end

---@param severity string
---@return integer
local function severity_rank(severity)
  local key = severity and severity:upper() or "UNKNOWN"
  if key == "CRITICAL" then
    return 4
  end
  if key == "HIGH" then
    return 3
  end
  if key == "MEDIUM" then
    return 2
  end
  if key == "LOW" then
    return 1
  end
  return 0
end

---@param a PyDepsOSVVulnerability
---@param b PyDepsOSVVulnerability
---@return boolean
local function vuln_sorter(a, b)
  local rank_a = severity_rank(a.severity)
  local rank_b = severity_rank(b.severity)
  if rank_a ~= rank_b then
    return rank_a > rank_b
  end
  return a.id < b.id
end

---@param payload string
---@return table?, string?
local function decode_json(payload)
  local ok, decoded = pcall(vim.json.decode, payload)
  if not ok then
    return nil, "failed to parse OSV response"
  end
  if type(decoded) ~= "table" then
    return nil, "invalid OSV response"
  end
  return decoded, nil
end

---@return string?
local function resolve_python()
  if vim.fn.executable("python3") == 1 then
    return "python3"
  end
  if vim.fn.executable("python") == 1 then
    return "python"
  end
  return nil
end

---@param payload string
---@return string[]?, string?
local function build_request_cmd(payload)
  local url = config.options.osv_url or "https://api.osv.dev/v1/querybatch"
  if vim.fn.executable("curl") == 1 then
    return {
      "curl",
      "-fsSL",
      "-X",
      "POST",
      "-H",
      "Content-Type: application/json",
      "--data-binary",
      payload,
      url,
    },
      nil
  end

  local python = resolve_python()
  if python then
    local script = table.concat({
      "import sys,urllib.request",
      "url=sys.argv[1]",
      "payload=sys.argv[2].encode('utf-8')",
      "req=urllib.request.Request(url,data=payload,headers={'Content-Type':'application/json'})",
      "with urllib.request.urlopen(req, timeout=15) as r:",
      "  print(r.read().decode('utf-8'))",
    }, "\n")
    return { python, "-c", script, url, payload }, nil
  end

  return nil, "pydeps: curl/python not found; OSV audit disabled"
end

---@param payload string
---@param cb fun(decoded: table?, err: string?)
---@return nil
local function run_request(payload, cb)
  local cmd, cmd_err = build_request_cmd(payload)
  if not cmd then
    vim.notify(cmd_err or "pydeps: OSV request failed", vim.log.levels.WARN)
    cb(nil, cmd_err)
    return
  end

  local stdout = {}
  local stderr = {}
  local completed = false
  local timer = nil

  ---@param decoded table?
  ---@param err string?
  local function finish(decoded, err)
    if completed then
      return
    end
    completed = true
    util.safe_close_timer(timer)
    timer = nil
    vim.schedule(function()
      cb(decoded, err)
    end)
  end

  local job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        vim.list_extend(stdout, data)
      end
    end,
    on_stderr = function(_, data)
      if data then
        vim.list_extend(stderr, data)
      end
    end,
    on_exit = function(_, code)
      local payload_out = table.concat(stdout, "\n")
      if code ~= 0 then
        local err_out = util.trim(table.concat(stderr, "\n"))
        if err_out == "" then
          err_out = "request failed with exit code " .. tostring(code)
        end
        finish(nil, err_out)
        return
      end
      if payload_out == "" then
        finish(nil, "empty response from OSV")
        return
      end
      local decoded, decode_err = decode_json(payload_out)
      finish(decoded, decode_err)
    end,
  })

  if job_id <= 0 then
    finish(nil, "failed to start OSV request")
    return
  end

  timer = uv.new_timer()
  timer:start(REQUEST_TIMEOUT, 0, function()
    util.safe_close_timer(timer)
    timer = nil
    if completed then
      return
    end
    completed = true
    vim.schedule(function()
      vim.fn.jobstop(job_id)
      cb(nil, "OSV request timed out")
    end)
  end)
end

---@param packages PyDepsAuditPackage[]
---@return PyDepsAuditPackage[]
local function normalize_packages(packages)
  local normalized = {}
  local seen = {}
  for _, package in ipairs(packages or {}) do
    local name = normalize_name(package.name)
    local version = normalize_version(package.version)
    if name and version and is_valid_package_name(name) then
      local key = cache_key(name, version)
      if not seen[key] then
        seen[key] = true
        table.insert(normalized, {
          name = name,
          version = version,
        })
      end
    end
  end
  return normalized
end

---@param decoded table
---@param batch PyDepsAuditPackage[]
---@return table<string, PyDepsOSVVulnerability[]>?, string?
local function parse_batch_results(decoded, batch)
  if type(decoded.results) ~= "table" then
    return nil, "invalid OSV response: 'results' field is missing"
  end

  ---@type table<string, PyDepsOSVVulnerability[]>
  local result_map = {}
  for index, package in ipairs(batch) do
    local row = decoded.results[index]
    local vulnerabilities = {}
    if type(row) == "table" and type(row.vulns) == "table" then
      for _, vulnerability in ipairs(row.vulns) do
        if type(vulnerability) == "table" then
          table.insert(vulnerabilities, normalize_vulnerability(vulnerability, package.name))
        end
      end
    end
    table.sort(vulnerabilities, vuln_sorter)
    result_map[cache_key(package.name, package.version)] = vulnerabilities
    set_cache(package.name, package.version, vulnerabilities, false)
  end

  return result_map, nil
end

---@param packages PyDepsAuditPackage[]
---@return PyDepsAuditPackage[][]
local function split_batches(packages)
  local batches = {}
  local index = 1
  while index <= #packages do
    local batch = {}
    for i = index, math.min(index + OSV_BATCH_SIZE - 1, #packages) do
      table.insert(batch, packages[i])
    end
    table.insert(batches, batch)
    index = index + OSV_BATCH_SIZE
  end
  return batches
end

---@param batch PyDepsAuditPackage[]
---@param cb fun(result_map: table<string, PyDepsOSVVulnerability[]>?, err: string?)
---@return nil
local function request_batch(batch, cb)
  local queries = {}
  for _, package in ipairs(batch) do
    table.insert(queries, {
      package = {
        ecosystem = "PyPI",
        name = package.name,
      },
      version = package.version,
    })
  end

  local ok, payload = pcall(vim.json.encode, { queries = queries })
  if not ok then
    for _, package in ipairs(batch) do
      set_cache(package.name, package.version, nil, true)
    end
    cb(nil, "failed to encode OSV query payload")
    return
  end

  run_request(payload, function(decoded, request_err)
    if request_err or not decoded then
      for _, package in ipairs(batch) do
        set_cache(package.name, package.version, nil, true)
      end
      cb(nil, request_err or "OSV request failed")
      return
    end

    local result_map, parse_err = parse_batch_results(decoded, batch)
    if parse_err or not result_map then
      for _, package in ipairs(batch) do
        set_cache(package.name, package.version, nil, true)
      end
      cb(nil, parse_err or "failed to parse OSV response")
      return
    end

    cb(result_map, nil)
  end)
end

---@param packages PyDepsAuditPackage[]
---@param result_map table<string, PyDepsOSVVulnerability[]>
---@return PyDepsOSVPackageResult[]
local function to_ordered_results(packages, result_map)
  local results = {}
  for _, package in ipairs(packages) do
    local key = cache_key(package.name, package.version)
    table.insert(results, {
      name = package.name,
      version = package.version,
      vulnerabilities = result_map[key] or {},
    })
  end
  return results
end

---@param name string
---@param version string
---@return PyDepsOSVVulnerability[]?
function M.get_cached(name, version)
  local normalized_name = normalize_name(name)
  local normalized_version = normalize_version(version)
  if not normalized_name or not normalized_version then
    return nil
  end
  local data, _ = cached_entry(normalized_name, normalized_version)
  return data
end

---@param packages PyDepsAuditPackage[]
---@param cb fun(results: PyDepsOSVPackageResult[], err: string?)
---@return nil
function M.audit(packages, cb)
  local normalized_packages = normalize_packages(packages)
  if #normalized_packages == 0 then
    cb({}, nil)
    return
  end

  ---@type table<string, PyDepsOSVVulnerability[]>
  local result_map = {}
  local pending = {}

  for _, package in ipairs(normalized_packages) do
    local key = cache_key(package.name, package.version)
    local cached, is_backoff = cached_entry(package.name, package.version)
    if cached then
      result_map[key] = cached
    elseif is_backoff then
      result_map[key] = {}
    else
      table.insert(pending, package)
    end
  end

  if #pending == 0 then
    cb(to_ordered_results(normalized_packages, result_map), nil)
    return
  end

  local batches = split_batches(pending)
  local batch_index = 1

  local function run_next_batch()
    if batch_index > #batches then
      cb(to_ordered_results(normalized_packages, result_map), nil)
      return
    end

    request_batch(batches[batch_index], function(batch_result_map, err)
      if batch_result_map then
        for key, vulnerabilities in pairs(batch_result_map) do
          result_map[key] = vulnerabilities
        end
      end
      if err then
        cb(to_ordered_results(normalized_packages, result_map), err)
        return
      end
      batch_index = batch_index + 1
      run_next_batch()
    end)
  end

  run_next_batch()
end

---@private
---@return nil
function M._clear_cache()
  cache = {}
end

return M
