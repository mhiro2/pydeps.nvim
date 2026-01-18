---@class PyDepsConfig
---@field show_virtual_text boolean
---@field show_missing_virtual_text boolean
---@field show_missing_lockfile_virtual_text boolean
---@field missing_lockfile_virtual_text string
---@field virtual_text_hl string
---@field virtual_text_missing_hl string
---@field ui PyDepsUiConfig
---@field auto_refresh boolean
---@field refresh_debounce_ms integer
---@field info_window_border string
---@field select_menu_border string
---@field select_menu_relative string
---@field notify_on_missing_lockfile boolean
---@field enable_diagnostics boolean
---@field diagnostic_severity PyDepsDiagnosticSeverity
---@field pypi_url string
---@field pypi_cache_ttl integer
---@field enable_completion boolean
---@field completion PyDepsCompletionConfig
---@field tree PyDepsTreeConfig

---@class PyDepsDiagnosticSeverity
---@field yanked integer
---@field marker integer
---@field lock integer

---@class PyDepsCompletionConfig
---@field pypi_search boolean
---@field pypi_search_min integer
---@field max_results integer

---@class PyDepsTreeConfig
---@field depth integer

---@class PyDepsUiIconConfig
---@field enabled boolean
---@field update string
---@field ok string
---@field inactive string
---@field yanked string
---@field lock_mismatch string
---@field pin_not_found string
---@field unknown string
---@field package string
---@field searching string
---@field loading string
---@field spec string
---@field lock string
---@field latest string
---@field extras string
---@field markers string
---@field status string
---@field deps string
---@field pypi string
---@field fallback table<string, string>

---@class PyDepsUiShowConfig
---@field resolved boolean
---@field latest boolean

---@class PyDepsUiStatusTextConfig
---@field searching string
---@field loading string

---@class PyDepsUiConfig
---@field enabled boolean
---@field section_padding integer
---@field icons PyDepsUiIconConfig
---@field show PyDepsUiShowConfig
---@field highlights? PyDepsUiHighlightsConfig
---@field status_text? PyDepsUiStatusTextConfig

---@class PyDepsUiHighlightsConfig
---@field resolved? string
---@field missing? string

local M = {}

---@type PyDepsConfig
M.defaults = {
  show_virtual_text = true,
  show_missing_virtual_text = true,
  show_missing_lockfile_virtual_text = true,
  missing_lockfile_virtual_text = "missing uv.lock",
  virtual_text_hl = "PyDepsResolved",
  virtual_text_missing_hl = "PyDepsMissing",
  ui = {
    enabled = true,
    section_padding = 4,
    icons = {
      enabled = true,
      searching = "",
      loading = "",
      update = "",
      ok = "",
      inactive = "󰍶",
      yanked = "󰀪",
      lock_mismatch = "",
      pin_not_found = "",
      unknown = "󰋼",
      package = "",
      spec = "",
      lock = "",
      latest = "",
      extras = "",
      markers = "󰍶",
      status = "",
      deps = "",
      pypi = "󰌠",
      fallback = {
        searching = "?",
        loading = "~",
        update = "^",
        ok = "=",
        inactive = "-",
        yanked = "!",
        lock_mismatch = "!",
        pin_not_found = "x",
        unknown = "?",
      },
    },
    show = {
      resolved = true,
      latest = true,
    },
    highlights = {
      resolved = "DiagnosticOk",
      missing = "WarningMsg",
    },
    status_text = {
      searching = "Searching",
      loading = "Loading",
    },
  },
  auto_refresh = true,
  refresh_debounce_ms = 200,
  info_window_border = "rounded",
  select_menu_border = "rounded",
  select_menu_relative = "cursor",
  notify_on_missing_lockfile = true,
  enable_diagnostics = true,
  diagnostic_severity = {
    yanked = vim.diagnostic.severity.WARN,
    marker = vim.diagnostic.severity.WARN,
    lock = vim.diagnostic.severity.WARN,
  },
  pypi_url = "https://pypi.org/pypi",
  pypi_cache_ttl = 3600,
  enable_completion = true,
  completion = {
    pypi_search = true,
    pypi_search_min = 2,
    max_results = 30,
  },
  tree = {
    depth = 255,
  },
}

---@type PyDepsConfig
M.options = vim.deepcopy(M.defaults)

