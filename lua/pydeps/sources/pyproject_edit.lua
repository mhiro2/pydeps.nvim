---@class PyDepsArrayInfo
---@field start_line integer
---@field end_line integer
---@field indent string
---@field key string
---@field inline boolean

local util = require("pydeps.util")

local M = {}

---@param lines string[]
---@param name string
---@return integer?
local function find_section(lines, name)
  for i, line in ipairs(lines) do
    local header = util.strip_toml_comment(line):match("^%s*%[([^%]]+)%]%s*$")
    if header == name then
      return i
    end
  end
  return nil
end

---@param lines string[]
---@param section string
---@param key string
---@return PyDepsArrayInfo?
local function find_array(lines, section, key)
  local current_section = nil
  local i = 1
  while i <= #lines do
    local header = util.strip_toml_comment(lines[i]):match("^%s*%[([^%]]+)%]%s*$")
    if header then
      current_section = header
      i = i + 1
    else
      if current_section == section then
        local stripped = util.strip_toml_comment(lines[i])
        local key_match = stripped:match("^%s*([%w%._%-]+)%s*=%s*%[")
        if key_match and key_match == key then
          local indent = lines[i]:match("^(%s*)") or ""
          local depth = util.count_brackets_outside_strings(stripped)
          local j = i
          while depth > 0 and j < #lines do
            j = j + 1
            depth = depth + util.count_brackets_outside_strings(util.strip_toml_comment(lines[j]))
          end
          return {
            start_line = i,
            end_line = j,
            indent = indent,
            key = key,
            inline = i == j,
          }
        end
      end
      i = i + 1
    end
  end
  return nil
end

---@param group string
---@return string?, string?
local function group_to_section(group)
  if group == "project" then
    return "project", "dependencies"
  end
  if group:match("^optional:") then
    return "project.optional-dependencies", group:sub(#"optional:" + 1)
  end
  if group:match("^group:") then
    return "dependency-groups", group:sub(#"group:" + 1)
  end
  return nil, nil
end

---@param lines string[]
---@param group string
---@return PyDepsArrayInfo?
function M.find_group(lines, group)
  local section, key = group_to_section(group)
  if not section then
    return nil
  end
  return find_array(lines, section, key)
end

---@param bufnr integer
---@param group string
---@param spec string
---@return boolean, string?
local function insert_new_group(bufnr, group, spec)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local section, key = group_to_section(group)
  if not section then
    return false, "invalid group"
  end

  local header_line = find_section(lines, section)
  local insert_at = #lines + 1
  if header_line then
    local j = header_line + 1
    local lines_count = #lines
    while j <= lines_count do
      local header = util.strip_toml_comment(lines[j]):match("^%s*%[([^%]]+)%]%s*$")
      if header then
        break
      end
      j = j + 1
    end
    insert_at = j
  else
    local lines_count = #lines
    if lines_count > 0 and util.trim(lines[lines_count]) ~= "" then
      table.insert(lines, "")
    end
    table.insert(lines, "[" .. section .. "]")
    insert_at = #lines + 1
  end

  local entry = key .. ' = ["' .. spec .. '"]'
  table.insert(lines, insert_at, entry)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return true
end

---@param bufnr integer
---@param group string
---@param spec string
---@return boolean, string?
function M.add_dependency(bufnr, group, spec)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local array = M.find_group(lines, group)
  if not array then
    return insert_new_group(bufnr, group, spec)
  end

  if array.inline then
    local line = lines[array.start_line]
    if line:match("%[%s*%]") then
      line = line:gsub("%[%s*%]", '["' .. spec .. '"]')
    else
      line = line:gsub("%]%s*$", ', "' .. spec .. '"]')
    end
    vim.api.nvim_buf_set_lines(bufnr, array.start_line - 1, array.start_line, false, { line })
    return true
  end

  local insert_line = array.end_line
  local last_entry = vim.api.nvim_buf_get_lines(bufnr, array.end_line - 2, array.end_line - 1, false)[1] or ""
  if last_entry ~= "" and not last_entry:match(",%s*$") then
    vim.api.nvim_buf_set_lines(bufnr, array.end_line - 2, array.end_line - 1, false, { last_entry .. "," })
  end
  local indent = array.indent .. "  "
  local entry = indent .. '"' .. spec .. '",'
  vim.api.nvim_buf_set_lines(bufnr, insert_line - 1, insert_line - 1, false, { entry })
  return true
end

---@param bufnr integer
---@param dep PyDepsDependency
---@param spec string
---@return boolean
function M.replace_dependency(bufnr, dep, spec)
  if not dep or not dep.line then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, dep.line - 1, dep.line, false)[1] or ""
  local quote = line:sub(dep.col_start, dep.col_start)
  if quote ~= '"' and quote ~= "'" then
    quote = '"'
  end
  local new_text = quote .. spec .. quote
  vim.api.nvim_buf_set_text(bufnr, dep.line - 1, dep.col_start - 1, dep.line - 1, dep.col_end, { new_text })
  return true
end

---@param bufnr integer
---@param dep PyDepsDependency
---@return boolean
function M.remove_dependency(bufnr, dep)
  if not dep or not dep.line then
    return false
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, dep.line - 1, dep.line, false)[1] or ""
  local before = line:sub(1, dep.col_start - 1)
  local after = line:sub(dep.col_end + 1)
  if after:match("^%s*,") then
    after = after:gsub("^%s*,%s*", " ")
  elseif before:match(",%s*$") then
    before = before:gsub(",%s*$", "")
  end
  local new_line = before .. after
  if util.trim(new_line) == "" then
    vim.api.nvim_buf_set_lines(bufnr, dep.line - 1, dep.line, false, {})
  else
    local cleaned = new_line:gsub("%s+%]", "]")
    vim.api.nvim_buf_set_lines(bufnr, dep.line - 1, dep.line, false, { cleaned })
  end
  return true
end

return M
