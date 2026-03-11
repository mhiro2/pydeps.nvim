local M = {}

---@param target table
---@param overrides? table
---@return nil
local function apply_overrides(target, overrides)
  for key, value in pairs(overrides or {}) do
    if key ~= "dep" then
      if value == vim.NIL then
        target[key] = nil
      elseif type(value) == "table" and type(target[key]) == "table" and not vim.islist(value) then
        apply_overrides(target[key], value)
      else
        target[key] = vim.deepcopy(value)
      end
    end
  end
end

---@param overrides? table
---@return PyDepsDependency
function M.dep(overrides)
  return vim.tbl_deep_extend("force", {
    name = "testpkg",
    line = 2,
    col_start = 3,
    col_end = 10,
    spec = ">=1.0",
    group = "project",
  }, overrides or {})
end

---@param overrides? table
---@return PyDepsDependencyView
function M.view(overrides)
  local dep = M.dep(overrides and overrides.dep or nil)
  local base = {
    dep = dep,
    name = dep.name,
    spec = dep.spec,
    group = dep.group,
    marker = nil,
    current_env = { python_version = "3.11" },
    resolved = "1.0.0",
    latest = "1.0.0",
    meta = {
      info = {
        version = "1.0.0",
        summary = "HTTP library",
      },
      releases = {},
    },
    pending = nil,
    missing_lockfile = false,
    missing_lockfile_text = "missing uv.lock",
    lockfile_loading = false,
    unresolved = false,
    active = true,
    yanked = false,
    class = "ok",
    pinned_version = nil,
    base_class = "ok",
    base_pinned_version = nil,
    status_kind = "ok",
    status_text = "active",
    status_icon = "",
    lock_status = "(up-to-date)",
    show_latest_warning = false,
  }

  apply_overrides(base, overrides)
  return base
end

---@param meta? PyDepsPyPIMeta
---@param is_yanked? boolean
---@return nil
function M.stub_pypi(meta, is_yanked)
  local result = meta
    or {
      info = {
        version = "1.0.0",
        summary = "HTTP library",
      },
      releases = {},
    }

  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb(result)
    end,
    is_yanked = function()
      return is_yanked == true
    end,
  }
end

---@return nil
function M.stub_pypi_not_found()
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb(nil)
    end,
    is_yanked = function()
      return false
    end,
  }
end

---@param opts? { dep?: PyDepsDependency, lock_data?: PyDepsLockfileData, missing_lockfile?: boolean }
---@return nil
function M.stub_cache(opts)
  opts = opts or {}
  local dep = opts.dep or M.dep()
  local lock_data = opts.lock_data or {
    resolved = {
      [dep.name] = "1.0.0",
    },
    packages = {},
  }

  package.loaded["pydeps.core.cache"] = {
    get_pyproject = function()
      return { dep }
    end,
    get_lockfile = function()
      return lock_data, opts.missing_lockfile == true
    end,
  }
end

---@return nil
function M.reset_info_modules()
  package.loaded["pydeps.ui.info"] = nil
  package.loaded["pydeps.ui.info.render_lines"] = nil
  package.loaded["pydeps.ui.info.highlight"] = nil
  package.loaded["pydeps.ui.info.hover_lifecycle"] = nil
end

---@return table
function M.require_info()
  M.reset_info_modules()
  return require("pydeps.ui.info")
end

---@return table
function M.require_render_lines()
  package.loaded["pydeps.ui.info.render_lines"] = nil
  return require("pydeps.ui.info.render_lines")
end

---@return table
function M.require_highlight()
  package.loaded["pydeps.ui.info.highlight"] = nil
  return require("pydeps.ui.info.highlight")
end

---@param lines string[]
---@return nil
function M.setup_project_buffer(lines)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = "toml"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

---@return integer?
function M.find_hover_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      return win
    end
  end
  return nil
end

---@return integer?
function M.find_hover_buf()
  local win = M.find_hover_win()
  if not win then
    return nil
  end
  return vim.api.nvim_win_get_buf(win)
end

---@return string[]
function M.hover_lines()
  local buf = M.find_hover_buf()
  if not buf then
    return {}
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param bufnr integer
---@param lhs string
---@param desc string
---@return boolean
function M.has_keymap(bufnr, lhs, desc)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if keymap.lhs == lhs and keymap.desc == desc then
      return true
    end
  end
  return false
end

---@param buf integer
---@param ns integer
---@param group string
---@return boolean
function M.has_highlight(buf, ns, group)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details and details.hl_group == group then
      return true
    end
  end
  return false
end

return M
