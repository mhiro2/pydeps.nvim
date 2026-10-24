---@class PyDepsCompletionItemMeta
---@field detail? string
---@field label_details? table
---@field new_text? string Text to insert instead of the label
---@field filter_text? string Text the client matches against what was typed

---@class PyDepsCompletionPackageSource
---@field is_local? boolean
---@field pypi? boolean

local util = require("pydeps.util")

local M = {}

local lsp_completion_item_kind = vim.lsp and vim.lsp.protocol and vim.lsp.protocol.CompletionItemKind or {}

M.kinds = {
  Module = lsp_completion_item_kind.Module or 9,
  Property = lsp_completion_item_kind.Property or 10,
  Value = lsp_completion_item_kind.Value or 12,
  EnumMember = lsp_completion_item_kind.EnumMember or 20,
}

---@param description? string
---@return table?
function M.label_details(description)
  if not description or description == "" then
    return nil
  end
  return { description = description }
end

---@param items string[]?
---@param detail? string
---@param label_description? string
---@return table<string, PyDepsCompletionItemMeta>
function M.uniform_meta(items, detail, label_description)
  local meta = {}
  local details = M.label_details(label_description)
  for _, item in ipairs(items or {}) do
    meta[item] = {
      detail = detail,
      label_details = details,
    }
  end
  return meta
end

---@param sources table<string, PyDepsCompletionPackageSource>
---@return table<string, PyDepsCompletionItemMeta>
function M.package_source_meta(sources)
  local meta = {}
  for name, source in pairs(sources or {}) do
    local description
    if source.is_local and source.pypi then
      description = "local/PyPI"
    elseif source.is_local then
      description = "local"
    elseif source.pypi then
      description = "PyPI"
    end
    meta[name] = {
      detail = "package",
      label_details = M.label_details(description),
    }
  end
  return meta
end

---Package names are offered in their PEP 503 spelling, so `zope.i` yields
---`zope-interface`. Give such items a filter text spelled the way the user
---started typing, or clients that filter on the typed text drop them.
---@param meta_by_label table<string, PyDepsCompletionItemMeta>
---@param typed string
---@return table<string, PyDepsCompletionItemMeta>
function M.with_typed_spelling(meta_by_label, typed)
  local prefix = util.normalize_package_name(typed)
  for name, meta in pairs(meta_by_label) do
    if name:sub(1, #prefix) == prefix and name:sub(1, #typed) ~= typed:lower() then
      meta.filter_text = typed .. name:sub(#prefix + 1)
    end
  end
  return meta_by_label
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
      newText = meta and meta.new_text or label,
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
    if meta.filter_text then
      item.filterText = meta.filter_text
    end
  end
  return item
end

---@param items string[]?
---@param range table
---@param kind integer
---@param meta_by_label? table<string, PyDepsCompletionItemMeta>
---@return table[]
function M.as_items(items, range, kind, meta_by_label)
  local out = {}
  for _, item in ipairs(items or {}) do
    out[#out + 1] = make_item(item, range, kind, meta_by_label and meta_by_label[item] or nil)
  end
  return out
end

return M
