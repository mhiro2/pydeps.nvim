---@class PyDepsQuotedString
---@field value string
---@field start_col integer
---@field end_col integer

local M = {}

---@param s string
---@return string
function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param s string
---@param char string
---@return integer
function M.count_char(s, char)
  local _, count = s:gsub(char, "")
  return count
end

---@param spec? string
---@return string?
function M.parse_requirement_name(spec)
  if not spec or spec == "" then
    return nil
  end
  local without_marker = spec:match("^[^;]+") or spec
  local trimmed = M.trim(without_marker)
  local name = trimmed:match("^([%w%._%-]+)")
  if not name then
    return nil
  end
  return name:lower()
end

---@param spec? string
---@return string[]
function M.parse_requirement_extras(spec)
  if not spec or spec == "" then
    return {}
  end

  local without_marker = spec:match("^[^;]+") or spec
  local extras_blob = without_marker:match("%[(.-)%]")
  if not extras_blob or extras_blob == "" then
    return {}
  end

  local extras = {}
  local seen = {}
  for part in extras_blob:gmatch("[^,]+") do
    local extra = M.trim(part)
    if extra ~= "" and not seen[extra] then
      seen[extra] = true
      table.insert(extras, extra)
    end
  end

  return extras
end

---@param line string
---@return PyDepsQuotedString[]
function M.parse_quoted_strings(line)
  local results = {}
  local idx = 1
  while true do
    local s, e, _, value = line:find("(['\"])(.-)%1", idx)
    if not s then
      break
    end
    table.insert(results, {
      value = value,
      start_col = s,
      end_col = e,
    })
    idx = e + 1
  end
  return results
end

---@param line string
---@param idx integer
---@return boolean
local function is_escaped(line, idx)
  local escaped = false
  local i = idx - 1
  while i >= 1 and line:sub(i, i) == "\\" do
    escaped = not escaped
    i = i - 1
  end
  return escaped
end

---@param line string
---@return string
function M.strip_toml_comment(line)
  local in_single = false
  local in_double = false
  for i = 1, #line do
    local ch = line:sub(i, i)
    if ch == "'" and not in_double then
      in_single = not in_single
    elseif ch == '"' and not in_single then
      if not is_escaped(line, i) then
        in_double = not in_double
      end
    elseif ch == "#" and not in_single and not in_double then
      return line:sub(1, i - 1)
    end
  end
  return line
end

---@param line string
---@return integer?
function M.find_comment_pos(line)
  local in_single = false
  local in_double = false
  for i = 1, #line do
    local ch = line:sub(i, i)
    if ch == "'" and not in_double then
      in_single = not in_single
    elseif ch == '"' and not in_single then
      if not is_escaped(line, i) then
        in_double = not in_double
      end
    elseif ch == "#" and not in_single and not in_double then
      return i
    end
  end
  return nil
end

---@param line string
---@return integer
function M.count_brackets_outside_strings(line)
  local in_single = false
  local in_double = false
  local delta = 0
  for i = 1, #line do
    local ch = line:sub(i, i)
    if ch == "'" and not in_double then
      in_single = not in_single
    elseif ch == '"' and not in_single then
      if not is_escaped(line, i) then
        in_double = not in_double
      end
    elseif not in_single and not in_double then
      if ch == "[" then
        delta = delta + 1
      elseif ch == "]" then
        delta = delta - 1
      end
    end
  end
  return delta
end

---@param path? string
---@return boolean
function M.is_pyproject(path)
  return path and path:match("pyproject%.toml$") ~= nil
end

---Get the dependency under cursor by checking cursor position against dependency ranges
---@param deps PyDepsDependency[]
---@return PyDepsDependency?
function M.dep_under_cursor(deps)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local line = cursor[1]
  local col = cursor[2] + 1
  local target = nil
  for _, dep in ipairs(deps or {}) do
    if dep.line == line then
      if col >= dep.col_start and col <= dep.col_end then
        return dep
      end
      if not target then
        target = dep
      end
    end
  end
  return target
end

return M
