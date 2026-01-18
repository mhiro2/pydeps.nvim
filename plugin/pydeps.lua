local commands = require("pydeps.commands")

vim.api.nvim_create_user_command("PyDepsToggle", function()
  commands.toggle()
end, {})

vim.api.nvim_create_user_command("PyDepsUpdate", function(opts)
  commands.update(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

vim.api.nvim_create_user_command("PyDepsResolve", function(opts)
  commands.resolve({ diff_only = opts.bang })
end, { bang = true })

vim.api.nvim_create_user_command("PyDepsTree", function(opts)
  commands.tree(opts.args, opts.bang)
end, { nargs = "*", bang = true })

vim.api.nvim_create_user_command("PyDepsWhy", function(opts)
  commands.provenance(opts.args ~= "" and opts.args or nil)
end, { nargs = "?" })

vim.api.nvim_create_user_command("PyDepsInfo", function()
  commands.info()
end, {})
