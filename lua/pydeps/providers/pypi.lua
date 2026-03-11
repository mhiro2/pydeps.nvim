---@class PyDepsPyPIMeta
---@field info? PyDepsPyPIInfo
---@field releases? table<string, PyDepsPyPIRelease[]>

---@class PyDepsPyPIInfo
---@field summary? string
---@field home_page? string
---@field project_urls? table<string, string>
---@field version? string
---@field provides_extra? string[]
---@field requires_dist? string[]

---@class PyDepsPyPIRelease
---@field yanked? boolean
---@field upload_time_iso_8601? string

---@class PyDepsPyPICacheEntry
---@field data PyDepsPyPIMeta?
---@field time number
---@field failed? boolean
---@field retry_after? number

local metadata = require("pydeps.providers.pypi.metadata")
local search = require("pydeps.providers.pypi.search")
local shared = require("pydeps.providers.pypi.shared")
local util = require("pydeps.util")

local notify_once = shared.create_notify_once()

local metadata_client = metadata.new({
  notify_once = notify_once,
  on_update = function(name)
    util.emit_user_autocmd("PyDepsPyPIUpdated", { name = name })
  end,
})

local search_client = search.new({
  notify_once = notify_once,
})

local M = {}

---@param name string
---@return PyDepsPyPIMeta?
function M.get_cached(name)
  return metadata_client.get_cached(name)
end

---@param name string
---@param cb? fun(data: PyDepsPyPIMeta?)
---@return nil
function M.get(name, cb)
  metadata_client.get(name, cb)
end

---@param query? string
---@param cb fun(results: string[])
---@return nil
function M.search(query, cb)
  search_client.search(query, cb)
end

---@param data? PyDepsPyPIMeta
---@param version? string
---@return boolean
function M.is_yanked(data, version)
  if not data or not version then
    return false
  end
  local releases = data.releases and data.releases[version]
  if not releases then
    return false
  end
  for _, file in ipairs(releases) do
    if file.yanked then
      return true
    end
  end
  return false
end

---@param data? PyDepsPyPIMeta
---@return string[]
function M.sorted_versions(data)
  if not data or not data.releases then
    return {}
  end
  local versions = {}
  for version, files in pairs(data.releases) do
    local latest = nil
    for _, file in ipairs(files) do
      if file.upload_time_iso_8601 then
        if not latest or file.upload_time_iso_8601 > latest then
          latest = file.upload_time_iso_8601
        end
      end
    end
    table.insert(versions, { version = version, time = latest or "" })
  end
  table.sort(versions, function(a, b)
    if a.time == b.time then
      return a.version > b.version
    end
    return a.time > b.time
  end)
  local result = {}
  for _, item in ipairs(versions) do
    table.insert(result, item.version)
  end
  return result
end

return M
