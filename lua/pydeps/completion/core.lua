---@class PyDepsCompletionContext
---@field kind string
---@field name? string
---@field prefix string
---@field token_prefix string
---@field range table

local config = require("pydeps.config")
local completion_items = require("pydeps.completion.items")
local completion_scan = require("pydeps.completion.scan")
local cache = require("pydeps.core.cache")
local project = require("pydeps.core.project")
local util = require("pydeps.util")
local pypi = require("pydeps.providers.pypi")

local M = {}

---@param bufnr integer
---@param line integer
---@return string
local function get_line(bufnr, line)
  return vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
end

---@param line integer
---@param start_col integer
---@param end_col integer
---@return table
local function make_range(line, start_col, end_col)
  return {
    start = { line = line - 1, character = start_col - 1 },
    ["end"] = { line = line - 1, character = end_col - 1 },
  }
end

---@param items string[]
---@return string[]
local function unique(items)
  local seen = {}
  local out = {}
  for _, item in ipairs(items) do
    if item and item ~= "" and not seen[item] then
      seen[item] = true
      table.insert(out, item)
    end
  end
  table.sort(out)
  return out
end

---@param bufnr integer
---@return string[]
local function local_package_names(bufnr)
  local deps = cache.get_pyproject(bufnr)
  local names = {}
  for _, dep in ipairs(deps) do
    table.insert(names, dep.name)
  end
  local root = project.find_root(bufnr)
  local resolved = {}
  if root then
    local lock_data = cache.get_lockfile(root)
    resolved = lock_data.resolved or {}
  end
  for name in pairs(resolved) do
    table.insert(names, name)
  end
  return unique(names)
end

---@param bufnr integer
---@param prefix string
---@return string[]
local function collect_local_groups(bufnr, prefix)
  local deps = cache.get_pyproject(bufnr)
  local values = {}
  local seen = {}
  for _, dep in ipairs(deps or {}) do
    if type(dep.group) == "string" and vim.startswith(dep.group, prefix) then
      local value = dep.group:sub(#prefix + 1)
      if not seen[value] then
        seen[value] = true
        values[#values + 1] = value
      end
    end
  end
  table.sort(values)
  return values
end

---@param prefix string
---@return string
local function marker_context(prefix)
  if prefix:match("extra%s*[%!=<>]*%s*['\"]?[%w%._%-]*$") then
    return "marker_extra"
  end
  if
    prefix:match("group%s*[%!=<>]*%s*['\"]?[%w%._%-]*$")
    or prefix:match("dependency_group%s*[%!=<>]*%s*['\"]?[%w%._%-]*$")
  then
    return "marker_group"
  end
  return "marker"
end

---@param bufnr integer
---@param cursor integer[]
---@return PyDepsCompletionContext?
local function detect_context(bufnr, cursor)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  if not util.is_pyproject(bufname) then
    return nil
  end
  local line_num = cursor[1]
  local col = cursor[2] + 1
  local line = get_line(bufnr, line_num)
  local ctx = completion_scan.string_context(line, col)
  if not ctx then
    return nil
  end
  local value = ctx.value
  local rel = col - ctx.start_col
  if rel < 1 then
    rel = 1
  end
  if rel > #value + 1 then
    rel = #value + 1
  end
  local prefix = value:sub(1, rel - 1)
  local name = util.parse_requirement_name(value)
  local kind = nil
  if prefix:find(";") then
    kind = marker_context(prefix)
  elseif prefix:find("%[") and not prefix:find("%]") then
    kind = "extra"
  elseif prefix:find("[<>=!~]") then
    kind = "version"
  else
    kind = "name"
  end

  local pattern = "[%w%._%-]"
  if kind == "version" then
    pattern = "[%w%._%-%+%*]"
  end
  local token_left, token_right = completion_scan.token_range(value, math.max(rel, 1), pattern)
  local start_col = ctx.start_col + token_left
  local end_col = ctx.start_col + token_right
  local token_prefix = value:sub(token_left, math.max(rel - 1, token_left - 1))
  return {
    kind = kind,
    name = name,
    prefix = prefix,
    token_prefix = token_prefix,
    range = make_range(line_num, start_col, end_col),
  }
end

---@param bufnr integer
---@param cursor integer[]
---@param callback fun(result: table)
function M.complete(bufnr, cursor, callback)
  local ctx = detect_context(bufnr, cursor)
  if not ctx then
    callback({ items = {}, isIncomplete = false })
    return
  end

  if ctx.kind == "name" then
    local local_names = local_package_names(bufnr)
    local completion_opts = config.options.completion or {}
    local search_prefix = ctx.token_prefix or ctx.prefix
    if completion_opts.pypi_search and #search_prefix >= (completion_opts.pypi_search_min or 2) then
      pypi.search(search_prefix, function(results)
        local combined = {}
        local sources = {}
        for _, name in ipairs(results or {}) do
          sources[name] = sources[name] or {}
          sources[name].pypi = true
          table.insert(combined, name)
        end
        for _, name in ipairs(local_names) do
          sources[name] = sources[name] or {}
          sources[name].is_local = true
          table.insert(combined, name)
        end
        callback({
          items = completion_items.as_items(
            unique(combined),
            ctx.range,
            completion_items.kinds.Module,
            completion_items.package_source_meta(sources)
          ),
          isIncomplete = false,
        })
      end)
      return
    end
    local meta = completion_items.uniform_meta(local_names, "package", "local")
    callback({
      items = completion_items.as_items(local_names, ctx.range, completion_items.kinds.Module, meta),
      isIncomplete = false,
    })
    return
  end

  if ctx.kind == "version" and ctx.name then
    pypi.get(ctx.name, function(meta)
      local versions = meta and pypi.sorted_versions(meta) or {}
      local item_meta = completion_items.uniform_meta(versions, "version", ctx.name)
      callback({
        items = completion_items.as_items(versions, ctx.range, completion_items.kinds.Value, item_meta),
        isIncomplete = false,
      })
    end)
    return
  end

  if ctx.kind == "extra" and ctx.name then
    pypi.get(ctx.name, function(meta)
      local extras = (meta and meta.info and meta.info.provides_extra) or {}
      local item_meta = completion_items.uniform_meta(extras, "extra", ctx.name)
      callback({
        items = completion_items.as_items(extras, ctx.range, completion_items.kinds.EnumMember, item_meta),
        isIncomplete = false,
      })
    end)
    return
  end

  if ctx.kind == "marker_extra" then
    local extras = collect_local_groups(bufnr, "optional:")
    local item_meta = completion_items.uniform_meta(extras, "marker extra", "local")
    callback({
      items = completion_items.as_items(extras, ctx.range, completion_items.kinds.EnumMember, item_meta),
      isIncomplete = false,
    })
    return
  end

  if ctx.kind == "marker_group" then
    local groups = collect_local_groups(bufnr, "group:")
    local item_meta = completion_items.uniform_meta(groups, "marker group", "local")
    callback({
      items = completion_items.as_items(groups, ctx.range, completion_items.kinds.EnumMember, item_meta),
      isIncomplete = false,
    })
    return
  end

  callback({ items = {}, isIncomplete = false })
end

return M