-- Validation functions (must be defined before M.setup)

---@param opts table
local function validate_top_level(opts)
  vim.validate({
    show_virtual_text = { opts.show_virtual_text, "boolean", true },
    show_missing_virtual_text = { opts.show_missing_virtual_text, "boolean", true },
    show_missing_lockfile_virtual_text = { opts.show_missing_lockfile_virtual_text, "boolean", true },
    missing_lockfile_virtual_text = { opts.missing_lockfile_virtual_text, "string", true },
    virtual_text_hl = { opts.virtual_text_hl, "string", true },
    virtual_text_missing_hl = { opts.virtual_text_missing_hl, "string", true },
    ui = { opts.ui, "table", true },
    auto_refresh = { opts.auto_refresh, "boolean", true },
    refresh_debounce_ms = { opts.refresh_debounce_ms, "number", true },
    info_window_border = { opts.info_window_border, "string", true },
    select_menu_border = { opts.select_menu_border, "string", true },
    select_menu_relative = { opts.select_menu_relative, "string", true },
    notify_on_missing_lockfile = { opts.notify_on_missing_lockfile, "boolean", true },
    enable_diagnostics = { opts.enable_diagnostics, "boolean", true },
    pypi_url = { opts.pypi_url, "string", true },
    pypi_cache_ttl = { opts.pypi_cache_ttl, "number", true },
    enable_completion = { opts.enable_completion, "boolean", true },
    diagnostic_severity = { opts.diagnostic_severity, "table", true },
    completion = { opts.completion, "table", true },
    tree = { opts.tree, "table", true },
  })
end

---@param severity table
local function validate_diagnostic_severity(severity)
  vim.validate({
    yanked = { severity.yanked, "number", true },
    marker = { severity.marker, "number", true },
    lock = { severity.lock, "number", true },
  })
end

---@param completion table
local function validate_completion(completion)
  vim.validate({
    pypi_search = { completion.pypi_search, "boolean", true },
    pypi_search_min = { completion.pypi_search_min, "number", true },
    max_results = { completion.max_results, "number", true },
  })
end

---@param tree table
local function validate_tree(tree)
  vim.validate({
    depth = { tree.depth, "number", true },
  })
end

---@param icons table
local function validate_ui_icons(icons)
  local icon_fields = {
    "update",
    "ok",
    "inactive",
    "yanked",
    "lock_mismatch",
    "pin_not_found",
    "unknown",
    "package",
    "searching",
    "loading",
    "spec",
    "lock",
    "latest",
    "extras",
    "markers",
    "status",
    "deps",
    "pypi",
    "fallback",
  }
  local schema = {
    enabled = { icons.enabled, "boolean", true },
  }
  for _, field in ipairs(icon_fields) do
    local field_type = field == "fallback" and "table" or "string"
    schema[field] = { icons[field], field_type, true }
  end
  vim.validate(schema)
end

---@param show table
local function validate_ui_show(show)
  vim.validate({
    resolved = { show.resolved, "boolean", true },
    latest = { show.latest, "boolean", true },
  })
end

---@param status_text table
local function validate_ui_status_text(status_text)
  vim.validate({
    searching = { status_text.searching, "string", true },
    loading = { status_text.loading, "string", true },
  })
end

---@param ui table
local function validate_ui(ui)
  vim.validate({
    enabled = { ui.enabled, "boolean", true },
    section_padding = { ui.section_padding, "number", true },
    icons = { ui.icons, "table", true },
    show = { ui.show, "table", true },
    highlights = { ui.highlights, "table", true },
  })

  if ui.icons then
    validate_ui_icons(ui.icons)
  end
  if ui.show then
    validate_ui_show(ui.show)
  end
  if ui.status_text then
    validate_ui_status_text(ui.status_text)
  end
end

---@param opts? PyDepsConfig
function M.setup(opts)
  opts = opts or {}

  -- Validate top-level options
  validate_top_level(opts)

  -- Validate nested options
  if opts.diagnostic_severity then
    validate_diagnostic_severity(opts.diagnostic_severity)
  end
  if opts.completion then
    validate_completion(opts.completion)
  end
  if opts.tree then
    validate_tree(opts.tree)
  end
  if opts.ui then
    validate_ui(opts.ui)
  end

  M.options = vim.tbl_deep_extend("force", M.defaults, opts)
end

return M
