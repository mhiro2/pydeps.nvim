local M = {}

---@param opts? PyDepsConfig
function M.setup(opts)
  require("pydeps.config").setup(opts)
  M.setup_highlights()
  require("pydeps.core.state").setup()
  if require("pydeps.config").options.enable_completion then
    local ok, cmp = pcall(require, "cmp")
    if ok then
      cmp.register_source("pydeps", require("pydeps.completion.cmp").new())
    end
    local ok_blink, blink = pcall(require, "blink.cmp")
    if ok_blink and blink and blink.register_source then
      blink.register_source("pydeps", require("pydeps.completion.blink").new())
    end
  end

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("PyDepsHighlights", { clear = true }),
    callback = function()
      M.setup_highlights()
    end,
  })
end

---Setup all highlight groups
---@private
function M.setup_highlights()
  require("pydeps.ui.virtual_text").setup_highlights()
  M.setup_tree_badge_highlights()
  M.setup_info_highlights()
end

---Setup highlight groups for tree badges
---@private
function M.setup_tree_badge_highlights()
  vim.api.nvim_set_hl(0, "PyDepsBadgeDirect", { link = "@keyword", default = true })
  vim.api.nvim_set_hl(0, "PyDepsBadgeTransitive", { link = "@comment", default = true })
  vim.api.nvim_set_hl(0, "PyDepsBadgeGroup", { link = "@type", default = true })
  vim.api.nvim_set_hl(0, "PyDepsBadgeExtra", { link = "@constant", default = true })
end

---Setup highlight groups for info window
---@private
function M.setup_info_highlights()
  -- Core content groups
  vim.api.nvim_set_hl(0, "PyDepsInfoPackage", { link = "@keyword", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoDescription", { link = "@comment", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoLabel", { link = "@property", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoValue", { link = "@string", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoUrl", { link = "@markup.link.url", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoVersion", { link = "@number.float", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoPill", {
    ctermfg = 15,
    ctermbg = 242,
    fg = "#e0e0e0",
    bg = "#5a5a5a",
    default = true,
  })

  -- Status groups
  vim.api.nvim_set_hl(0, "PyDepsInfoStatusOk", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoStatusUpdate", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoStatusWarn", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoStatusError", { link = "DiagnosticError", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoStatusInactive", { link = "DiagnosticInfo", default = true })

  -- Suffix annotation groups
  vim.api.nvim_set_hl(0, "PyDepsInfoSuffixOk", { link = "DiagnosticOk", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoSuffixWarn", { link = "DiagnosticWarn", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoSuffixInfo", { link = "@comment", default = true })
  vim.api.nvim_set_hl(0, "PyDepsInfoSuffixError", { link = "DiagnosticError", default = true })
end

return M
