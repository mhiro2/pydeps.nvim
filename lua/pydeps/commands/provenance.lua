local buffer_context = require("pydeps.core.buffer_context")
local cache = require("pydeps.core.cache")
local provenance_ui = require("pydeps.ui.provenance")

local M = {}

---@param target? string
---@return nil
function M.run(target)
  local bufnr = buffer_context.current_buf()
  if not buffer_context.is_pyproject_buf(bufnr) and not target then
    vim.notify("pydeps: open pyproject.toml or pass a package name", vim.log.levels.WARN)
    return
  end

  local root = buffer_context.find_root(bufnr)
  if not root then
    vim.notify("pydeps: project root not found", vim.log.levels.WARN)
    return
  end

  local deps = buffer_context.get_project_deps(bufnr)
  local dep = target and { name = target } or buffer_context.dep_under_cursor(deps)
  if not dep then
    vim.ui.input({ prompt = "pydeps: package name" }, function(input)
      if input and input ~= "" then
        local ok, err = pcall(M.run, input)
        if not ok then
          vim.notify(
            string.format("pydeps: failed to show provenance: %s", err or "unknown error"),
            vim.log.levels.ERROR
          )
        end
      end
    end)
    return
  end

  local lock_data, missing = cache.get_lockfile(root, { sync = true })
  if missing then
    vim.notify("pydeps: uv.lock not found", vim.log.levels.WARN)
    return
  end

  local ok, err = provenance_ui.show(dep.name, deps, lock_data.graph or {})
  if not ok then
    vim.notify(string.format("pydeps: failed to show provenance: %s", err or "unknown error"), vim.log.levels.ERROR)
  end
end

return M
