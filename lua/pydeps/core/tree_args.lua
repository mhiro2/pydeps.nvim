---@class PyDepsTreeArgs
---@field target string?
---@field depth integer?
---@field reverse boolean
---@field universal boolean
---@field show_sizes boolean
---@field all_groups boolean
---@field groups string[]
---@field no_groups string[]
---@field frozen boolean

---@class PyDepsTreeParseResult
---@field args PyDepsTreeArgs
---@field errors string[]

local M = {}

---@param input string
---@param bang boolean
---@return PyDepsTreeArgs
function M.parse(input, bang)
  ---@type PyDepsTreeArgs
  local result = {
    target = nil,
    depth = nil,
    reverse = bang or false,
    universal = false,
    show_sizes = false,
    all_groups = false,
    groups = {},
    no_groups = {},
    frozen = true,
  }

  if not input or input == "" then
    return result
  end

  -- Split input by whitespace, handling quoted strings
  local parts = {}
  local current = ""
  local in_quotes = false
  local quote_char = nil

  for i = 1, #input do
    local char = input:sub(i, i)
    if (char == '"' or char == "'") and not in_quotes then
      in_quotes = true
      quote_char = char
    elseif char == quote_char and in_quotes then
      in_quotes = false
      quote_char = nil
    elseif char == " " and not in_quotes then
      if current ~= "" then
        table.insert(parts, current)
        current = ""
      end
    else
      current = current .. char
    end
  end
  if current ~= "" then
    table.insert(parts, current)
  end

  -- Parse flags
  local i = 1
  while i <= #parts do
    local part = parts[i]
    local is_flag = part:match("^%-") ~= nil

    if not is_flag then
      -- Positional argument becomes target
      result.target = part
    elseif part == "--package" or part == "--target" then
      i = i + 1
      if i <= #parts then
        result.target = parts[i]
      end
    elseif part == "--depth" or part == "-d" then
      i = i + 1
      if i <= #parts then
        local depth = tonumber(parts[i])
        if depth then
          result.depth = depth
        end
      end
    elseif part == "--reverse" or part == "--invert" then
      result.reverse = true
    elseif part == "--universal" then
      result.universal = true
    elseif part == "--show-sizes" then
      result.show_sizes = true
    elseif part == "--all-groups" then
      result.all_groups = true
    elseif part == "--group" then
      i = i + 1
      if i <= #parts then
        table.insert(result.groups, parts[i])
      end
    elseif part == "--no-group" then
      i = i + 1
      if i <= #parts then
        table.insert(result.no_groups, parts[i])
      end
    elseif part == "--resolve" then
      result.frozen = false
    end

    i = i + 1
  end

  return result
end

return M
