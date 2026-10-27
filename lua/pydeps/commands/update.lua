local buffer_context = require("pydeps.core.buffer_context")
local cache = require("pydeps.core.cache")
local edit = require("pydeps.sources.pyproject_edit")
local resolve = require("pydeps.commands.resolve")
local update_plan = require("pydeps.core.update_plan")
local util = require("pydeps.util")
local version = require("pydeps.core.version")

local M = {}

local MAX_CHANGE_LINES = 8

---@param target string
---@param deps PyDepsDependency[]
---@return PyDepsDependency?
local function find_dep_by_name(target, deps)
  local normalized_target = util.parse_requirement_name(target)
  for _, dep in ipairs(deps or {}) do
    local normalized_name = util.parse_requirement_name(dep.name)
    if normalized_name == normalized_target then
      return dep
    end
  end
  return nil
end

---@param spec string
---@return boolean
local function is_direct_reference(spec)
  if spec:find("%s@%s") or spec:find("^[%w%._%-]+@") then
    return true
  end
  if spec:match("https?://") then
    return true
  end
  if spec:match("file://") then
    return true
  end
  if spec:match("%.%/") then
    return true
  end
  return false
end

---@param bufnr integer
---@return string?
local function project_requires_python(bufnr)
  local section
  for _, raw in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local line = util.strip_toml_comment(raw)
    local header = line:match("^%s*%[%[?([^%[%]]+)%]%]?%s*$")
    if header then
      section = util.trim(header)
    elseif section == "project" then
      local value = line:match("^%s*requires%-python%s*=%s*[\"'](.-)[\"']")
      if value then
        return value
      end
    end
  end
  return nil
end

---@param lock PyDepsLockfileData
---@param name string
---@return string[]
local function locked_versions(lock, name)
  local versions, seen = {}, {}
  for _, id in ipairs(lock.by_name and lock.by_name[name] or {}) do
    local locked = lock.packages[id].version
    if locked and not seen[locked] then
      seen[locked] = true
      table.insert(versions, locked)
    end
  end
  table.sort(versions, function(a, b)
    return (version.compare(a, b) or 0) < 0
  end)
  return versions
end

---@param result PyDepsUvResolveResult
---@return string
local function dry_run_error(result)
  if result.reason == "missing_uv" then
    return "uv not found in PATH"
  elseif result.reason == "timeout" then
    return "timed out"
  end
  local stderr = result.stderr or ""
  local start = stderr:find("error:", 1, true)
  return start and util.trim(stderr:sub(start)) or ("exit code " .. result.code)
end

---@param change PyDepsLockChange
---@return string
local function change_line(change)
  if change.kind == "update" then
    return ("~ %s %s -> %s"):format(change.name, table.concat(change.from, ", "), table.concat(change.to, ", "))
  elseif change.kind == "add" then
    return ("+ %s %s"):format(change.name, table.concat(change.to, ", "))
  end
  return ("- %s %s"):format(change.name, table.concat(change.from, ", "))
end

