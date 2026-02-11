---@class PyDepsOSVAuditSummary
---@field scanned_packages integer
---@field vulnerable_packages integer
---@field total_vulnerabilities integer

---@class PyDepsOSVAuditShowOptions
---@field root? string
---@field error? string

local config = require("pydeps.config")
local output = require("pydeps.ui.output")

local M = {}

---@param vulnerability PyDepsOSVVulnerability
---@return string
local function format_vulnerability(vulnerability)
  local severity = (vulnerability.severity or "UNKNOWN"):upper()
  local fixed_suffix = ""
  if vulnerability.fixed_version and vulnerability.fixed_version ~= "" then
    fixed_suffix = " | fixed: " .. vulnerability.fixed_version
  end
  return string.format("    - [%s] %s%s", severity, vulnerability.id or "UNKNOWN", fixed_suffix)
end

---@param results PyDepsOSVPackageResult[]
---@return PyDepsOSVAuditSummary
local function summarize(results)
  local vulnerable_packages = 0
  local total_vulnerabilities = 0
  for _, result in ipairs(results or {}) do
    local count = #(result.vulnerabilities or {})
    if count > 0 then
      vulnerable_packages = vulnerable_packages + 1
      total_vulnerabilities = total_vulnerabilities + count
    end
  end
  return {
    scanned_packages = #(results or {}),
    vulnerable_packages = vulnerable_packages,
    total_vulnerabilities = total_vulnerabilities,
  }
end

---@param a PyDepsOSVPackageResult
---@param b PyDepsOSVPackageResult
---@return boolean
local function package_sorter(a, b)
  local count_a = #(a.vulnerabilities or {})
  local count_b = #(b.vulnerabilities or {})
  if count_a ~= count_b then
    return count_a > count_b
  end
  return a.name < b.name
end

---@param results PyDepsOSVPackageResult[]
---@param opts? PyDepsOSVAuditShowOptions
---@return string[], PyDepsOSVAuditSummary
local function build_lines(results, opts)
  local summary = summarize(results)
  local lines = {
    "PyDeps Security Audit (OSV)",
    "Scanned packages: " .. summary.scanned_packages,
    "Packages with vulnerabilities: " .. summary.vulnerable_packages,
    "Total vulnerabilities: " .. summary.total_vulnerabilities,
  }

  if opts and opts.root then
    table.insert(lines, "Project root: " .. opts.root)
  end
  if opts and opts.error then
    table.insert(lines, "Warning: partial result (" .. opts.error .. ")")
  end

  table.insert(lines, "")
  if summary.total_vulnerabilities == 0 then
    table.insert(lines, "No known vulnerabilities found.")
    table.insert(lines, "")
    table.insert(lines, "Press q or <Esc> to close")
    return lines, summary
  end

  local vulnerable_results = {}
  for _, result in ipairs(results or {}) do
    if #(result.vulnerabilities or {}) > 0 then
      table.insert(vulnerable_results, result)
    end
  end
  table.sort(vulnerable_results, package_sorter)

  table.insert(lines, "Findings:")
  for _, result in ipairs(vulnerable_results) do
    table.insert(lines, "")
    table.insert(lines, string.format("  %s@%s (%d)", result.name, result.version, #result.vulnerabilities))
    for _, vulnerability in ipairs(result.vulnerabilities) do
      table.insert(lines, format_vulnerability(vulnerability))
      table.insert(lines, "      " .. (vulnerability.summary or "(no summary)"))
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Press q or <Esc> to close")
  return lines, summary
end

---@param results PyDepsOSVPackageResult[]
---@param opts? PyDepsOSVAuditShowOptions
---@return PyDepsOSVAuditSummary
function M.show(results, opts)
  local lines, summary = build_lines(results or {}, opts)
  output.show("PyDeps Audit", lines, {
    mode = "float",
    anchor = "center",
    border = config.options.audit_window_border or "rounded",
  })
  return summary
end

return M
