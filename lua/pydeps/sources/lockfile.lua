local util = require("pydeps.util")

local M = {}

---@alias PyDepsResolved table<string, string>

---@class PyDepsLockPackage
---@field name string
---@field version string
---@field dependencies string[]

---@class PyDepsLockfileData
---@field resolved PyDepsResolved
---@field packages table<string, PyDepsLockPackage>
---@field graph? table<string, string[]>

---@param lines string[]
---@return PyDepsLockfileData
local function parse_lines(lines)
  local resolved = {}
  local packages = {}
  local in_package = false
  local current_table = nil
  ---@type PyDepsLockPackage?
  local current = nil
  local in_dependencies = false
  local dependencies_depth = 0

  ---@private
  local function finalize_current()
    if current and current.name and current.version then
      packages[current.name] = current
      resolved[current.name] = current.version
    end
  end

  for _, raw_line in ipairs(lines or {}) do
    local line = util.strip_toml_comment(raw_line)
    local array_header = line:match("^%s*%[%[([^%]]+)%]%]%s*$")
    if array_header then
      current_table = array_header
      in_dependencies = false
      dependencies_depth = 0
      if array_header == "package" then
        if current then
          finalize_current()
        end
        in_package = true
        current = { dependencies = {} }
      elseif array_header:match("^package%.") then
        in_package = true
      else
        in_package = false
      end
    else
      local table_header = line:match("^%s*%[([^%]]+)%]%s*$")
      if table_header then
        current_table = table_header
        if table_header == "package" or table_header:match("^package%.") then
          in_package = true
        else
          in_package = false
        end
        in_dependencies = false
        dependencies_depth = 0
      end
    end

    if in_package and current_table == "package" and current then
      if in_dependencies then
        dependencies_depth = dependencies_depth + util.count_brackets_outside_strings(line)
        for _, entry in ipairs(util.parse_quoted_strings(line)) do
          table.insert(current.dependencies, entry.value)
        end
        if dependencies_depth <= 0 then
          in_dependencies = false
        end
      else
        local name = line:match("^%s*name%s*=%s*['\"]([^'\"]+)['\"]")
        if name then
          current.name = util.parse_requirement_name(name)
        end

        local version = line:match("^%s*version%s*=%s*['\"]([^'\"]+)['\"]")
        if version then
          current.version = util.trim(version)
        end

        if line:match("^%s*dependencies%s*=%s*%[") then
          in_dependencies = true
          dependencies_depth = util.count_brackets_outside_strings(line)
          for _, entry in ipairs(util.parse_quoted_strings(line)) do
            table.insert(current.dependencies, entry.value)
          end
          if dependencies_depth <= 0 then
            in_dependencies = false
          end
        end
      end
    end
  end

  finalize_current()

  return { resolved = resolved, packages = packages }
end

---@param packages table<string, PyDepsLockPackage>
---@return table<string, string[]>
function M.build_graph(packages)
  local graph = {}
  for name, pkg in pairs(packages or {}) do
    local deps = {}
    local seen = {}
    for _, dep in ipairs(pkg.dependencies or {}) do
      local dep_name = util.parse_requirement_name(dep)
      if dep_name and not seen[dep_name] then
        seen[dep_name] = true
        table.insert(deps, dep_name)
      end
    end
    graph[name] = deps
  end
  return graph
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