---@param changes PyDepsLockChange[]
---@return string[]
local function change_lines(changes)
  local lines = {}
  for i, change in ipairs(changes) do
    if i > MAX_CHANGE_LINES then
      table.insert(lines, ("... %d more"):format(#changes - MAX_CHANGE_LINES))
      break
    end
    table.insert(lines, change_line(change))
  end
  return lines
end

---@param candidate PyDepsUpdateCandidate
---@param dep PyDepsDependency
---@param from string
---@return PyDepsSelectOption
local function menu_item(candidate, dep, from)
  local transition = ("%s -> %s"):format(from, candidate.version)
  if candidate.kind == "lock" then
    return {
      label = transition .. "  keep declaration (resolved by uv)",
      details = change_lines(candidate.changes),
      value = candidate,
    }
  elseif candidate.kind == "pin" then
    local note = candidate.note and "; " .. candidate.note or ""
    return {
      label = ("%s  keep declaration (latest in range%s)"):format(transition, note),
      value = candidate,
    }
  end
  return {
    label = ("%s  change declaration (%s)"):format(transition, candidate.note),
    details = { dep.spec .. "  =>  " .. candidate.spec },
    value = candidate,
  }
end

---Write the buffer and report whether the file reached disk; an error raised
---by a write autocommand after the file was written still counts as written.
---@param bufnr integer
---@return boolean
local function write_buffer(bufnr)
  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent write")
  end)
  return not vim.bo[bufnr].modified
end

---Rewrite the declaration, save it for uv and lock; undo the rewrite if uv
---cannot lock it, so a failed update leaves pyproject.toml as it was.
---@param bufnr integer
---@param dep PyDepsDependency
---@param root string
---@param candidate PyDepsUpdateCandidate
---@return nil
local function apply_declaration(bufnr, dep, root, candidate)
  local row = dep.line - 1
  local original = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  edit.replace_dependency(bufnr, dep, candidate.spec)
  local edited = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not write_buffer(bufnr) then
    vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { original })
    vim.bo[bufnr].modified = false
    vim.notify("pydeps: failed to write pyproject.toml; update cancelled", vim.log.levels.ERROR)
    return
  end
  local written = vim.api.nvim_buf_get_changedtick(bufnr)
  resolve.lock(root, {
    args = { "--upgrade-package", candidate.upgrade },
    on_finish = function(ok)
      if ok then
        return
      end
      -- Restore only the line we wrote: an edit since, or a formatter that
      -- moved it on save, would make the old line number point elsewhere.
      if
        not vim.api.nvim_buf_is_valid(bufnr)
        or vim.api.nvim_buf_get_changedtick(bufnr) ~= written
        or vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] ~= edited
      then
        vim.notify("pydeps: buffer changed during uv lock; declaration left as " .. candidate.spec, vim.log.levels.WARN)
        return
      end
      vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { original })
      if write_buffer(bufnr) then
        vim.notify("pydeps: restored declaration " .. dep.spec, vim.log.levels.WARN)
      else
        vim.notify("pydeps: failed to save the restored declaration " .. dep.spec, vim.log.levels.ERROR)
      end
    end,
  })
end

---@param bufnr integer
---@param dep PyDepsDependency
---@param root string
---@param plan PyDepsUpdatePlan
---@param locked string[]
---@param changedtick integer
---@return nil
local function show_plan(bufnr, dep, root, plan, locked, changedtick)
  local name = util.normalize_package_name(dep.name)
  local from = #locked > 0 and table.concat(locked, ", ") or "(not locked)"
  if #plan.candidates == 0 then
    local message = ("pydeps: no update available for %s (locked %s)"):format(name, from)
    if #plan.notes > 0 then
      message = message .. "\n" .. table.concat(plan.notes, "\n")
    end
    vim.notify(message, vim.log.levels.INFO)
    return
  end

  local header = { "declared  " .. dep.spec, "locked    " .. from }
  for _, note in ipairs(plan.notes) do
    vim.list_extend(header, vim.split(note, "\n", { plain = true }))
  end
  local items = {}
  for _, candidate in ipairs(plan.candidates) do
    table.insert(items, menu_item(candidate, dep, from))
  end

  require("pydeps.ui.select_menu").show({
    prompt = "update " .. name,
    header = header,
    items = items,
    on_select = function(choice)
      if not choice then
        return
      end
      if
        not vim.api.nvim_buf_is_valid(bufnr)
        or vim.api.nvim_buf_get_changedtick(bufnr) ~= changedtick
        or vim.bo[bufnr].modified
      then
        vim.notify("pydeps: buffer changed while planning the update; retry update", vim.log.levels.WARN)
        return
      end
      local candidate = choice.value
      if candidate.kind == "declare" then
        apply_declaration(bufnr, dep, root, candidate)
      else
        resolve.lock(root, { args = { "--upgrade-package", candidate.upgrade } })
      end
    end,
  })
