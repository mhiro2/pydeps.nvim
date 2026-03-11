local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.providers.uv"] = nil
    end,
    post_case = function()
      package.loaded["pydeps.providers.uv"] = nil
    end,
  },
})

T["resolve returns success result"] = function()
  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart

  vim.fn.executable = function(cmd)
    if cmd == "uv" then
      return 1
    end
    return original_executable(cmd)
  end

  vim.fn.jobstart = function(cmd, opts)
    MiniTest.expect.equality(vim.deep_equal(cmd, { "uv", "lock" }), true)
    vim.schedule(function()
      opts.on_exit(nil, 0, nil)
    end)
    return 1
  end

  local uv = require("pydeps.providers.uv")
  local result = nil
  uv.resolve({
    root = "/tmp/project",
    on_finish = function(value)
      result = value
    end,
  })

  vim.wait(200, function()
    return result ~= nil
  end, 10)

  MiniTest.expect.equality(result.ok, true)
  MiniTest.expect.equality(result.code, 0)

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

T["resolve returns stderr on failure"] = function()
  local original_executable = vim.fn.executable
  local original_jobstart = vim.fn.jobstart

  vim.fn.executable = function(cmd)
    if cmd == "uv" then
      return 1
    end
    return original_executable(cmd)
  end

  vim.fn.jobstart = function(_, opts)
    vim.schedule(function()
      opts.on_stderr(nil, { "lock failed" })
      opts.on_exit(nil, 2, nil)
    end)
    return 1
  end

  local uv = require("pydeps.providers.uv")
  local result = nil
  uv.resolve({
    on_finish = function(value)
      result = value
    end,
  })

  vim.wait(200, function()
    return result ~= nil
  end, 10)

  MiniTest.expect.equality(result.ok, false)
  MiniTest.expect.equality(result.reason, "exit")
  MiniTest.expect.equality(result.code, 2)
  MiniTest.expect.equality(result.stderr, "lock failed")

  vim.fn.executable = original_executable
  vim.fn.jobstart = original_jobstart
end

T["tree_command returns explicit command payload"] = function()
  local original_executable = vim.fn.executable

  vim.fn.executable = function(cmd)
    if cmd == "uv" then
      return 1
    end
    return original_executable(cmd)
  end

  local uv = require("pydeps.providers.uv")
  local command = uv.tree_command({
    root = "/tmp/project",
    args = { "tree", "--depth", "2" },
  })

  MiniTest.expect.no_equality(command, nil)
  MiniTest.expect.equality(vim.deep_equal(command.cmd, { "uv", "tree", "--depth", "2" }), true)
  MiniTest.expect.equality(command.cwd, "/tmp/project")

  vim.fn.executable = original_executable
end

return T
