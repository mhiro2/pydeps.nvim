local cwd = vim.fn.getcwd()
local mini_path = vim.env.MINI_PATH or (cwd .. "/deps/mini.nvim")
local treesitter_path = vim.env.TREESITTER_PATH or (cwd .. "/deps/nvim-treesitter")
local treesitter_install_dir = vim.env.TREESITTER_INSTALL_DIR or (cwd .. "/deps/treesitter")

vim.opt.runtimepath:append(cwd)
vim.opt.runtimepath:append(mini_path)
vim.opt.runtimepath:append(treesitter_path)

-- Configure Tree-sitter parser path
if vim.fn.isdirectory(treesitter_install_dir) == 1 then
  local parser_path = treesitter_install_dir .. "/parser"
  if vim.fn.isdirectory(parser_path) == 1 then
    -- Add the toml parser using the newer API
    pcall(function()
      vim.treesitter.language.add("toml", { path = parser_path .. "/toml.so" })
    end)
  end
end

package.path = table.concat({
  cwd .. "/?.lua",
  cwd .. "/?/init.lua",
  package.path,
}, ";")

vim.opt.swapfile = false
vim.opt.writebackup = false
vim.opt.shortmess:append("W")

local MiniTest = require("mini.test")
MiniTest.setup({
  execute = {
    reporter = MiniTest.gen_reporter.stdout(),
  },
})
