local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.config"] = nil
      package.loaded["pydeps.health"] = nil
      package.loaded["pydeps.treesitter.toml"] = nil
    end,
  },
})

---@param version vim.Version
---@return string
local function version_string(version)
  return string.format("%d.%d.%d", version.major, version.minor, version.patch)
end

---@param ts_available boolean
---@return table<string, string[]>
local function run_health(ts_available)
  require("pydeps.config").setup({})

  local messages = {
    ok = {},
    warn = {},
    error = {},
    info = {},
    start = {},
  }

  local original_health = vim.health
  local original_executable = vim.fn.executable

  vim.health = {
    start = function(message)
      table.insert(messages.start, message)
    end,
    ok = function(message)
      table.insert(messages.ok, message)
    end,
    warn = function(message)
      table.insert(messages.warn, message)
    end,
    error = function(message)
      table.insert(messages.error, message)
    end,
    info = function(message)
      table.insert(messages.info, message)
    end,
  }

  vim.fn.executable = function(_)
    return 0
  end

  package.loaded["pydeps.treesitter.toml"] = {
    is_available = function()
      return ts_available
    end,
  }

  require("pydeps.health").check()

  vim.health = original_health
  vim.fn.executable = original_executable
  package.loaded["pydeps.treesitter.toml"] = nil

  return messages
end

T["check reports Neovim 0.12 as minimum version"] = function()
  local messages = run_health(true)
  local current = version_string(vim.version())

  MiniTest.expect.equality(messages.start[1], "pydeps.nvim")
  MiniTest.expect.equality(vim.tbl_contains(messages.ok, "Neovim version: " .. current), true)
  MiniTest.expect.equality(vim.tbl_contains(messages.ok, "Tree-sitter: TOML parser available"), true)
end

T["check reports missing TOML parser without nvim-treesitter wording"] = function()
  local messages = run_health(false)

  MiniTest.expect.equality(vim.tbl_contains(messages.error, "Tree-sitter: TOML parser not available"), true)
  MiniTest.expect.equality(vim.tbl_contains(messages.error, "nvim-treesitter: toml parser not installed"), false)
end

return T
