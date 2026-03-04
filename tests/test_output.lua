local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      helpers.close_extra_windows()
      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_set_current_buf(bufnr)
    end,
    post_case = function()
      helpers.close_extra_windows()
    end,
  },
})

T["output run_command: collects stdout chunks"] = function()
  package.loaded["pydeps.ui.output"] = nil
  local output = require("pydeps.ui.output")

  local original_jobstart = vim.fn.jobstart
  local original_show = output.show
  local shown_lines = nil

  output.show = function(_, lines)
    shown_lines = lines
  end

  vim.fn.jobstart = function(_, opts)
    vim.schedule(function()
      opts.on_stdout(nil, { "first line" })
      opts.on_stdout(nil, { "second line", "" })
      opts.on_exit(nil, 0)
    end)
    return 1
  end

  output.run_command({ "dummy" }, { title = "dummy" })
  vim.wait(200, function()
    return shown_lines ~= nil
  end, 10)

  MiniTest.expect.equality(vim.deep_equal(shown_lines, { "first line", "second line" }), true)

  output.show = original_show
  vim.fn.jobstart = original_jobstart
end

T["output run_command: collects stderr chunks for error message"] = function()
  package.loaded["pydeps.ui.output"] = nil
  local output = require("pydeps.ui.output")

  local original_jobstart = vim.fn.jobstart
  local original_notify = vim.notify
  local notified_message = nil

  vim.notify = function(msg)
    notified_message = msg
  end

  vim.fn.jobstart = function(_, opts)
    vim.schedule(function()
      opts.on_stderr(nil, { "first error" })
      opts.on_stderr(nil, { "second error", "" })
      opts.on_exit(nil, 1)
    end)
    return 1
  end

  output.run_command({ "dummy" }, { title = "dummy" })
  vim.wait(200, function()
    return notified_message ~= nil
  end, 10)

  MiniTest.expect.equality(notified_message:match("first error") ~= nil, true)
  MiniTest.expect.equality(notified_message:match("second error") ~= nil, true)

  vim.notify = original_notify
  vim.fn.jobstart = original_jobstart
end

return T
