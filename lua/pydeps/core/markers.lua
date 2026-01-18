---@class PyDepsMarkerToken
---@field kind string
---@field value string

---@class PyDepsMarkerNode
---@field type string
---@field value? string
---@field op? string
---@field left? PyDepsMarkerNode
---@field right? PyDepsMarkerNode

local util = require("pydeps.util")

local M = {}

-- Cache for tokenize and parse results
---@type table<string, PyDepsMarkerToken[]>
local tokenize_cache = {}
---@type table<string, PyDepsMarkerNode?>
local parse_cache = {}

---@param expr string
---@return PyDepsMarkerToken[]
local function tokenize(expr)
  if tokenize_cache[expr] then
    return tokenize_cache[expr]
  end

  local tokens = {}
  local i = 1
  local len = #expr

  local function push(kind, value)
    table.insert(tokens, { kind = kind, value = value })
  end

  while i <= len do
    local ch = expr:sub(i, i)
    if ch:match("%s") then
      i = i + 1
    elseif ch == "(" or ch == ")" then
      push(ch, ch)
      i = i + 1
    elseif ch == "'" or ch == '"' then
      local quote = ch
      local j = i + 1
      local value = {}
      while j <= len do
        local cj = expr:sub(j, j)
        if cj == quote then
          break
        end
        table.insert(value, cj)
        j = j + 1
      end
      push("string", table.concat(value))
      i = j + 1
    else
      local rest = expr:sub(i)
      local op = rest:match("^not%s+in")
      if op then
        push("op", "not in")
        i = i + #op
      else
        op = rest:match("^(in)%f[%s]")
        if op then
          push("op", "in")
          i = i + #op
        else
          op = rest:match("^(and)%f[%s]")
          if op then
            push("op", "and")
            i = i + #op
          else
            op = rest:match("^(or)%f[%s]")
            if op then
              push("op", "or")
              i = i + #op
            else
              op = rest:match("^(===?)")
              if op then
                push("op", op)
                i = i + #op
              else
                op = rest:match("^([<>!]=)")
                if op then
                  push("op", op)
                  i = i + #op
                else
                  op = rest:match("^([<>])")
                  if op then
                    push("op", op)
                    i = i + #op
                  else
                    local ident = rest:match("^([%w_%.]+)")
                    if ident then
                      push("ident", ident)
                      i = i + #ident
                    else
                      i = i + 1
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  tokenize_cache[expr] = tokens
  return tokens
end

---@param tokens PyDepsMarkerToken[]
---@return PyDepsMarkerNode?
local function parser(tokens)
  -- Generate a cache key from tokens
  local cache_key = table.concat(
    vim.tbl_map(function(t)
      return t.kind .. ":" .. t.value
    end, tokens),
    "|"
  )

  if parse_cache[cache_key] ~= nil then
    return parse_cache[cache_key]
  end

  local pos = 1
  local parse_or

  local function peek()
    return tokens[pos]
  end

  local function consume()
    local t = tokens[pos]
    pos = pos + 1
    return t
  end

  local function parse_term()
    local t = peek()
    if not t then
      return nil
    end
    if t.kind == "string" then
      consume()
      return { type = "string", value = t.value }
    end
    if t.kind == "ident" then
      consume()
      return { type = "ident", value = t.value }
    end
    if t.kind == "(" then
      consume()
      local expr = parse_or()
      if peek() and peek().kind == ")" then
        consume()
      end
      return expr
    end
    return nil
  end

  local function parse_compare()
    local left = parse_term()
    local t = peek()
    if t and t.kind == "op" and t.value ~= "and" and t.value ~= "or" then
      local op = consume().value
      local right = parse_term()
      return { type = "compare", op = op, left = left, right = right }
    end
    return left
  end

  local function parse_and()
    local node = parse_compare()
    while true do
      local t = peek()
      if t and t.kind == "op" and t.value == "and" then
        consume()
        node = { type = "and", left = node, right = parse_compare() }
      else
        break
      end
    end
    return node
  end

  function parse_or()
    local node = parse_and()
    while true do
      local t = peek()
      if t and t.kind == "op" and t.value == "or" then
        consume()
        node = { type = "or", left = node, right = parse_and() }
      else
        break
      end
    end
    return node
  end

  local result = parse_or()
  parse_cache[cache_key] = result
  return result
