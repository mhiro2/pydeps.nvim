local M = {}

-- Parse the normalized components defined by PEP 440, without executing Python.
local function parse(value)
  local rest = value:match("^%s*(.-)%s*$"):lower():gsub("^v", "")
  local epoch = rest:match("^(%d+)!")
  if epoch then
    rest = rest:sub(#epoch + 2)
  end
  local release = rest:match("^%d+[%.%d]*")
  if not release then
    return nil
  end
  release = release:gsub("%.$", "")
  if release:find("..", 1, true) then
    return nil
  end
  rest = rest:sub(#release + 1)
  local result = { epoch = tonumber(epoch) or 0, release = {} }
  for part in release:gmatch("%d+") do
    table.insert(result.release, tonumber(part))
  end
  local function suffix(labels)
    for _, label in ipairs(labels) do
      local prefix, digits = rest:match("^([%._%-]?" .. label .. "[%._%-]?)(%d*)")
      if prefix then
        rest = rest:sub(#prefix + #digits + 1)
        return label, tonumber(digits) or 0
      end
    end
  end
  local label, number = suffix({ "alpha", "beta", "preview", "pre", "rc", "a", "b", "c" })
  if label then
    local ranks = { alpha = 0, a = 0, beta = 1, b = 1, preview = 2, pre = 2, rc = 2, c = 2 }
    result.pre = { ranks[label], number }
  end
  local implicit_post = rest:match("^%-(%d+)")
  if implicit_post then
    result.post = tonumber(implicit_post)
    rest = rest:sub(#implicit_post + 2)
  else
    label, number = suffix({ "post", "rev", "r" })
    if label then
      result.post = number
    end
  end
  label, number = suffix({ "dev" })
  if label then
    result.dev = number
  end
  if rest:sub(1, 1) == "+" then
    local local_part = rest:sub(2)
    if
      not local_part:match("^[a-z%d]+[a-z%d%._%-]*$")
      or local_part:find("[%._%-][%._%-]")
      or local_part:find("[%._%-]$")
    then
      return nil
    end
    result.local_parts = {}
    for part in local_part:gmatch("[^%._%-]+") do
      table.insert(result.local_parts, tonumber(part) or part)
    end
    rest = ""
  end
  if rest ~= "" then
    return nil
  end
  return result
end

local function cmp(a, b)
  if a == b then
    return 0
  end
  return a < b and -1 or 1
end

local function release_cmp(a, b, count)
  for i = 1, count or math.max(#a.release, #b.release) do
    local order = cmp(a.release[i] or 0, b.release[i] or 0)
    if order ~= 0 then
      return order
    end
  end
  return 0
end

local function compare(a, b, include_local)
  local order = cmp(a.epoch, b.epoch)
  if order == 0 then
    order = release_cmp(a, b)
  end
  if order ~= 0 then
    return order
  end
  local function pre_key(v)
    if v.pre then
      return v.pre
    end
    if v.dev and not v.post then
      return { -1, 0 }
    end
    return { math.huge, 0 }
  end
  local ap, bp = pre_key(a), pre_key(b)
  for _, pair in ipairs({
    { ap[1], bp[1] },
    { ap[2], bp[2] },
    { a.post or -1, b.post or -1 },
    { a.dev or math.huge, b.dev or math.huge },
  }) do
    order = cmp(pair[1], pair[2])
    if order ~= 0 then
      return order
    end
  end
  if include_local then
    local al, bl = a.local_parts or {}, b.local_parts or {}
    for i = 1, math.max(#al, #bl) do
      if al[i] == nil then
        return -1
      elseif bl[i] == nil then
        return 1
      elseif type(al[i]) ~= type(bl[i]) then
        return type(al[i]) == "number" and 1 or -1
      end
      order = cmp(al[i], bl[i])
      if order ~= 0 then
        return order
      end
    end
  end
  return 0
end

---Apply a PEP 440 specifier to a concrete version, including prereleases.
---@return boolean? matched nil for an invalid version or specifier
function M.matches(value, op, spec)
  if op == "===" then
    return value:lower() == spec:lower()
  end
  local wildcard = spec:sub(-2) == ".*"
  local a, b = parse(value), parse(wildcard and spec:sub(1, -3) or spec)
  if not a or not b then
    return nil
  end
  if wildcard then
    if (op ~= "==" and op ~= "!=") or b.pre or b.post or b.dev or b.local_parts then
      return nil
    end
    local equal = a.epoch == b.epoch and release_cmp(a, b, #b.release) == 0
    if op == "!=" then
      return not equal
    end
    return equal
  end
  if op ~= "==" and op ~= "!=" and b.local_parts then
    return nil
  end
  local order = compare(a, b, b.local_parts ~= nil)
  if op == "==" then
    return order == 0
  elseif op == "!=" then
    return order ~= 0
  elseif op == "~=" then
    if #b.release < 2 then
      return nil
    end
    return order >= 0 and a.epoch == b.epoch and release_cmp(a, b, #b.release - 1) == 0
  elseif op == ">=" then
    return order >= 0
  elseif op == "<=" then
    return order <= 0
  elseif op == "<" then
    -- Exclusive comparisons exclude prereleases of a final upper bound.
    if not b.pre and not b.dev and (a.pre or a.dev) and a.epoch == b.epoch and release_cmp(a, b) == 0 then
      return false
    end
    return order < 0
  elseif op == ">" then
    -- A postrelease of the same base is not greater than an unqualified bound.
    if
      not b.post
      and a.post
      and a.epoch == b.epoch
      and release_cmp(a, b) == 0
      and compare(
          { epoch = a.epoch, release = a.release, pre = a.pre },
          { epoch = b.epoch, release = b.release, pre = b.pre },
          false
        )
        == 0
    then
      return false
    end
    return order > 0
  end
  return nil
end

return M
