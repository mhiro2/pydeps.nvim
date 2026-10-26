---@class PyDepsLockChange
---@field kind "update"|"add"|"remove"
---@field name string
---@field from? string[]
---@field to? string[]

---@class PyDepsDryRun
---@field ok boolean
---@field changes PyDepsLockChange[]
---@field error? string

---@class PyDepsUpdateCandidate
---@field kind "lock"|"pin"|"declare"
---@field version string Version(s) the lock moves to, comma separated for forks
---@field upgrade string Argument for `uv lock --upgrade-package`
---@field spec? string Rewritten declaration, only for "declare"
---@field note? string
---@field changes? PyDepsLockChange[] Lock changes planned by uv, only for "lock"

---@class PyDepsUpdatePlanInput
---@field name string Normalized package name
---@field spec string Declared requirement
---@field locked string[] Versions of the package in uv.lock
---@field meta? PyDepsPyPIMeta
---@field python? string Lowest Python version the project supports
---@field dry_run? PyDepsDryRun

---@class PyDepsUpdatePlan
---@field candidates PyDepsUpdateCandidate[]
---@field notes string[]

local pypi = require("pydeps.providers.pypi")
local util = require("pydeps.util")
local version = require("pydeps.core.version")

local M = {}

local KINDS = { Update = "update", Add = "add", Remove = "remove" }

---@param text string
---@return string[]
local function split_versions(text)
  local versions = {}
  for item in text:gmatch("[^,%s]+") do
    table.insert(versions, (item:gsub("^v", "")))
  end
  return versions
end

---Read the changes `uv lock --dry-run` reports, e.g. `Update requests v2.31.0 -> v2.32.3`.
---@param output? string
---@return PyDepsLockChange[]
function M.parse_dry_run(output)
  local changes = {}
  for line in (output or ""):gmatch("[^\n]+") do
    local verb, name, rest = line:match("^%s*(%a+)%s+(%S+)%s+(v.+)$")
    local kind = verb and KINDS[verb]
    if kind then
      local change = { kind = kind, name = util.normalize_package_name(name) }
      if kind == "update" then
        local from, to = rest:match("^(.-)%s+%->%s+(.+)$")
        if from then
          change.from, change.to = split_versions(from), split_versions(to)
        end
      elseif kind == "add" then
        change.to = split_versions(rest)
      else
        change.from = split_versions(rest)
      end
      if change.from or change.to then
        table.insert(changes, change)
      end
    end
  end
  return changes
end

---@param versions string[]
---@return string?
local function newest(versions)
  local best
  for _, item in ipairs(versions or {}) do
    if not best or (version.compare(item, best) or 0) > 0 then
      best = item
    end
  end
  return best
end

