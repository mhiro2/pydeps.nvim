---@class PyDepsStringRange
---@field start_col integer
---@field end_col integer
---@field closed boolean
---@field quote string

---@class PyDepsStringContext
---@field value string
---@field start_col integer
---@field end_col integer

local M = {}

---@param line string
---@param idx integer
---@return boolean
local function is_escaped(line, idx)
  local count = 0
  local j = idx - 1
  while j >= 1 and line:sub(j, j) == "\\" do
    count = count + 1
    j = j - 1
  end
  return count % 2 == 1
end

---@param line string
---@return PyDepsStringRange[]
function M.scan_strings(line)
  local ranges = {}
  local i = 1
  local len = #line

  while i <= len do
    local ch = line:sub(i, i)
    if ch == "'" or ch == '"' then
      local quote = ch
      local start_col = i
      i = i + 1
      local closed = false
      while i <= len do
        local current = line:sub(i, i)
        if current == quote and not is_escaped(line, i) then
          closed = true
          break
        end
        i = i + 1
      end
      local end_col = closed and i or (len + 1)
      ranges[#ranges + 1] = {
        start_col = start_col,
        end_col = end_col,
        closed = closed,
        quote = quote,
      }
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
function M.string_context(line, col)
  for _, range in ipairs(M.scan_strings(line)) do
    if col > range.start_col and col <= range.end_col then
      return {
        value = line:sub(range.start_col + 1, range.end_col - 1),
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
function M.token_range(value, pos, pattern)
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

return M
