---@class PyDepsStringRange
---@field start_col integer
---@field end_col integer
---@field closed boolean
---@field quote string

---@class PyDepsStringContext
---@field value string
---@field start_col integer
---@field end_col integer

---@class PyDepsCompletionContext
---@field kind string
---@field name? string
---@field prefix string
---@field token_prefix string
---@field range table

---@class PyDepsCompletionItemMeta
---@field detail? string
---@field label_details? table
---@field documentation? string|table
---@field insert_text? string
---@field sort_text? string

local config = require("pydeps.config")
local cache = require("pydeps.core.cache")
local project = require("pydeps.core.project")
local util = require("pydeps.util")
local pypi = require("pydeps.providers.pypi")

local M = {}

-- CompletionItemKind fallback values (from LSP spec)
local lsp_completion_item_kind = vim.lsp and vim.lsp.protocol and vim.lsp.protocol.CompletionItemKind or {}
local CompletionItemKind = {
  Module = lsp_completion_item_kind.Module or 9,
  Value = lsp_completion_item_kind.Value or 12,
  EnumMember = lsp_completion_item_kind.EnumMember or 20,
}

---@param bufnr integer
---@param line integer
---@return string
local function get_line(bufnr, line)
  return vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
end

---@param line string
---@return PyDepsStringRange[]
local function scan_strings(line)
  local ranges = {}
  local i = 1
  local len = #line

  ---@param idx integer
  ---@return boolean
  local function is_escaped(idx)
    local count = 0
    local j = idx - 1
    while j >= 1 and line:sub(j, j) == "\\" do
      count = count + 1
      j = j - 1
    end
    return count % 2 == 1
  end

  while i <= len do
    local ch = line:sub(i, i)
    if ch == "'" or ch == '"' then
      local quote = ch
      local start_col = i
      i = i + 1
      local closed = false
      while i <= len do
        local cj = line:sub(i, i)
        if cj == quote and not is_escaped(i) then
          closed = true
          break
        end
        i = i + 1
      end
      local end_col = closed and i or (len + 1)
      table.insert(ranges, {
        start_col = start_col,
        end_col = end_col,
        closed = closed,
        quote = quote,
      })
      i = i + 1
    else
      i = i + 1
    end
  end
  return ranges
end

---@param line string
---@param col integer
---@return PyDepsStringContext?
local function string_context(line, col)
  for _, range in ipairs(scan_strings(line)) do
    if col > range.start_col and col <= range.end_col then
      local value = line:sub(range.start_col + 1, range.end_col - 1)
      return {
        value = value,
        start_col = range.start_col,
        end_col = range.end_col,
      }
    end
  end
  return nil
end

---@param value string
---@param pos integer
---@param pattern string
---@return integer, integer
local function token_range(value, pos, pattern)
  local left = pos
  if left < 1 then
    left = 1
  end
  if left > #value then
    left = #value
  end
  while left > 1 do
    local ch = value:sub(left - 1, left - 1)
    if not ch:match(pattern) then
      break
    end
    left = left - 1
  end
  local right = pos
  if right < 1 then
    right = 1
  end
  while right <= #value do
    local ch = value:sub(right, right)
    if not ch:match(pattern) then
      break
    end
    right = right + 1
  end
  return left, right
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

---@param description? string
---@return table?
local function label_details(description)
  if not description or description == "" then
    return nil
  end
  return { description = description }
end

---@param items string[]
---@param detail? string
---@param label_description? string
---@return table<string, PyDepsCompletionItemMeta>
local function uniform_meta(items, detail, label_description)
  local meta = {}
  local details = label_details(label_description)
  for _, item in ipairs(items or {}) do
    meta[item] = {
      detail = detail,
      label_details = details,
    }
  end
  return meta
end

