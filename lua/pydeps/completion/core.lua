local lockfile = require("pydeps.sources.lockfile")
---@class PyDepsCompletionContext
---@field kind string
---@field name? string
---@field marker_field? string
---@field quote? string Quote to wrap an inserted marker value in, when the user has not typed one
---@field prefix string
---@field token_prefix string
---@field range table

local config = require("pydeps.config")
local completion_items = require("pydeps.completion.items")
local completion_scan = require("pydeps.completion.scan")
local cache = require("pydeps.core.cache")
local markers = require("pydeps.core.markers")
local project = require("pydeps.core.project")
local util = require("pydeps.util")
local pypi = require("pydeps.providers.pypi")
local ts_toml = require("pydeps.treesitter.toml")

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
    resolved = lockfile.project(lock_data, require("pydeps.core.env").get(root)).resolved
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

-- Values commonly compared against marker fields. The current environment's
-- value is offered as well, which covers version-like fields.
local marker_values = {
  os_name = { "nt", "posix" },
  sys_platform = { "cygwin", "darwin", "emscripten", "linux", "win32" },
  platform_system = { "Darwin", "Emscripten", "Linux", "Windows" },
  platform_machine = { "AMD64", "aarch64", "arm64", "x86_64" },
  platform_python_implementation = { "CPython", "PyPy" },
  implementation_name = { "cpython", "pypy" },
}

---Classify the marker expression before the cursor.
---@param prefix string requirement text before the cursor, containing `;`
---@return string kind
---@return string? field marker field whose value is being completed
---@return boolean? quoted whether the value already has an opening quote
local function marker_context(prefix)
  local expr = prefix:match(";(.*)$")
  -- An operand may open with a TOML-escaped quote (`\"`) inside a basic string.
  for _, operator in ipairs({ "%s*[=!<>~]+%s*", "%s+not%s+in%s*", "%s+in%s*" }) do
    local field, quote = expr:match("([%w_]+)" .. operator .. "(\\?['\"]?)[^'\"\\]*$")
    if field then
      return "marker_value", field, quote ~= ""
    end
  end
  local before = (expr:gsub("[%w_]*$", ""))
  if
    before:match("^%s*$")
    or before:match("%(%s*$")
    or before:match("[%s%)'\"]and%s+$")
    or before:match("[%s%)'\"]or%s+$")
  then
    return "marker_field"
  end
  return "marker"
end

---@param bufnr integer
---@param field string
---@return string[] values, string detail, string source
local function marker_value_candidates(bufnr, field)
  if field == "extra" then
    return collect_local_groups(bufnr, "optional:"), "marker extra", "local"
  end
  if field == "group" or field == "dependency_group" then
    return collect_local_groups(bufnr, "group:"), "marker group", "local"
  end
  local values = vim.list_extend({}, marker_values[field] or {})
  local current = require("pydeps.core.env").get(project.find_root(bufnr))[field]
  if type(current) == "string" then
    values[#values + 1] = current
  end
  return unique(values), "marker value", field
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
  if not ctx or not ts_toml.dependency_section_at(bufnr, line_num - 1, ctx.start_col - 1) then
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
  local kind, marker_field, quoted = nil, nil, nil
  if prefix:find(";") then
    kind, marker_field, quoted = marker_context(prefix)
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
  elseif kind == "marker_value" and quoted then
    -- Replace the whole quoted operand, which may contain spaces (e.g. platform_version).
    pattern = "[^'\"\\]"
  end
  local token_left, token_right = completion_scan.token_range(value, rel, pattern)
  local start_col = ctx.start_col + token_left
  local end_col = ctx.start_col + token_right
  local token_prefix = value:sub(token_left, rel - 1)
  return {
    kind = kind,
    name = name,
    marker_field = marker_field,
    quote = (kind == "marker_value" and not quoted) and (ctx.quote == '"' and "'" or '"') or nil,
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
            completion_items.with_typed_spelling(completion_items.package_source_meta(sources), search_prefix)
          ),
          isIncomplete = false,
        })
      end)
      return
    end
    local meta = completion_items.with_typed_spelling(
      completion_items.uniform_meta(local_names, "package", "local"),
      search_prefix
    )
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

  if ctx.kind == "marker_field" then
    local fields = markers.field_names()
    local item_meta = completion_items.uniform_meta(fields, "marker field")
    callback({
      items = completion_items.as_items(fields, ctx.range, completion_items.kinds.Property, item_meta),
      isIncomplete = false,
    })
    return
  end

  if ctx.kind == "marker_value" then
    local values, detail, source = marker_value_candidates(bufnr, ctx.marker_field)
    local item_meta = completion_items.uniform_meta(values, detail, source)
    if ctx.quote then
      for value, meta in pairs(item_meta) do
        meta.new_text = ctx.quote .. value .. ctx.quote
      end
    end
    callback({
      items = completion_items.as_items(values, ctx.range, completion_items.kinds.EnumMember, item_meta),
      isIncomplete = false,
    })
    return
  end

  callback({ items = {}, isIncomplete = false })
end

return M
