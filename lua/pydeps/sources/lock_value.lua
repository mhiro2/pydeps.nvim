-- Decode the strings, arrays and inline tables emitted in uv lockfiles.
local M = {}

function M.parse(text)
  local pos = 1
  local parse
  local function skip()
    local _, last = text:find("^%s*", pos)
    pos = (last or pos - 1) + 1
  end
  local function string_value()
    local quote = text:sub(pos, pos)
    local start = pos
    pos = pos + 1
    while pos <= #text do
      local char = text:sub(pos, pos)
      if char == quote then
        local raw = text:sub(start, pos)
        pos = pos + 1
        if quote == "'" then
          return raw:sub(2, -2)
        end
        -- Preserve escaped backslashes while translating TOML's eight-digit escape.
        local chunks, index = {}, 1
        while index <= #raw do
          local token = raw:sub(index, index + 1)
          if token == "\\U" then
            local hex = raw:sub(index + 2, index + 9)
            assert(hex:match("^%x%x%x%x%x%x%x%x$"), "invalid Unicode escape")
            local code = tonumber(hex, 16)
            assert(code <= 0x10FFFF and not (code >= 0xD800 and code <= 0xDFFF), "invalid Unicode scalar")
            chunks[#chunks + 1] = vim.json.encode(vim.fn.nr2char(code)):sub(2, -2)
            index = index + 10
          elseif raw:sub(index, index) == "\\" then
            chunks[#chunks + 1] = token
            index = index + 2
          else
            chunks[#chunks + 1] = raw:sub(index, index)
            index = index + 1
          end
        end
        raw = table.concat(chunks)
        return vim.json.decode(raw)
      elseif char == "\\" and quote == '"' then
        pos = pos + 1
      end
      pos = pos + 1
    end
    error("unfinished string")
  end
  parse = function()
    skip()
    local char = text:sub(pos, pos)
    if char == '"' or char == "'" then
      return string_value()
    end
    if char == "[" or char == "{" then
      local close = char == "[" and "]" or "}"
      local result = {}
      pos = pos + 1
      skip()
      while text:sub(pos, pos) ~= close do
        if pos > #text then
          error("unfinished collection")
        end
        if char == "{" then
          local key
          if text:sub(pos, pos):match("[\"']") then
            key = string_value()
          else
            key = text:match("^([%w_-]+)", pos)
            assert(key, "invalid key")
            pos = pos + #key
          end
          skip()
          assert(text:sub(pos, pos) == "=", "expected equals")
          pos = pos + 1
          result[key] = parse()
        else
          table.insert(result, parse())
        end
        skip()
        if text:sub(pos, pos) == "," then
          pos = pos + 1
          skip()
        else
          assert(text:sub(pos, pos) == close, "expected separator")
        end
      end
      pos = pos + 1
      return result
    end
    error("unsupported lockfile value")
  end
  local ok, result = pcall(function()
    local value = parse()
    skip()
    assert(pos > #text, "trailing value")
    return value
  end)
  if ok then
    return result
  end
end

return M
