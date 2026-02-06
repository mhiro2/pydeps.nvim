vim.api.nvim_create_user_command("PyDepsToggle", function()
  require("pydeps.commands").toggle()
end, {})

vim.api.nvim_create_user_command("PyDepsUpdate", function(opts)
  require("pydeps.commands").update(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

vim.api.nvim_create_user_command("PyDepsResolve", function(opts)
  require("pydeps.commands").resolve({ diff_only = opts.bang })
end, { bang = true })

vim.api.nvim_create_user_command("PyDepsTree", function(opts)
  require("pydeps.commands").tree(opts.args, opts.bang)
end, { nargs = "*", bang = true })

vim.api.nvim_create_user_command("PyDepsWhy", function(opts)
  require("pydeps.commands").provenance(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

vim.api.nvim_create_user_command("PyDepsInfo", function()
  require("pydeps.commands").info()
end, {})
