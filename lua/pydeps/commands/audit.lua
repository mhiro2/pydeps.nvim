local buffer_context = require("pydeps.core.buffer_context")
local cache = require("pydeps.core.cache")
local util = require("pydeps.util")

local M = {}

---@param lock_data PyDepsLockfileData
---@return PyDepsAuditPackage[]
local function collect_lock_packages(lock_data)
  local packages = {}
  for name, package in pairs(lock_data.packages or {}) do
    if type(package) == "table" and package.version then
      table.insert(packages, {
        name = package.name or name,
        version = package.version,
      })
    end
  end
  table.sort(packages, function(a, b)
    return a.name < b.name
  end)
  return packages
end

---@return nil
function M.run()
  local bufnr = buffer_context.current_buf()
  local root = buffer_context.find_root(bufnr)
  if not root then
    vim.notify("pydeps: project root not found", vim.log.levels.WARN)
    return
  end

  local lock_data, missing = cache.get_lockfile(root, { sync = true })
  if missing then
    vim.notify("pydeps: uv.lock not found", vim.log.levels.WARN)
    return
  end

  local packages = collect_lock_packages(lock_data)
  if #packages == 0 then
    vim.notify("pydeps: no lockfile packages found", vim.log.levels.WARN)
    return
  end

  vim.notify("pydeps: running OSV audit", vim.log.levels.INFO)
  local osv = require("pydeps.providers.osv")
  local security_audit = require("pydeps.ui.security_audit")
  osv.audit(packages, function(results, err)
    local summary = security_audit.show(results, {
      root = root,
      error = err,
    })

    util.emit_user_autocmd("PyDepsAuditCompleted", {
      root = root,
      scanned = summary.scanned_packages,
      vulnerable_packages = summary.vulnerable_packages,
      vulnerabilities = summary.total_vulnerabilities,
      error = err,
    })

    if err then
      vim.notify("pydeps: OSV audit completed with errors: " .. err, vim.log.levels.WARN)
    end
  end)
end

return M
