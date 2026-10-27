local buffer_context = require("pydeps.core.buffer_context")
local context = require("pydeps.core.context")
local util = require("pydeps.util")

local M = {}

---@param root string
---@param field string
---@param value string|string[]|nil
---@return nil
local function apply(root, field, value)
  local ok, err = context.set(root, field, value)
  if not ok then
    vim.notify("pydeps: " .. err, vim.log.levels.WARN)
    return
  end
  vim.notify("pydeps: context " .. context.summary(root), vim.log.levels.INFO)
end

---`all` leaves the selection unfiltered and `none` selects nothing.
---@param args string[]
---@return string[]?
local function parse_names(args)
  local names = {}
  for _, arg in ipairs(args) do
    for name in arg:gmatch("[^,%s]+") do
      names[#names + 1] = name
    end
  end
  if #names == 1 and names[1] == "all" then
    return nil
  end
  if #names == 1 and names[1] == "none" then
    return {}
  end
  return names
end

---@param root string
---@param field "extras"|"groups"
---@return string[]
local function declared_names(root, field)
  local sections = context.sections(root)
  return field == "extras" and sections.extras or sections.groups
end

---@param root string
---@param field string
---@return nil
local function prompt_field(root, field)
  local overrides = context.overrides(root)
  if field == "platform" then
    vim.ui.select(vim.list_extend({ "detected" }, context.platforms()), {
      prompt = "pydeps: target platform",
    }, function(choice)
      if choice then
        apply(root, "platform", choice ~= "detected" and choice or nil)
      end
    end)
    return
  end

  if field == "python" then
    vim.ui.input({
      prompt = "pydeps: Python version (empty: detected) ",
      default = overrides.python or "",
    }, function(input)
      if input then
        input = util.trim(input)
        apply(root, "python", input ~= "" and input or nil)
      end
    end)
    return
  end

  local declared = declared_names(root, field)
  if #declared == 0 then
    vim.notify("pydeps: pyproject.toml declares no " .. field, vim.log.levels.WARN)
    return
  end
  local selected = overrides[field]
  vim.ui.input({
    prompt = string.format("pydeps: %s [%s] (all, none) ", field, table.concat(declared, ", ")),
    default = selected and (#selected == 0 and "none" or table.concat(selected, ",")) or "all",
  }, function(input)
    if input and util.trim(input) ~= "" then
      apply(root, field, parse_names({ input }))
    end
  end)
end

---@param root string
---@return nil
local function open_menu(root)
  local items = {}
  for _, row in ipairs(context.describe(root)) do
    table.insert(items, {
      label = string.format("%-8s %s", row.field, row.value),
      value = row.field,
      details = { "(" .. row.source .. ")" },
    })
  end
  table.insert(items, { label = "reset all", value = "reset" })

  require("pydeps.ui.select_menu").show({
    prompt = "context",
    items = items,
    on_select = function(choice)
      if not choice then
        return
      end
      if choice.value == "reset" then
        context.reset(root)
        vim.notify("pydeps: context " .. context.summary(root), vim.log.levels.INFO)
        return
      end
      prompt_field(root, choice.value)
    end,
  })
end

---@return string?
local function current_root()
  local root = buffer_context.find_root(buffer_context.current_buf())
  if not root then
    vim.notify("pydeps: project root not found", vim.log.levels.WARN)
  end
  return root
end

---@param args string[]
---@return nil
function M.run(args)
  local root = current_root()
  if not root then
    return
  end

  local field = args[1]
  if not field then
    open_menu(root)
    return
  end

  if field == "reset" then
    local ok, err = context.reset(root, args[2])
    if not ok then
      vim.notify("pydeps: " .. err, vim.log.levels.WARN)
      return
    end
    vim.notify("pydeps: context " .. context.summary(root), vim.log.levels.INFO)
    return
  end

  if not vim.tbl_contains(context.FIELDS, field) then
    vim.notify("pydeps: unknown context field '" .. field .. "'", vim.log.levels.WARN)
    return
  end

  local values = vim.list_slice(args, 2)
  if #values == 0 then
    prompt_field(root, field)
  elseif field == "extras" or field == "groups" then
    apply(root, field, parse_names(values))
  else
    apply(root, field, values[1])
  end
end

---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  -- The word being completed is not yet in `words` when the line ends with a space.
  local position = #words - (arglead ~= "" and 1 or 0)
  local candidates = {}
  if position <= 1 then
    candidates = vim.list_extend({ "reset" }, context.FIELDS)
  elseif words[2] == "reset" and position == 2 then
    candidates = context.FIELDS
  elseif words[2] == "platform" and position == 2 then
    candidates = context.platforms()
  elseif words[2] == "extras" or words[2] == "groups" then
    local root = buffer_context.find_root(buffer_context.current_buf())
    candidates = vim.list_extend({ "all", "none" }, root and declared_names(root, words[2]) or {})
  end
  return vim.tbl_filter(function(candidate)
    return vim.startswith(candidate, arglead)
  end, candidates)
end

return M
