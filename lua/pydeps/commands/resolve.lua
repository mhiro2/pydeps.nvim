local buffer_context = require("pydeps.core.buffer_context")
local cache = require("pydeps.core.cache")
local lock_diff = require("pydeps.ui.lock_diff")
local state = require("pydeps.core.state")

local M = {}

---@param root string
---@return nil
local function show_lock_diff(root)
  local snapshot = cache.get_lock_snapshot(root)
  if not snapshot then
    vim.notify("pydeps: no previous lockfile snapshot (run :PyDepsResolve first)", vim.log.levels.WARN)
    return
  end
  local current, missing = cache.get_lockfile(root, { sync = true })
  if missing then
    vim.notify("pydeps: uv.lock not found", vim.log.levels.WARN)
    return
  end
  lock_diff.show(snapshot, current.resolved or {}, { title = "PyDeps Lock Diff", root = root })
end

---@param result PyDepsUvResolveResult
---@return string, integer
local function resolve_message(result)
  if result.reason == "missing_uv" then
    return "pydeps: uv not found in PATH", vim.log.levels.ERROR
  end
  if result.reason == "spawn" then
    return "pydeps: failed to start uv lock", vim.log.levels.ERROR
  end
  if result.reason == "timeout" then
    return "pydeps: uv lock timed out after 5 minutes", vim.log.levels.ERROR
  end

  local message = "pydeps: uv lock failed (exit code " .. result.code .. ")"
  if result.stderr and result.stderr ~= "" then
    message = message .. "\n" .. result.stderr
  end
  return message, vim.log.levels.ERROR
end

---@param opts? { diff_only?: boolean, root?: string }
---@return nil
function M.run(opts)
  local bufnr = buffer_context.current_buf()
  local root = (opts and opts.root) or buffer_context.find_root(bufnr)
  if not root then
    vim.notify("pydeps: project root not found", vim.log.levels.WARN)
    return
  end

  if opts and opts.diff_only then
    show_lock_diff(root)
    state.refresh_all()
    return
  end

  local before = cache.get_lockfile(root, { sync = true })
  cache.set_lock_snapshot(root, before.resolved or {})

  local uv = require("pydeps.providers.uv")
  vim.notify("pydeps: running uv lock", vim.log.levels.INFO)
  uv.resolve({
    root = root,
    on_finish = function(result)
      if not result.ok then
        local message, level = resolve_message(result)
        vim.notify(message, level)
        return
      end

      vim.notify("pydeps: uv lock succeeded", vim.log.levels.INFO)
      cache.invalidate_lockfile(root)
      local after, missing = cache.get_lockfile(root, { sync = true })
      if missing then
        vim.notify("pydeps: uv.lock not found after resolve", vim.log.levels.WARN)
      else
        lock_diff.show(before.resolved or {}, after.resolved or {}, { title = "PyDeps Lock Diff", root = root })
        cache.set_lock_snapshot(root, after.resolved or {})
      end
      state.refresh_all()
    end,
  })
end

return M
