local config = require("pydeps.config")
local env = require("pydeps.core.env")
local markers = require("pydeps.core.markers")
local project = require("pydeps.core.project")

local ok_pypi, pypi = pcall(require, "pydeps.providers.pypi")
local ok_ts, ts_toml = pcall(require, "pydeps.treesitter.toml")
if not ok_ts then
  ts_toml = nil
end

local M = {}

M.ns = vim.api.nvim_create_namespace("pydeps.virtual_text")

-- Rate limiting for PyPI requests (max concurrent requests)
local MAX_CONCURRENT_REQUESTS = 5
---@type table<string, "searching" | "loading" | nil>
local pending = {}
local rate_limit = require("pydeps.core.rate_limit")
local limiter = rate_limit.new(MAX_CONCURRENT_REQUESTS)

-- Debounce state to prevent recursive rendering (per-buffer)
---@type table<integer, {timer: uv_timer_t, pending: boolean}>
local debounce_state = {}

---@param bufnr integer
---@return uv_timer_t?, boolean?
local function get_debounce_state(bufnr)
  local state = debounce_state[bufnr]
  if state then
    return state.timer, state.pending
  end
  return nil, false
end

---@param bufnr integer
---@param timer uv_timer_t
---@param is_pending boolean
local function set_debounce_state(bufnr, timer, is_pending)
  debounce_state[bufnr] = { timer = timer, pending = is_pending }
end

---@param bufnr integer
local function clear_debounce_state(bufnr)
  local state = debounce_state[bufnr]
  if state then
    if state.timer then
      state.timer:stop()
      state.timer:close()
    end
    debounce_state[bufnr] = nil
  end
end

---@private
---@param bufnr integer
---@param deps table[]
---@param resolved table
---@param opts? table
local function schedule_render(bufnr, deps, resolved, opts)
  local _, is_pending = get_debounce_state(bufnr)
  if is_pending then
    return
  end

  -- Clear any existing timer for this buffer
  clear_debounce_state(bufnr)

  local timer = vim.uv.new_timer()
  set_debounce_state(bufnr, timer, true)

  timer:start(50, 0, function()
    timer:stop()
    timer:close()
    set_debounce_state(bufnr, nil, false)

    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        M.render(bufnr, deps, resolved, opts)
      end
    end)
  end)
end

