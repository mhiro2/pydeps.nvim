local render_lines = require("pydeps.ui.info.render_lines")
local ui_shared = require("pydeps.ui.shared")

local M = {}

local info_ns = vim.api.nvim_create_namespace("pydeps-info")

local info_labels = {
  "spec",
  "lock",
  "latest",
  "extras",
  "markers",
  "status",
  "deps",
  "pypi",
}

---@param kind string
---@return string
local function status_highlight_group(kind)
  if kind == "ok" then
    return "PyDepsInfoStatusOk"
  elseif kind == "update" then
    return "PyDepsInfoStatusUpdate"
  elseif kind == "warn" then
    return "PyDepsInfoStatusWarn"
  elseif kind == "error" then
    return "PyDepsInfoStatusError"
  elseif kind == "inactive" then
    return "PyDepsInfoStatusInactive"
  end

  return "PyDepsInfoStatusInactive"
end

---@param line string
---@return string?
local function find_label(line)
  for _, label in ipairs(info_labels) do
    if line:match("^%s*%S+%s+" .. label .. "%s") or line:match("^%s*" .. label .. "%s") then
      return label
    end
  end

  return nil
end

---@param suffix string
---@return string
local function suffix_highlight_group(suffix)
  if suffix == "up-to-date" then
    return "PyDepsInfoSuffixOk"
  elseif suffix == "update available" then
    return "PyDepsInfoSuffixWarn"
  elseif suffix == "loading..." then
    return "PyDepsInfoSuffixInfo"
  elseif suffix == "not found" or suffix == "missing" then
    return "PyDepsInfoSuffixError"
  end

  return "PyDepsInfoSuffixInfo"
end

---@return integer
function M.namespace()
  return info_ns
end

---@param buf integer
---@param dep PyDepsDependency
---@param lines string[]
---@param status PyDepsStatusResult
---@return nil
function M.apply(buf, dep, lines, status)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(buf, info_ns, 0, -1)

  if lines[1] and dep and dep.name then
    local package_icon = ui_shared.icon_for("package")
    local icon_offset = #package_icon + (#package_icon > 0 and 1 or 0)
    vim.api.nvim_buf_add_highlight(buf, info_ns, "PyDepsInfoPackage", 0, 0, icon_offset + #dep.name)
  end

  local description_marked = false
  for idx, line in ipairs(lines) do
    if not description_marked and idx > 1 and line ~= "" and not find_label(line) then
      vim.api.nvim_buf_add_highlight(buf, info_ns, "PyDepsInfoDescription", idx - 1, 0, -1)
      description_marked = true
    end

    local label = find_label(line)
    if label then
      local start_col = line:find(label, 1, true)
      if start_col then
        vim.api.nvim_buf_add_highlight(buf, info_ns, "PyDepsInfoLabel", idx - 1, 0, start_col - 1 + #label)
      end

      if label == "extras" then
        local value_start = line:find("%S", (start_col or 1) + #label)
        if value_start then
          vim.api.nvim_buf_add_highlight(buf, info_ns, "PyDepsInfoPill", idx - 1, value_start - 1, -1)
        end
      elseif label == "status" then
        local status_text = render_lines.format_status_text(status)
        local value_start = line:find(status_text, 1, true)
        if value_start then
          vim.api.nvim_buf_add_highlight(
            buf,
            info_ns,
            status_highlight_group(status.kind),
            idx - 1,
            value_start - 1,
            value_start - 1 + #status_text
          )
        end
      elseif label == "pypi" and line:match("https?://") then
        local url_start = line:find("https?://")
        if url_start then
          vim.api.nvim_buf_add_highlight(buf, info_ns, "PyDepsInfoUrl", idx - 1, url_start - 1, -1)
        end
      end
    end

    local suffix = line:match("%((.+)%)%s*$")
    if suffix then
      local suffix_start = line:find("%(" .. vim.pesc(suffix) .. "%)%s*$")
      if suffix_start then
        vim.api.nvim_buf_add_highlight(buf, info_ns, suffix_highlight_group(suffix), idx - 1, suffix_start - 1, -1)
      end
    end
  end
end

return M
