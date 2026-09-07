local util = require("pydeps.util")
local value = require("pydeps.sources.lock_value")
local markers = require("pydeps.core.markers")

local M = {}

---@alias PyDepsResolved table<string, string>
---@class PyDepsLockPackage
---@field id string
---@field name string
---@field version? string
---@field source table<string, string>
---@field dependencies table[]
---@field resolution_markers string[]
---@class PyDepsLockfileData
---@field resolved PyDepsResolved Only unambiguous universal versions
---@field packages table<string, PyDepsLockPackage> Universal package identities
---@field by_name table<string, string[]>
---@field graph table<string, string[]>

local function source_key(source)
  local entries = {}
  for _, key in ipairs(vim.tbl_keys(source or {})) do
    entries[#entries + 1] = vim.json.encode({ key, source[key] })
  end
  table.sort(entries)
  return table.concat(entries, ",")
end

local function identity(pkg)
  return vim.json.encode({ pkg.name, pkg.version or "", source_key(pkg.source) })
end

local function matches(pkg, edge)
  return pkg.name == edge.name
    and (not edge.version or pkg.version == edge.version)
    and (not edge.source or source_key(pkg.source) == source_key(edge.source))
end

local function marker_active(expressions, env)
  if #expressions == 0 then
    return true
  end
  local unknown = false
  for _, expression in ipairs(expressions) do
    local active = markers.evaluate(expression, env)
    if active == true then
      return true
    end
    unknown = unknown or active == nil
  end
  if unknown then
    return nil
  end
  return false
end

---Project a universal lock without guessing when markers or identities are ambiguous.
---Extras and groups select optional edges; the universal package table is never filtered.
function M.project(data, env)
  env = env or {}
  local selected, resolved, ambiguous = {}, {}, {}
  local candidates = {}
  for id, pkg in pairs(data.packages or {}) do
    local active = marker_active(pkg.resolution_markers or {}, env)
    if active ~= false then
      candidates[pkg.name] = candidates[pkg.name] or {}
      table.insert(candidates[pkg.name], { id = id, active = active })
    end
  end
  for name, entries in pairs(candidates) do
    if #entries == 1 and entries[1].active == true then
      selected[name] = entries[1].id
      resolved[name] = data.packages[entries[1].id].version
    else
      ambiguous[name] = true
    end
  end
  local graph, extras = {}, {}
  local changed = true
  while changed do
    changed = false
    for name, id in pairs(selected) do
      graph[name] = graph[name] or {}
      local seen = {}
      for _, child in ipairs(graph[name]) do
        seen[child] = true
      end
      for _, edge in ipairs(data.packages[id].dependencies or {}) do
        local enabled = edge.kind == "runtime"
          or (edge.kind == "optional" and (edge.group == env.extra or (extras[name] and extras[name][edge.group])))
          or (edge.kind == "dev" and edge.group == (env.dependency_group or env.group))
        local child = selected[edge.name] and data.packages[selected[edge.name]]
        if
          enabled
          and child
          and matches(child, edge)
          and (not edge.marker or markers.evaluate(edge.marker, env) == true)
        then
          if not seen[edge.name] then
            graph[name][#graph[name] + 1] = edge.name
            seen[edge.name] = true
          end
          for _, extra in ipairs(edge.extra or {}) do
            extras[edge.name] = extras[edge.name] or {}
            if not extras[edge.name][extra] then
              extras[edge.name][extra] = true
              changed = true
            end
          end
        end
      end
      table.sort(graph[name])
    end
  end
  return { resolved = resolved, selected = selected, ambiguous = ambiguous, graph = graph }
end

---Collect all locked versions per name for environment-independent lock diffs.
function M.snapshot(data)
  local versions = {}
  for _, pkg in pairs(data.packages or {}) do
    if pkg.version then
      versions[pkg.name] = versions[pkg.name] or {}
      versions[pkg.name][pkg.version] = true
    end
  end
  local result = {}
  for name, entries in pairs(versions) do
    local sorted = vim.tbl_keys(entries)
    table.sort(sorted)
    result[name] = table.concat(sorted, ", ")
  end
  return result
end

local function parse_lines(lines)
  local packages, current, section = {}, nil, nil
  local pending_key, pending_text
  local function finish()
    if current and current.name then
      current.id = identity(current)
      packages[current.id] = current
    end
  end
  local function assign(key, parsed)
    if not current then
      return
    end
    if section == "package" then
      if key == "name" then
        current.name = util.parse_requirement_name(parsed)
      elseif key == "version" or key == "source" then
        current[key] = parsed
      elseif key == "resolution-markers" then
        current.resolution_markers = parsed
      end
    end
    local kind = section == "package" and key == "dependencies" and "runtime"
      or section == "package.optional-dependencies" and "optional"
      or section == "package.dev-dependencies" and "dev"
    if kind then
      for _, edge in ipairs(parsed) do
        if type(edge) == "table" and type(edge.name) == "string" then
          edge.name = util.parse_requirement_name(edge.name)
          edge.kind = kind
          edge.group = kind ~= "runtime" and key or nil
          current.dependencies[#current.dependencies + 1] = edge
        end
      end
    end
  end
  for _, raw in ipairs(lines or {}) do
    local line = util.strip_toml_comment(raw)
    local header = line:match("^%s*%[%[([^%]]+)%]%]%s*$")
    local table_header = line:match("^%s*%[([^%]]+)%]%s*$")
    if header or table_header then
      pending_key, pending_text = nil, nil
      section = header or table_header
      if header == "package" then
        finish()
        current = { source = {}, dependencies = {}, resolution_markers = {} }
      end
    elseif pending_key then
      pending_text = pending_text .. "\n" .. line
      local parsed = value.parse(pending_text)
      if parsed ~= nil then
        assign(pending_key, parsed)
        pending_key, pending_text = nil, nil
      end
    elseif
      current
      and (section == "package" or section == "package.optional-dependencies" or section == "package.dev-dependencies")
    then
      local key, text = line:match("^%s*([%w_-]+)%s*=%s*(.+)$")
      if not key then
        local quoted
        quoted, text = line:match('^%s*(".-")%s*=%s*(.+)$')
        key = quoted and value.parse(quoted)
      end
      if
        key
        and (
          key == "name"
          or key == "version"
          or key == "source"
          or key == "resolution-markers"
          or key == "dependencies"
          or section ~= "package"
        )
      then
        local parsed = value.parse(text)
        if parsed ~= nil then
          assign(key, parsed)
        elseif text:match("^%[") or text:match("^{") then
          pending_key, pending_text = key, text
        end
      end
    end
  end
  finish()
  local data = { packages = packages, by_name = {} }
  for id, pkg in pairs(packages) do
    data.by_name[pkg.name] = data.by_name[pkg.name] or {}
    table.insert(data.by_name[pkg.name], id)
  end
  for _, ids in pairs(data.by_name) do
    table.sort(ids)
  end
  local projection = M.project(data)
  data.resolved, data.graph = projection.resolved, projection.graph
  return data
end

---@param path? string
---@return PyDepsLockfileData
function M.parse_full(path)
  if not path then
    return { resolved = {}, packages = {} }
  end

  local lines = {}
  local file, err = io.open(path, "r")
  if not file then
    -- Only notify if path exists but cannot be opened (permission issues, etc.)
    if path and vim.fn.filereadable(path) == 1 then
      vim.notify(
        string.format("pydeps: Failed to read lockfile '%s'. Error: %s", path, err or "unknown error"),
        vim.log.levels.ERROR
      )
    end
    return { resolved = {}, packages = {} }
  end
  for line in file:lines() do
    table.insert(lines, line)
  end
  file:close()
  return parse_lines(lines)
end

---@param path? string
---@param cb fun(data: PyDepsLockfileData? , err?: string)
---@return nil
function M.parse_async(path, cb)
  if not path then
    cb(nil, "path is nil")
    return
  end

  local uv = vim.uv
  uv.fs_open(path, "r", 438, function(open_err, fd)
    if open_err or not fd then
      if vim.fn.filereadable(path) == 1 then
        vim.notify(
          string.format("pydeps: Failed to read lockfile '%s'. Error: %s", path, open_err or "unknown error"),
          vim.log.levels.ERROR
        )
      end
      cb(nil, open_err or "open failed")
      return
    end

    uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or not stat then
        uv.fs_close(fd)
        cb(nil, stat_err or "fstat failed")
        return
      end
      local size = stat.size or 0
      if size == 0 then
        uv.fs_close(fd)
        cb(parse_lines({}))
        return
      end
      uv.fs_read(fd, size, 0, function(read_err, data)
        uv.fs_close(fd)
        if read_err then
          cb(nil, read_err)
          return
        end
        local lines = vim.split(data or "", "\n", { plain = true })
        cb(parse_lines(lines))
      end)
    end)
  end)
end

---@param path? string
---@return PyDepsResolved
function M.parse(path)
  return M.parse_full(path).resolved
end

return M
