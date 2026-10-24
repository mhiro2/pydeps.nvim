local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.config"] = nil
      package.loaded["pydeps.health"] = nil
      package.loaded["pydeps.treesitter.toml"] = nil
    end,
  },
})

---@param ts_available boolean
---@param nvim_version? string
---@return table<string, string[]>
local function run_health(ts_available, nvim_version)
  require("pydeps.config").setup({})

  local messages = {
    ok = {},
    warn = {},
    error = {},
    info = {},
    start = {},
  }

  helpers.stub(vim, "health", {
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
  })
  helpers.stub(vim.fn, "executable", function(_)
    return 0
  end)
  if nvim_version then
    local version = vim.version
    helpers.stub(
      vim,
      "version",
      setmetatable({}, {
        __index = version,
        __call = function()
          return version.parse(nvim_version)
        end,
      })
    )
  end
  helpers.stub_module("pydeps.treesitter.toml", {
    is_available = function()
      return ts_available
    end,
  })

  require("pydeps.health").check()
  return messages
end

T["check enforces Neovim 0.12 as minimum version"] = function()
  local cases = {
    { version = "0.11.5", error = "Neovim version: 0.11.5 (expected >= 0.12.0)" },
    { version = "0.12.0", ok = "Neovim version: 0.12.0" },
    { version = "1.0.2", ok = "Neovim version: 1.0.2" },
  }
  for _, case in ipairs(cases) do
    package.loaded["pydeps.health"] = nil
    local messages = run_health(true, case.version)
    MiniTest.expect.equality(messages.start[1], "pydeps.nvim")
    local reported = vim.tbl_filter(function(msg)
      return vim.startswith(msg, "Neovim version")
    end, vim.list_extend(vim.list_extend({}, messages.ok), messages.error))
    MiniTest.expect.equality(reported, { case.ok or case.error })
    MiniTest.expect.equality(vim.tbl_contains(messages.ok, case.ok or ""), case.ok ~= nil)
    helpers.restore_all()
  end
end

T["check reports an available TOML parser"] = function()
  local messages = run_health(true)

  MiniTest.expect.equality(vim.tbl_contains(messages.ok, "Tree-sitter: TOML parser available"), true)
end

T["check reports missing TOML parser without nvim-treesitter wording"] = function()
  local messages = run_health(false)

  MiniTest.expect.equality(vim.tbl_contains(messages.error, "Tree-sitter: TOML parser not available"), true)
  MiniTest.expect.equality(vim.tbl_contains(messages.error, "nvim-treesitter: toml parser not installed"), false)
end

return T
