local config = require("pydeps.config")

local M = {}

M.REQUEST_TIMEOUT = 10000
M.SEARCH_FAILURE_BACKOFF = 60

---@param name? string
---@return string
function M.normalize(name)
  return (name or ""):lower()
end

---@param name string
---@return boolean
function M.is_valid_package_name(name)
  return name:match("^[a-z0-9][a-z0-9%._-]*$") ~= nil
end

---@return fun(msg: string): nil
function M.create_notify_once()
  local notified = false
  return function(msg)
    if notified then
      return
    end
    notified = true
    vim.notify(msg, vim.log.levels.WARN)
  end
end

---@return string?
function M.resolve_python()
  if vim.fn.executable("python3") == 1 then
    return "python3"
  end
  if vim.fn.executable("python") == 1 then
    return "python"
  end
  return nil
end

---@param payload string
---@return table?
function M.decode_json(payload)
  local ok, decoded = pcall(vim.json.decode, payload)
  if ok then
    return decoded
  end
  vim.notify(
    "pydeps: Failed to fetch package info from PyPI. Please check your internet connection.",
    vim.log.levels.WARN
  )
  return nil
end

---@param name string
---@return string?
function M.request_url(name)
  if not M.is_valid_package_name(name) then
    return nil
  end
  local base = config.options.pypi_url or "https://pypi.org/pypi"
  return string.format("%s/%s/json", base, name)
end

---@return number
function M.pypi_cache_ttl()
  return config.options.pypi_cache_ttl or 3600
end

---@param value string
---@return string
function M.url_encode(value)
  return (value:gsub("[^%w%-%._~]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

---@return string
function M.pypi_base_url()
  local configured = config.options.pypi_url or "https://pypi.org/pypi"
  local base = configured:gsub("/pypi/?$", "")
  base = base:gsub("/+$", "")
  if base == "" then
    return "https://pypi.org"
  end
  return base
end

---@param query string
---@return string?
function M.search_url(query)
  if not M.is_valid_package_name(query) then
    return nil
  end
  return string.format("%s/search/?q=%s", M.pypi_base_url(), M.url_encode(query))
end

return M
