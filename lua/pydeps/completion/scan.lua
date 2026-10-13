---@class PyDepsStringRange
---@field start_col integer
---@field end_col integer
---@field closed boolean
---@field quote string

---@class PyDepsStringContext
---@field value string
---@field start_col integer
---@field end_col integer
---@field quote string

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
        quote = range.quote,
      }
    end
  end
  return nil
end

---Find the token around an insertion point.
---Returns the half-open range [left, right) of characters matching `pattern`
---around `pos`. When no token touches `pos`, the range is empty (left == right == pos)
---so an edit inserts text without consuming neighbouring delimiters.
---@param value string
---@param pos integer insertion index (1 .. #value + 1)
---@param pattern string
---@return integer, integer
function M.token_range(value, pos, pattern)
  pos = math.max(1, math.min(pos, #value + 1))

  local left = pos
  while left > 1 and value:sub(left - 1, left - 1):match(pattern) do
    left = left - 1
  end

  local right = pos
  while right <= #value and value:sub(right, right):match(pattern) do
    right = right + 1
  end

  return left, right
end

return M
