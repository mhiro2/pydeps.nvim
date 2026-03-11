local buffer_context = require("pydeps.core.buffer_context")
local cache = require("pydeps.core.cache")
local info = require("pydeps.ui.info")

local M = {}

---@return nil
function M.run()
  local bufnr = buffer_context.current_buf()
  if not buffer_context.is_pyproject_buf(bufnr) then
    vim.notify("pydeps: open pyproject.toml to inspect dependencies", vim.log.levels.WARN)
    return
  end

  local deps = buffer_context.get_deps(bufnr)
  local target = buffer_context.dep_under_cursor(deps)
  local root = buffer_context.find_root(bufnr)
  local resolved = {}
  local missing_lockfile = false

  if root then
    local lock_data, missing, loading = cache.get_lockfile(root)
    resolved = lock_data.resolved or {}
    missing_lockfile = missing
    if loading then
      missing_lockfile = false
    end
  end

  info.show(target, target and resolved[target.name] or nil, { lockfile_missing = missing_lockfile })
end

return M