---@param spec string
---@return { name: string, specifiers: string, marker?: string }?
local function split_requirement(spec)
  local req, marker = spec:match("^(.-)%s*;%s*(.+)$")
  req = util.trim(req or spec)
  local name = req:match("^[%w%._%-]+%s*%b[]") or req:match("^[%w%._%-]+")
  if not name then
    return nil
  end
  local specifiers = util.trim(req:sub(#name + 1))
  specifiers = specifiers:match("^%((.*)%)$") or specifiers
  return { name = name:gsub("%s+", ""), specifiers = util.trim(specifiers), marker = marker and util.trim(marker) }
end

---@param release integer[]
---@param count integer
---@return string
local function release_prefix(release, count)
  local parts = {}
  for i = 1, count do
    parts[i] = tostring(release[i] or 0)
  end
  return table.concat(parts, ".")
end

---Move an upper bound past `release` at the precision the bound was written
---with, so `<3` becomes `<4` and `<2.1` becomes `<2.4` for 2.3.0.
---@param bound integer[]
---@param release integer[]
---@return string
local function raise_upper_bound(bound, release)
  local index = #bound
  while index > 1 and bound[index] == 0 do
    index = index - 1
  end
  local parts = {}
  for i = 1, #bound do
    if i < index then
      parts[i] = tostring(release[i] or 0)
    elseif i == index then
      parts[i] = tostring((release[i] or 0) + 1)
    else
      parts[i] = "0"
    end
  end
  return table.concat(parts, ".")
end

---@param clause { op: string, version: string }
---@param target string
---@param release integer[]
---@param epoch string Epoch prefix of the target such as `1!`, empty for none
---@return string? clause nil when the clause is dropped
local function rewrite_clause(clause, target, release, epoch)
  local wildcard = clause.version:sub(-2) == ".*"
  local bound = version.release(wildcard and clause.version:sub(1, -3) or clause.version)
  if not bound then
    return clause.op .. clause.version
  end
  if clause.op == ">=" or clause.op == ">" then
    return ">=" .. target
  elseif clause.op == "===" then
    return "===" .. target
  elseif clause.op == "==" then
    return "==" .. (wildcard and epoch .. release_prefix(release, #bound) .. ".*" or target)
  elseif clause.op == "~=" then
    return "~=" .. epoch .. release_prefix(release, math.max(#bound, 2))
  elseif version.matches(target, clause.op, clause.version) then
    return clause.op .. clause.version
  elseif clause.op == "<=" then
    return "<=" .. target
  elseif clause.op == "<" then
    return "<" .. epoch .. raise_upper_bound(bound, release)
  end
  -- An exclusion of the target itself has no meaning once the target is chosen.
  return nil
end

---Rewrite a requirement so it admits `target`: lower bounds move to the
---target, and bounds that exclude it move just past it at their precision.
---@param spec string
---@param target string
---@return string? spec nil when the requirement cannot be rewritten safely
function M.rewrite_spec(spec, target)
  local req = split_requirement(spec)
  local release = version.release(target)
  if not req or not release then
    return nil
  end
  local clauses = version.parse_specifiers(req.specifiers)
  if not clauses then
    return nil
  end
  if #clauses == 0 then
    clauses = { { op = ">=", version = target } }
  end
  local epoch = target:match("^%s*(%d+!)") or ""
  local rewritten = {}
  for _, clause in ipairs(clauses) do
    table.insert(rewritten, rewrite_clause(clause, target, release, epoch))
  end
  local specifiers = table.concat(rewritten, ",")
  if version.satisfies(target, specifiers) ~= true then
    return nil
  end
  return req.name .. specifiers .. (req.marker and "; " .. req.marker or "")
end

---Highest lower bound of a `requires-python` range, e.g. `3.9` for `>=3.9,<4`.
---@param requires_python? string
---@return string?
function M.python_floor(requires_python)
  local floor
  for _, clause in ipairs(requires_python and version.parse_specifiers(requires_python) or {}) do
    if clause.op == ">=" or clause.op == ">" or clause.op == "~=" or clause.op == "==" then
      local bound = clause.version:gsub("%.%*$", "")
      if not floor or (version.compare(bound, floor) or 0) > 0 then
        floor = bound
      end
    end
  end
  return floor
end

---@param meta? PyDepsPyPIMeta
---@return { version: string, requires_python?: string }[] newest first
local function releases(meta)
  local result = {}
  for name, files in pairs(meta and meta.releases or {}) do
    if #files > 0 and version.is_prerelease(name) == false and not pypi.is_yanked(meta, name) then
      -- PyPI sends `null` (decoded as vim.NIL) for releases without the field.
      local requires_python = files[1].requires_python
      table.insert(result, {
        version = name,
        requires_python = type(requires_python) == "string" and requires_python ~= "" and requires_python or nil,
      })
    end
  end
  table.sort(result, function(a, b)
    return (version.compare(a.version, b.version) or 0) > 0
  end)
  return result
end

---Collect the versions a dependency can move to, split by what each needs:
---uv's own upgrade, a pin within the declared range, or a declaration change.
---@param input PyDepsUpdatePlanInput
---@return PyDepsUpdatePlan
function M.build(input)
  local candidates, notes = {}, {}
  local req = split_requirement(input.spec)
  local specifiers = req and req.specifiers or ""
  local locked = newest(input.locked)

  local function python_ok(release)
    if not input.python or not release.requires_python then
      return true
    end
    return version.satisfies(input.python, release.requires_python) ~= false
  end
  local function newer(target)
    return not locked or (version.compare(target, locked) or 0) > 0
  end

  local dry_run = input.dry_run
  local upgrade
  for _, change in ipairs(dry_run and dry_run.changes or {}) do
    if change.kind == "update" and change.name == input.name then
      upgrade = change
    end
  end
  local resolved = upgrade and newest(upgrade.to)
  if upgrade then
    table.insert(candidates, {
      kind = "lock",
      version = table.concat(upgrade.to, ", "),
      upgrade = input.name,
      changes = dry_run.changes,
    })
  end

  local available = releases(input.meta)
  local in_range, compatible
  for _, release in ipairs(available) do
    if python_ok(release) then
      compatible = compatible or release
      if not in_range and version.satisfies(release.version, specifiers) == true then
        in_range = release
      end
    end
  end

  if
    in_range
    and newer(in_range.version)
    and (not resolved or (version.compare(in_range.version, resolved) or 0) > 0)
  then
    table.insert(candidates, {
      kind = "pin",
      version = in_range.version,
      upgrade = input.name .. "==" .. in_range.version,
      note = resolved and ("uv resolves " .. resolved)
        or (dry_run and dry_run.ok and "uv keeps the locked version")
        or nil,
    })
  end

  if compatible and newer(compatible.version) and version.satisfies(compatible.version, specifiers) == false then
    local spec = M.rewrite_spec(input.spec, compatible.version)
    if spec then
      table.insert(candidates, {
        kind = "declare",
        version = compatible.version,
        upgrade = input.name .. "==" .. compatible.version,
        spec = spec,
        note = compatible == available[1] and "latest" or ("newest for Python " .. input.python),
      })
    else
      table.insert(
        notes,
        ("latest %s is outside %s; update the declaration manually"):format(compatible.version, specifiers)
      )
    end
  end

  local latest = available[1]
  if latest and not python_ok(latest) then
    table.insert(
      notes,
      ("latest %s requires Python %s (project supports %s)"):format(
        latest.version,
        latest.requires_python,
        input.python
      )
    )
  end
  if not input.meta then
    table.insert(notes, "PyPI metadata not available")
  end
  if dry_run and not dry_run.ok then
    table.insert(notes, "uv lock --dry-run failed: " .. (dry_run.error or "unknown error"))
  end

  return { candidates = candidates, notes = notes }
end

return M