end

---Plan the update with PyPI releases and a uv dry run, then let the user pick
---one candidate from a menu that already shows what it changes.
---@param bufnr integer
---@param dep PyDepsDependency
---@return nil
local function update_dependency(bufnr, dep)
  if is_direct_reference(dep.spec) then
    vim.notify("pydeps: direct reference spec cannot be auto-updated: " .. dep.spec, vim.log.levels.WARN)
    return
  end
  -- uv plans from the file on disk, so unsaved edits would make the plan lie.
  if vim.bo[bufnr].modified then
    vim.notify("pydeps: save pyproject.toml before updating dependencies", vim.log.levels.WARN)
    return
  end
  local root = buffer_context.find_root(bufnr)
  if not root then
    vim.notify("pydeps: project root not found", vim.log.levels.WARN)
    return
  end
  local lock, missing = cache.get_lockfile(root, { sync = true })
  if missing then
    vim.notify("pydeps: uv.lock not found (run :PyDepsResolve first)", vim.log.levels.WARN)
    return
  end

  local name = util.normalize_package_name(dep.name)
  local locked = locked_versions(lock, name)
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local python = update_plan.python_floor(project_requires_python(bufnr))
  local meta, dry_run
  local pending = 2

  local function finish()
    pending = pending - 1
    if pending > 0 or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local plan = update_plan.build({
      name = name,
      spec = dep.spec,
      locked = locked,
      meta = meta,
      python = python,
      dry_run = dry_run,
    })
    show_plan(bufnr, dep, root, plan, locked, changedtick)
  end

  vim.notify("pydeps: planning update for " .. name, vim.log.levels.INFO)
  require("pydeps.providers.pypi").get(name, function(data)
    meta = data
    finish()
  end)
  require("pydeps.providers.uv").resolve({
    root = root,
    args = { "--dry-run", "--upgrade-package", name },
    on_finish = vim.schedule_wrap(function(result)
      dry_run = {
        ok = result.ok,
        changes = result.ok and update_plan.parse_dry_run(result.stderr) or {},
        error = not result.ok and dry_run_error(result) or nil,
      }
      finish()
    end),
  })
end

local run_for_buffer

---@param bufnr integer
---@param target? string
---@param deps PyDepsDependency[]
---@return PyDepsDependency?
local function find_dependency(bufnr, target, deps)
  if target and target ~= "" then
    local dep = find_dep_by_name(target, deps)
    if not dep then
      vim.notify("pydeps: dependency not found: " .. target, vim.log.levels.WARN)
    end
    return dep
  end

  local dep = buffer_context.dep_under_cursor(deps)
  if dep then
    return dep
  end

  -- The prompt is asynchronous, so resume on the buffer that asked for the
  -- update rather than on whichever buffer is current when the name arrives.
  vim.ui.input({ prompt = "pydeps: package name" }, function(input)
    if input and input ~= "" then
      local ok, err = pcall(run_for_buffer, bufnr, input)
      if not ok then
        vim.notify(
          string.format("pydeps: failed to update dependency: %s", err or "unknown error"),
          vim.log.levels.ERROR
        )
      end
    end
  end)

  return nil
end

---@param bufnr integer
---@param target? string
---@return nil
function run_for_buffer(bufnr, target)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("pydeps: buffer is no longer available; retry update", vim.log.levels.WARN)
    return
  end

  local deps = buffer_context.get_deps(bufnr)
  local dep = find_dependency(bufnr, target, deps)
  if not dep then
    return
  end

  update_dependency(bufnr, dep)
end

---@param target? string
---@return nil
function M.run(target)
  local bufnr = buffer_context.current_buf()
  if not buffer_context.is_pyproject_buf(bufnr) then
    vim.notify("pydeps: open pyproject.toml to update dependencies", vim.log.levels.WARN)
    return
  end

  run_for_buffer(bufnr, target)
end

return M
