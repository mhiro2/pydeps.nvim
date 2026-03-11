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
---@field audit_window_border string
---@field notify_on_missing_lockfile boolean
---@field enable_diagnostics boolean
---@field diagnostic_severity PyDepsDiagnosticSeverity
---@field pypi_url string
---@field pypi_cache_ttl integer
---@field osv_url string
---@field osv_cache_ttl integer
---@field enable_completion boolean
---@field completion PyDepsCompletionConfig

---@class PyDepsDiagnosticSeverity
---@field yanked integer
---@field marker integer
---@field lock integer

---@class PyDepsCompletionConfig
---@field pypi_search boolean
---@field pypi_search_min integer
---@field max_results integer

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
  audit_window_border = "rounded",
  notify_on_missing_lockfile = true,
  enable_diagnostics = true,
  diagnostic_severity = {
    yanked = vim.diagnostic.severity.WARN,
    marker = vim.diagnostic.severity.WARN,
    lock = vim.diagnostic.severity.WARN,
  },
  pypi_url = "https://pypi.org/pypi",
  pypi_cache_ttl = 3600,
  osv_url = "https://api.osv.dev/v1/querybatch",
  osv_cache_ttl = 3600,
  enable_completion = true,
  completion = {
    pypi_search = true,
    pypi_search_min = 2,
    max_results = 30,
  },
}

---@type PyDepsConfig
M.options = vim.deepcopy(M.defaults)

-- Validation functions (must be defined before M.setup)

---@type boolean
local has_new_validate = pcall(vim.validate, "__pydeps_validate_probe__", true, "boolean")

---@param name string
---@param value any
---@param validator any
---@param optional? boolean
local function validate_field(name, value, validator, optional)
  if has_new_validate then
    vim.validate(name, value, validator, optional)
    return
  end
  vim.validate({
    [name] = { value, validator, optional },
  })
end

---@param name string
---@param value number|nil
---@param min number
---@return nil
local function validate_min(name, value, min)
  if value ~= nil and value < min then
    error(string.format("pydeps: %s must be >= %s", name, min))
  end
end

---@class PyDepsValidationSpec
---@field name string
---@field validator any
---@field min? number
---@field fields? PyDepsValidationSpec[]

---@param name string
---@param validator any
---@param opts? table
---@return PyDepsValidationSpec
local function spec(name, validator, opts)
  local field = {
    name = name,
    validator = validator,
  }
  for key, value in pairs(opts or {}) do
    field[key] = value
  end
  return field
end

---@param target PyDepsValidationSpec[]
---@param names string[]
---@param validator any
local function add_specs(target, names, validator)
  for _, name in ipairs(names) do
    target[#target + 1] = spec(name, validator)
  end
end

local diagnostic_severity_specs = {}
add_specs(diagnostic_severity_specs, { "yanked", "marker", "lock" }, "number")

local completion_specs = {
  spec("pypi_search", "boolean"),
  spec("pypi_search_min", "number"),
  spec("max_results", "number", { min = 1 }),
}

local ui_icon_specs = {
  spec("enabled", "boolean"),
  spec("fallback", "table"),
}
add_specs(ui_icon_specs, {
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
}, "string")

local ui_show_specs = {}
add_specs(ui_show_specs, { "resolved", "latest" }, "boolean")

local ui_status_text_specs = {}
add_specs(ui_status_text_specs, { "searching", "loading" }, "string")

local ui_specs = {
  spec("enabled", "boolean"),
  spec("section_padding", "number"),
  spec("icons", "table", { fields = ui_icon_specs }),
  spec("show", "table", { fields = ui_show_specs }),
  spec("highlights", "table"),
  spec("status_text", "table", { fields = ui_status_text_specs }),
}

local top_level_specs = {
  spec("show_virtual_text", "boolean"),
  spec("show_missing_virtual_text", "boolean"),
  spec("show_missing_lockfile_virtual_text", "boolean"),
  spec("missing_lockfile_virtual_text", "string"),
  spec("virtual_text_hl", "string"),
  spec("virtual_text_missing_hl", "string"),
  spec("ui", "table", { fields = ui_specs }),
  spec("auto_refresh", "boolean"),
  spec("refresh_debounce_ms", "number", { min = 0 }),
  spec("info_window_border", "string"),
  spec("select_menu_border", "string"),
  spec("select_menu_relative", "string"),
  spec("audit_window_border", "string"),
  spec("notify_on_missing_lockfile", "boolean"),
  spec("enable_diagnostics", "boolean"),
  spec("pypi_url", "string"),
  spec("pypi_cache_ttl", "number", { min = 1 }),
  spec("osv_url", "string"),
  spec("osv_cache_ttl", "number", { min = 1 }),
  spec("enable_completion", "boolean"),
  spec("diagnostic_severity", "table", { fields = diagnostic_severity_specs }),
  spec("completion", "table", { fields = completion_specs }),
}

---@param value table
---@param specs PyDepsValidationSpec[]
local function validate_specs(value, specs)
  for _, current in ipairs(specs) do
    local field_value = value[current.name]
    validate_field(current.name, field_value, current.validator, true)
    if current.min ~= nil then
      validate_min(current.name, field_value, current.min)
    end
    if current.fields and field_value ~= nil then
      validate_specs(field_value, current.fields)
    end
  end
end

---@param opts? PyDepsConfig
function M.setup(opts)
  opts = opts or {}

  validate_specs(opts, top_level_specs)

  M.options = vim.tbl_deep_extend("force", M.defaults, opts)
end

return M