---@param label string
---@param range table
---@param kind integer
---@param meta? PyDepsCompletionItemMeta
---@return table
local function make_item(label, range, kind, meta)
  local item = {
    label = label,
    kind = kind,
    textEdit = {
      newText = label,
      range = range,
    },
  }
  if meta then
    if meta.detail then
      item.detail = meta.detail
    end
    if meta.label_details then
      item.labelDetails = meta.label_details
    end
    if meta.documentation then
      item.documentation = meta.documentation
    end
    if meta.insert_text then
      item.insertText = meta.insert_text
    end
    if meta.sort_text then
      item.sortText = meta.sort_text
    end
  end
  return item
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
  local ctx = string_context(line, col)
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
  local token_left, token_right = token_range(value, math.max(rel, 1), pattern)
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

---@param items string[]
---@param range table
---@param kind integer
---@param meta_by_label? table<string, PyDepsCompletionItemMeta>
---@return table[]
local function as_items(items, range, kind, meta_by_label)
  local out = {}
  for _, item in ipairs(items) do
    table.insert(out, make_item(item, range, kind, meta_by_label and meta_by_label[item] or nil))
  end
  return out
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
        local meta = {}
        for name, source in pairs(sources) do
          local description = nil
          if source.is_local and source.pypi then
            description = "local/PyPI"
          elseif source.is_local then
            description = "local"
          elseif source.pypi then
            description = "PyPI"
          end
          meta[name] = {
            detail = "package",
            label_details = label_details(description),
          }
        end
        callback({
          items = as_items(unique(combined), ctx.range, CompletionItemKind.Module, meta),
          isIncomplete = false,
        })
      end)
      return
    end
    local meta = uniform_meta(local_names, "package", "local")
    callback({
      items = as_items(local_names, ctx.range, CompletionItemKind.Module, meta),
      isIncomplete = false,
    })
    return
  end

  if ctx.kind == "version" and ctx.name then
    pypi.get(ctx.name, function(meta)
      local versions = meta and pypi.sorted_versions(meta) or {}
      local item_meta = uniform_meta(versions, "version", ctx.name)
      callback({
        items = as_items(versions, ctx.range, CompletionItemKind.Value, item_meta),
        isIncomplete = false,
      })
    end)
    return
  end

  if ctx.kind == "extra" and ctx.name then
    pypi.get(ctx.name, function(meta)
      local extras = (meta and meta.info and meta.info.provides_extra) or {}
      local item_meta = uniform_meta(extras, "extra", ctx.name)
      callback({
        items = as_items(extras, ctx.range, CompletionItemKind.EnumMember, item_meta),
        isIncomplete = false,
      })
    end)
    return
  end

  if ctx.kind == "marker_extra" then
    local deps = cache.get_pyproject(bufnr)
    local extras = {}
    local seen = {}
    for _, dep in ipairs(deps or {}) do
      if dep.group and dep.group:match("^optional:") then
        local extra = dep.group:sub(#"optional:" + 1)
        if not seen[extra] then
          seen[extra] = true
          table.insert(extras, extra)
        end
      end
    end
    table.sort(extras)
    local item_meta = uniform_meta(extras, "marker extra", "local")
    callback({
      items = as_items(extras, ctx.range, CompletionItemKind.EnumMember, item_meta),
      isIncomplete = false,
    })
    return
  end

  if ctx.kind == "marker_group" then
    local deps = cache.get_pyproject(bufnr)
    local groups = {}
    local seen = {}
    for _, dep in ipairs(deps or {}) do
      if dep.group and dep.group:match("^group:") then
        local group = dep.group:sub(#"group:" + 1)
        if not seen[group] then
          seen[group] = true
          table.insert(groups, group)
        end
      end
    end
    table.sort(groups)
    local item_meta = uniform_meta(groups, "marker group", "local")
    callback({
      items = as_items(groups, ctx.range, CompletionItemKind.EnumMember, item_meta),
      isIncomplete = false,
    })
    return
  end

  callback({ items = {}, isIncomplete = false })
end

return M
