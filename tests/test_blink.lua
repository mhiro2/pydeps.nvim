local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local T = helpers.create_test_set()

---@param response table
---@return table calls
local function stub_core(response)
  local calls = {}
  helpers.stub(require("pydeps.completion.core"), "complete", function(bufnr, cursor, callback)
    calls[#calls + 1] = { bufnr, cursor }
    callback(response)
  end)
  helpers.stub_module("pydeps.completion.blink", nil)
  return calls
end

T["blink passes its cursor through and maps the result"] = function()
  local calls = stub_core({ items = { { label = "requests" } }, isIncomplete = true })
  local source = require("pydeps.completion.blink").new()

  local result
  source:get_completions({ bufnr = 12, cursor = { 3, 7 } }, function(value)
    result = value
  end)

  MiniTest.expect.equality(calls, { { 12, { 3, 7 } } })
  MiniTest.expect.equality(result, {
    items = { { label = "requests" } },
    is_incomplete_forward = true,
    is_incomplete_backward = true,
  })
end

T["blink falls back to the current window and tolerates missing items"] = function()
  local calls = stub_core({})
  local source = require("pydeps.completion.blink").new()
  helpers.setup_buffer({ "[project]", 'dependencies = ["requests"]' })
  vim.api.nvim_win_set_cursor(0, { 2, 18 })

  local result
  source:get_completions({}, function(value)
    result = value
  end)

  MiniTest.expect.equality(calls, { { vim.api.nvim_get_current_buf(), { 2, 18 } } })
  MiniTest.expect.equality(result, { items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
end

T["blink is enabled by the completion option"] = function()
  stub_core({})
  local config = require("pydeps.config")
  local source = require("pydeps.completion.blink").new()

  helpers.stub(config.options, "enable_completion", true)
  MiniTest.expect.equality(source:enabled(), true)
  config.options.enable_completion = false
  MiniTest.expect.equality(source:enabled(), false)
end

return T
