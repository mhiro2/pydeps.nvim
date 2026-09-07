local util = require("pydeps.util")
local version = require("pydeps.core.version")
local M = {}
local cache = util.create_lru_cache(100)

local fields = {
  python_version = "version",
  python_full_version = "version",
  implementation_version = "version",
  platform_release = "version_or_string",
  platform_version = "version_or_string",
  os_name = "string",
  sys_platform = "string",
  platform_system = "string",
  platform_machine = "string",
  platform_python_implementation = "string",
  implementation_name = "string",
  extra = "extra",
  extras = "set",
  dependency_groups = "set",
  -- Project dependency group selectors are a pydeps extension.
  group = "string",
  dependency_group = "string",
}

local function tokenize(expr)
  local tokens, i = {}, 1
  while i <= #expr do
    local rest, ch = expr:sub(i), expr:sub(i, i)
    local value, kind
    if ch:match("%s") then
      i = i + 1
    else
      if ch == "'" or ch == '"' then
        local finish = expr:find(ch, i + 1, true)
        if not finish then
          return nil
        end
        value, kind = expr:sub(i + 1, finish - 1), "string"
        i = finish + 1
      else
        if ch == "(" or ch == ")" then
          value, kind = ch, ch
        else
          value = rest:match("^===") or rest:match("^[=<>!~]=") or rest:match("^[<>]")
          kind = "op"
          if not value then
            value = rest:match("^not%s+in%f[^%w_]")
            if not value then
              value = rest:match("^[%a_][%w_]*")
              kind = "ident"
            end
          end
        end
        if not value then
          return nil
        end
        i = i + #value
        if value:match("^not%s+in$") then
          value = "not in"
        elseif value == "in" or value == "and" or value == "or" then
          kind = "op"
        end
      end
      tokens[#tokens + 1] = { kind = kind, value = value }
    end
  end
  return tokens
end

local function parse(expr)
  local cached = cache:get(expr)
  if cached then
    return cached.node, cached.reason
  end
  local tokens = tokenize(expr)
  if not tokens then
    return nil, "invalid"
  end
  local pos, reason, depth = 1, nil, 0
  local parse_or
  local function operand()
    local token = tokens[pos]
    if not token or (token.kind ~= "ident" and token.kind ~= "string") then
      reason = "invalid"
      return nil
    end
    if token.kind == "ident" and not fields[token.value] then
      reason = "unknown"
    end
    pos = pos + 1
    return token
  end
  local function expression()
    depth = depth + 1
    if depth > 100 then
      reason = "invalid"
      return nil
    end
    local node
    if tokens[pos] and tokens[pos].kind == "(" then
      pos = pos + 1
      node = parse_or()
      if not tokens[pos] or tokens[pos].kind ~= ")" then
        reason = "invalid"
        return nil
      end
      pos = pos + 1
    else
      local left = operand()
      local op = tokens[pos]
      if not left or not op or op.kind ~= "op" or op.value == "and" or op.value == "or" then
        reason = "invalid"
        return nil
      end
      pos = pos + 1
      local right = operand()
      if not right or (left.kind == "ident") == (right.kind == "ident") then
        reason = "invalid"
        return nil
      end
      node = { op = op.value, left = left, right = right }
    end
    depth = depth - 1
    return node
  end
  local function parse_and()
    local node = expression()
    while node and tokens[pos] and tokens[pos].value == "and" do
      pos = pos + 1
      local right = expression()
      if not right then
        return nil
      end
      node = { op = "and", left = node, right = right }
    end
    return node
  end
  function parse_or()
    local node = parse_and()
    while node and tokens[pos] and tokens[pos].value == "or" do
      pos = pos + 1
      local right = parse_and()
      if not right then
        return nil
      end
      node = { op = "or", left = node, right = right }
    end
    return node
  end
  local node = parse_or()
  if pos <= #tokens then
    reason = "invalid"
  end
  if reason then
    node = nil
  end
  cache:set(expr, { node = node, reason = reason })
  return node, reason
end

local function normalize_extra(value)
  return (value:lower():gsub("[-_.]+", "-"))
end

local function evaluate(node, env)
  if node.op == "and" or node.op == "or" then
    local left, left_reason = evaluate(node.left, env)
    local right, right_reason = evaluate(node.right, env)
    -- Invalid comparisons cannot become valid through boolean short-circuiting.
    if left_reason == "invalid" or right_reason == "invalid" then
      return nil, "invalid"
    end
    if node.op == "and" then
      if left == false or right == false then
        return false
      elseif left == true and right == true then
        return true
      end
    elseif left == true or right == true then
      return true
    elseif left == false and right == false then
      return false
    end
    return nil, "pending"
  end
  local variable = node.left.kind == "ident" and node.left or node.right
  local field = fields[variable.value]
  local left, right = node.left.value, node.right.value
  if node.left.kind == "ident" then
    left = env[node.left.value]
  else
    right = env[node.right.value]
  end
  if env[variable.value] == nil then
    return nil, "pending"
  end
  local op = node.op
  if field == "set" then
    if type(right) ~= "table" or node.left.kind ~= "string" or (op ~= "in" and op ~= "not in") then
      return nil, "invalid"
    end
    local found = false
    for _, item in ipairs(right) do
      if type(item) ~= "string" then
        return nil, "invalid"
      end
      if normalize_extra(left) == normalize_extra(item) then
        found = true
      end
    end
    if op == "not in" then
      return not found
    end
    return found
  end
  if type(left) ~= "string" or type(right) ~= "string" then
    return nil, "invalid"
  end
  if field == "extra" then
    left, right = normalize_extra(left), normalize_extra(right)
  end
  if op == "in" or op == "not in" then
    -- Membership is substring containment for every field, including version
    -- fields: 'python_version in "3.9 3.10"' lists releases, it does not order them.
    local found = right:find(left, 1, true) ~= nil
    if op == "not in" then
      return not found
    end
    return found
  end
  if field == "version" or field == "version_or_string" then
    local result = version.matches(left, op, right)
    if result ~= nil then
      return result
    elseif field == "version" then
      return nil, "invalid"
    end
  end
  if op == "==" or op == "<=" or op == ">=" then
    return left == right
  elseif op == "!=" then
    return left ~= right
  elseif op == "<" or op == ">" then
    return false
  end
  return nil, "invalid"
end

---Evaluate a marker without guessing missing environment values.
---@param marker? string
---@param env? table<string, any>
---@return boolean? result
---@return "invalid"|"unknown"|"pending"? reason Invalid syntax/comparison, unknown field, or unavailable environment value.
function M.evaluate(marker, env)
  if not marker or util.trim(marker) == "" then
    return true
  end
  local node, reason = parse(marker)
  if not node then
    return nil, reason or "invalid"
  end
  return evaluate(node, env or {})
end

return M