end

---@param v string|number
---@return (string|number)[]
local function split_version(v)
  local parts = {}
  for part in tostring(v):gmatch("[^%.]+") do
    local num = tonumber(part)
    table.insert(parts, num or part)
  end
  return parts
end

---@param v string|number
---@return string
local function normalize_string(v)
  return util.trim(tostring(v)):lower()
end

---@param a string|number
---@param b string|number
---@return integer
local function compare_versions(a, b)
  local ap = split_version(a)
  local bp = split_version(b)
  local max_len = math.max(#ap, #bp)
  for i = 1, max_len do
    local av = ap[i] or 0
    local bv = bp[i] or 0
    if type(av) == "number" and type(bv) == "number" then
      if av ~= bv then
        return av < bv and -1 or 1
      end
    else
      local as = tostring(av)
      local bs = tostring(bv)
      if as ~= bs then
        return as < bs and -1 or 1
      end
    end
  end
  return 0
end

---@param value string|number
---@return string[]
local function to_list(value)
  local items = {}
  for item in tostring(value):gmatch("[^,%s]+") do
    table.insert(items, util.trim(item))
  end
  return items
end

---@param node? PyDepsMarkerNode
---@param env table<string, any>
---@return boolean|nil
local function evaluate(node, env)
  if not node then
    return true
  end
  if node.type == "string" then
    return node.value
  end
  if node.type == "ident" then
    local value = env[node.value]
    -- Return nil if env key is missing (not yet fetched)
    -- This distinguishes between "not fetched" and "falsy value"
    if value == nil then
      return nil
    end
    return value
  end
  if node.type == "and" then
    local left = evaluate(node.left, env)
    local right = evaluate(node.right, env)
    -- If either side is nil (not evaluated), return nil
    if left == nil or right == nil then
      return nil
    end
    return left and right
  end
  if node.type == "or" then
    local left = evaluate(node.left, env)
    local right = evaluate(node.right, env)
    -- If left is true, short-circuit (right doesn't matter)
    if left == true then
      return true
    end
    -- If left is false, check right
    if left == false then
      return right
    end
    -- left is nil, so result depends on right
    return right
  end
  if node.type == "compare" then
    local left = evaluate(node.left, env)
    local right = evaluate(node.right, env)
    -- Return nil if either side is nil (not evaluated)
    if left == nil or right == nil then
      return nil
    end
    local op = node.op
    if op == "in" or op == "not in" then
      local list = to_list(right)
      local found = false
      for _, item in ipairs(list) do
        if normalize_string(left) == normalize_string(item) then
          found = true
          break
        end
      end
      return op == "in" and found or not found
    end
    local compare = nil
    if type(left) == "string" and type(right) == "string" then
      if node.left.type == "ident" and node.left.value:match("python") then
        compare = compare_versions(left, right)
      else
        local l = normalize_string(left)
        local r = normalize_string(right)
        compare = l < r and -1 or (l > r and 1 or 0)
      end
    else
      compare = tostring(left) < tostring(right) and -1 or (tostring(left) > tostring(right) and 1 or 0)
    end
    if op == "==" then
      return compare == 0
    elseif op == "!=" then
      return compare ~= 0
    elseif op == "<" then
      return compare == -1
    elseif op == "<=" then
      return compare == -1 or compare == 0
    elseif op == ">" then
      return compare == 1
    elseif op == ">=" then
      return compare == 1 or compare == 0
    end
  end
  return false
end

---@param marker? string
---@param env? table<string, any>
---@return boolean|nil Returns true if marker evaluates to true, false if to false, nil if evaluation is incomplete (env keys not yet fetched)
function M.evaluate(marker, env)
  if not marker or util.trim(marker) == "" then
    return true
  end
  local tokens = tokenize(marker)
  local ast = parser(tokens)
  return evaluate(ast, env or {})
end

return M