---@return nil
function M.setup_highlights()
  -- Virtual text badge highlights
  vim.api.nvim_set_hl(0, "PyDepsOk", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "PyDepsUpdate", { link = "DiagnosticHint", default = true })
  vim.api.nvim_set_hl(0, "PyDepsMajor", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "PyDepsYanked", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInactive", { link = "@comment", default = true })
  vim.api.nvim_set_hl(0, "PyDepsLockMismatch", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "PyDepsPinNotFound", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "PyDepsUnknown", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "PyDepsResolved", { link = "@comment", default = true })
  vim.api.nvim_set_hl(0, "PyDepsMissing", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "PyDepsLabel", { link = "@comment", default = true })
  vim.api.nvim_set_hl(0, "PyDepsSearching", { link = "DiagnosticInfo", default = true })
  vim.api.nvim_set_hl(0, "PyDepsLoading", { link = "DiagnosticHint", default = true })
end

---@param bufnr integer
function M.clear(bufnr)
  clear_debounce_state(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

---@return PyDepsUiShowConfig
local function ui_show()
  local show = (config.options.ui and config.options.ui.show) or {}
  return {
    resolved = show.resolved ~= false,
    latest = show.latest ~= false,
  }
end

---@return integer
local function section_padding()
  local ui = config.options.ui or {}
  return ui.section_padding or 4
end

---@return PyDepsUiIconConfig
local function ui_icons()
  local ui = config.options.ui or {}
  return ui.icons or {}
end

---@param kind string
---@return string
local function icon_for(kind)
  local icons = ui_icons()
  if icons.enabled == false then
    return (icons.fallback and icons.fallback[kind]) or ""
  end
  return icons[kind] or (icons.fallback and icons.fallback[kind]) or ""
end

---@param spec? string
---@return string?
local function extract_marker(spec)
  if not spec then
    return nil
  end
  return spec:match(";%s*(.+)$")
end

---@param text string
---@param byte_index integer
---@return integer
local function display_width_to(text, byte_index)
  local substring = text:sub(1, byte_index)
  return vim.fn.strdisplaywidth(substring)
end

---@param spec? string
---@return boolean, string?
local function is_pinned_spec(spec)
  if not spec then
    return false, nil
  end
  local version = spec:match("%s*===*%s*([%d%.]+)")
  if version then
    return true, version
  end
  return false, nil
end

---@param base? PyDepsEnv
---@param dep PyDepsDependency
---@return PyDepsEnv
local function with_extra_env(base, dep)
  local env_copy = vim.tbl_extend("force", {}, base or {})
  if dep.group then
    if dep.group:match("^optional:") then
      env_copy.extra = dep.group:sub(#"optional:" + 1)
    elseif dep.group:match("^group:") then
      local group_name = dep.group:sub(#"group:" + 1)
      env_copy.group = group_name
      env_copy.dependency_group = group_name
    end
  end
  return env_copy
end

---@param meta? PyDepsPyPIMeta
---@return string?
local function latest_from_meta(meta)
  if not meta then
    return nil
  end
  if meta.info and meta.info.version then
    return meta.info.version
  end
  if ok_pypi and pypi.sorted_versions then
    local versions = pypi.sorted_versions(meta)
    return versions[1]
  end
  return nil
end

---@param meta? PyDepsPyPIMeta
---@param version string
---@return boolean
local function is_version_in_releases(meta, version)
  if not meta or not meta.releases then
    return true
  end
  return meta.releases[version] ~= nil
end

---@param resolved? string
---@param latest? string
---@return boolean
local function is_major_bump(resolved, latest)
  local function major(v)
    if not v then
      return nil
    end
    local m = tostring(v):match("^(%d+)")
    return m and tonumber(m) or nil
  end
  local r = major(resolved)
  local l = major(latest)
  return (r and l and l > r) or false
end

---@param class string
---@return string
local function hl_for(class)
  local highlight_map = {
    ok = "PyDepsOk",
    update = "PyDepsUpdate",
    major = "PyDepsMajor",
    inactive = "PyDepsInactive",
    yanked = "PyDepsYanked",
    lock_mismatch = "PyDepsLockMismatch",
    pin_not_found = "PyDepsPinNotFound",
    searching = "PyDepsSearching",
    loading = "PyDepsLoading",
  }
  return highlight_map[class] or "PyDepsUnknown"
end

---@param class string
---@return string
local function kind_for(class)
  local kind_map = {
    ok = "ok",
    update = "update",
    major = "update",
    inactive = "inactive",
    yanked = "yanked",
    lock_mismatch = "lock_mismatch",
    pin_not_found = "pin_not_found",
    searching = "searching",
    loading = "loading",
  }
  return kind_map[class] or "unknown"
end

---@param dep table
---@return string?
local function classify(dep)
  -- Check inactive (marker evaluation failed)
  if dep.active == false then
    return "inactive"
  end

  -- Check yanked version
  if dep.yanked then
    return "yanked"
  end

  -- Check pin not found in PyPI releases
  local is_pinned, pinned_version = is_pinned_spec(dep.spec)
  if is_pinned and pinned_version and dep.meta and not is_version_in_releases(dep.meta, pinned_version) then
    return "pin_not_found"
  end

  -- Check lock mismatch (pinned version differs from resolved)
  if pinned_version and pinned_version ~= dep.resolved then
    dep.lock_mismatch_version = pinned_version
    return "lock_mismatch"
  end

  -- Check missing lockfile or unresolved
  if dep.missing_lockfile or dep.unresolved then
    return "unknown"
  end

  -- Check pending states
  if dep.pending == "searching" then
    return "searching"
  end
  if dep.pending == "loading" then
    return "loading"
  end

  -- Check version updates
  if dep.latest and dep.resolved and dep.latest ~= dep.resolved then
    return is_major_bump(dep.resolved, dep.latest) and "major" or "update"
  end

  -- All good
  if dep.resolved then
    return "ok"
  end

  return nil
end

---@param class string
---@return string
local function get_status_text(class)
  local ui = config.options.ui or {}
  local status_text = ui.status_text or {}
  return status_text[class] or (class == "searching" and "Searching" or "Loading")
end

---@param dep table
---@return table[]?, string?
local function build_badge(dep)
  local class = classify(dep)
  if not class then
    return nil, nil
  end

  local hl = hl_for(class)
  local chunks = {}
  local show = ui_show()

  -- Add icon if enabled
  local icon = icon_for(kind_for(class))
  if icon ~= "" then
    table.insert(chunks, { icon .. " ", hl })
  end

  -- Build badge content based on class
  if class == "inactive" then
    table.insert(chunks, { "inactive", hl })
    return chunks, class
  end

  if class == "yanked" then
    table.insert(chunks, { "yanked", hl })
    if show.resolved and dep.resolved then
      table.insert(chunks, { " " .. dep.resolved, hl })
    end
    return chunks, class
  end

  if class == "pin_not_found" then
    table.insert(chunks, { "not on public PyPI", hl })
    if show.resolved and dep.resolved then
      table.insert(chunks, { " " .. dep.resolved, "PyDepsLabel" })
    end
    return chunks, class
  end

  if class == "unknown" then
    local label = dep.missing_lockfile_text or (dep.unresolved and "unresolved") or "unknown"
    table.insert(chunks, { label, hl })
    return chunks, class
  end

  if class == "searching" or class == "loading" then
    local label = get_status_text(class)
    table.insert(chunks, { label, hl })
    return chunks, class
  end

  -- For ok, update, major, lock_mismatch: show resolved and optionally latest
  if show.resolved then
    table.insert(chunks, { dep.resolved or "?", hl })
  end

  -- Show update arrow and latest version
  if class ~= "ok" and dep.latest and dep.resolved and dep.latest ~= dep.resolved then
    if show.latest then
      local arrow = " → "
      local prefix = show.resolved and arrow or ""
      table.insert(chunks, { prefix .. dep.latest, hl })
    end
  end

  -- Show lock mismatch version
  if class == "lock_mismatch" and dep.lock_mismatch_version then
    table.insert(chunks, { "  (pinned: " .. dep.lock_mismatch_version .. ")", hl })
  end

  return chunks, class
end

---@param chunks table[]
---@return integer
local function badge_width(chunks)
  local text = ""
  for _, chunk in ipairs(chunks or {}) do
    text = text .. (chunk[1] or "")
  end
  return vim.fn.strdisplaywidth(text)
end

---Calculate anchor columns per section (display-based)
---@param deps table[]
---@param ranges? table<string, {start_line: integer, end_line: integer}>
---@return table<string, integer>
local function calculate_section_anchors(deps, ranges)
  local anchors = {}
  for _, dep in ipairs(deps or {}) do
    local group = dep.group or ""
    local col_end = dep.col_end_display or dep.col_end or 0
    local line = dep.line or (dep.lnum and dep.lnum + 1)
    local range = ranges and ranges[group] or nil
    local in_range = true
    if range and line then
      in_range = line >= range.start_line and line <= range.end_line
    end
    if in_range then
      if not anchors[group] or col_end > anchors[group] then
        anchors[group] = col_end
      end
    end
  end
  return anchors
end

---@param bufnr integer
---@return integer
local function pick_winid(bufnr)
  local wins = vim.fn.win_findbuf(bufnr)
  if type(wins) == "table" and #wins > 0 then
    return wins[1]
  end
  return vim.api.nvim_get_current_win()
end

---@param bufnr integer
---@return integer
local function win_width(bufnr)
  local winid = pick_winid(bufnr)
  return vim.api.nvim_win_get_width(winid)
end

---Calculate badge position with comment collision avoidance (display-based)
---@param dep table
---@param anchor_col integer Display-based anchor column (max col_end in section)
---@param width integer Badge display width
---@param padding integer Section padding
---@param bufnr integer
---@return integer Display column position for badge
local function calculate_badge_position(dep, anchor_col, width, padding, bufnr)
  local min_start = math.max(dep.col_end_display or dep.col_end or 1, 0)
  local start = math.max(anchor_col + padding - 1, min_start)

  -- If comment exists, place badge after the comment
  if dep.comment_end_display then
    local comment_padding = 1
    local after_comment = dep.comment_end_display + comment_padding
    if start < after_comment then
      start = after_comment
    end
  end

  -- Clamp badge position to window width (prefer visibility over perfect alignment)
  local ww = win_width(bufnr)
  if ww and ww > 0 then
    local max_start = math.max(0, ww - width)
    if start > max_start then
      start = max_start
    end
  end

  return math.max(start, min_start)
end

---@param deps table[]
---@param bufnr integer
---@param ranges? table<string, {start_line: integer, end_line: integer}>
---@return table<integer, integer?>
local function calculate_positions(deps, bufnr, ranges)
  local anchors = calculate_section_anchors(deps, ranges)
  local padding = section_padding()
  local positions = {}
  for idx, dep in ipairs(deps or {}) do
    local chunks = build_badge(dep)
    if chunks and #chunks > 0 then
      local width = badge_width(chunks)
      positions[idx] = calculate_badge_position(dep, anchors[dep.group or ""] or 0, width, padding, bufnr)
    end
  end
  return positions
end

---@param bufnr integer
---@param dep table
---@param col integer
local function set_mark(bufnr, dep, col)
  local chunks = build_badge(dep)
  if not chunks or #chunks == 0 then
    return
  end
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, dep.lnum, dep.col or 0, {
    virt_text = chunks,
    virt_text_pos = "overlay",
    virt_text_win_col = col,
    hl_mode = "combine",
    priority = 200,
  })
end

---@param bufnr integer
---@param line integer?
---@param line_cache table<integer, string?>
---@return string?
local function get_buffer_line(bufnr, line, line_cache)
  if not line or line < 1 then
    return nil
  end
  if line_cache[line] == nil then
    line_cache[line] = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
  end
  return line_cache[line]
end

---@param dep PyDepsDependency
---@param resolved PyDepsResolved
---@return string?
local function get_resolved_version(dep, resolved)
  return resolved and resolved[dep.name] or nil
end

---@param _dep PyDepsDependency
---@param resolved_version string?
---@param lockfile_missing boolean
---@param show_missing_lockfile boolean
---@param show_missing boolean
---@param meta PyDepsPyPIMeta?
---@return table
local function build_view_metadata(
  _dep,
  resolved_version,
  lockfile_missing,
  lockfile_loading,
  show_missing_lockfile,
  show_missing,
  meta
)
  local view = {
    missing_lockfile = false,
    unresolved = false,
    meta = nil,
    latest = nil,
    yanked = false,
  }

  if not resolved_version and not lockfile_loading then
    if lockfile_missing and show_missing_lockfile then
      view.missing_lockfile = true
      view.missing_lockfile_text = config.options.missing_lockfile_virtual_text or "missing uv.lock"
    elseif not lockfile_missing and show_missing then
      -- Only show unresolved if package exists on PyPI (meta is available)
      -- This avoids noise for private packages, git/path dependencies, etc.
      if meta then
        view.unresolved = true
      end
    end
  end

  if meta then
    view.meta = meta
    view.latest = latest_from_meta(meta)
    if resolved_version then
      view.yanked = pypi.is_yanked(meta, resolved_version)
    end
  end

  return view
end

---@param bufnr integer
---@param dep PyDepsDependency
---@param resolved PyDepsResolved
---@param current_env PyDepsEnv
---@param line_cache table<integer, string?>
---@param lockfile_missing boolean
---@return table
local function create_dependency_view(bufnr, dep, resolved, current_env, line_cache, lockfile_missing, lockfile_loading)
  -- Evaluate marker if present
  local marker = extract_marker(dep.spec)
  local marker_active = true
  if marker then
    local result = markers.evaluate(marker, with_extra_env(current_env, dep))
    marker_active = result ~= false
  end

  -- Get resolved version
  local resolved_version = get_resolved_version(dep, resolved)

  -- Calculate display positions
  local line = dep.line
  local line_text = line and get_buffer_line(bufnr, line, line_cache) or nil
  local col_end_display = line_text and dep.col_end and display_width_to(line_text, dep.col_end) or nil
  local comment_end_display = line_text and dep.comment_col and vim.fn.strdisplaywidth(line_text) or nil

  -- Build base view
  local view = {
    name = dep.name,
    spec = dep.spec,
    lnum = dep.line - 1,
    col = math.max((dep.col_start or 1) - 1, 0),
    line = dep.line,
    marker = marker,
    active = marker_active,
    resolved = resolved_version,
    col_end = dep.col_end,
    col_end_display = col_end_display,
    comment_col = dep.comment_col,
    comment_end_display = comment_end_display,
    group = dep.group,
    pending = pending[dep.name],
  }

  -- Add PyPI metadata
  local meta = nil
  if ok_pypi then
    meta = pypi.get_cached(dep.name)
  end

  local show_missing = config.options.show_missing_virtual_text
  local show_missing_lockfile = config.options.show_missing_lockfile_virtual_text
  local metadata = build_view_metadata(
    dep,
    resolved_version,
    lockfile_missing,
    lockfile_loading,
    show_missing_lockfile,
    show_missing,
    meta
  )

  for k, v in pairs(metadata) do
    view[k] = v
  end

  return view
end

-- Helper functions for M.render (must be defined before M.render)

---Check if virtual text should be rendered based on configuration
---@private
---@return boolean
local function should_render_virtual_text()
  if config.options.show_virtual_text == false then
    return false
  end
  if config.options.ui and config.options.ui.enabled == false then
    return false
  end
  return true
end

---@private
---@param bufnr integer
---@param package_name string
---@param deps PyDepsDependency[]
---@param resolved PyDepsResolved
---@param opts? PyDepsRenderOptions
---@return nil
local function queue_pypi_request(bufnr, package_name, deps, resolved, opts)
  pending[package_name] = "searching"
  limiter:enqueue(function(done)
    pending[package_name] = "loading"
    pypi.get(package_name, function()
      pending[package_name] = nil
      done()
      if vim.api.nvim_buf_is_valid(bufnr) then
        schedule_render(bufnr, deps, resolved, opts)
      end
    end)
  end)
end

---@private
---@param bufnr integer
---@return table?
local function get_treesitter_ranges(bufnr)
  if ts_toml and ts_toml.is_available() then
    return ts_toml.get_dependency_array_ranges(bufnr)
  end
  return nil
end

---@param bufnr integer
---@param deps PyDepsDependency[]
---@param resolved PyDepsResolved
---@param current_env PyDepsEnv
---@param lockfile_missing boolean
---@return table[]
local function build_dependency_views(bufnr, deps, resolved, current_env, lockfile_missing, lockfile_loading)
  local views = {}
  local line_cache = {}

  for _, dep in ipairs(deps or {}) do
    -- Queue PyPI request if needed
    if ok_pypi and not pypi.get_cached(dep.name) and not pending[dep.name] then
      queue_pypi_request(bufnr, dep.name, deps, resolved, { lockfile_missing = lockfile_missing })
    end

    local view =
      create_dependency_view(bufnr, dep, resolved, current_env, line_cache, lockfile_missing, lockfile_loading)
    table.insert(views, view)
  end

  return views
end

---@param bufnr integer
---@param views table[]
---@param positions table<integer, integer?>
---@return nil
local function render_badges(bufnr, views, positions)
  for i, view in ipairs(views) do
    local col = positions[i]
    if col then
      set_mark(bufnr, view, col)
    end
  end
end

---@param bufnr integer
---@param deps PyDepsDependency[]
---@param resolved PyDepsResolved
---@param opts? PyDepsRenderOptions
function M.render(bufnr, deps, resolved, opts)
  if not should_render_virtual_text() or not vim.api.nvim_buf_is_valid(bufnr) then
    M.clear(bufnr)
    return
  end

  M.clear(bufnr)

  local root = project.find_root(bufnr)
  local current_env = env.get(root)
  local lockfile_missing = opts and opts.lockfile_missing or false
  local lockfile_loading = opts and opts.lockfile_loading or false

  -- Build all dependency views
  local views = build_dependency_views(bufnr, deps, resolved, current_env, lockfile_missing, lockfile_loading)

  -- Calculate badge positions
  local ranges = get_treesitter_ranges(bufnr)
  local positions = calculate_positions(views, bufnr, ranges)

  -- Render badges
  render_badges(bufnr, views, positions)
end

---Clean up debounce state for a buffer (used by autocmd cleanup)
---@param bufnr integer
function M.clear_debounce_state(bufnr)
  clear_debounce_state(bufnr)
end

return M
