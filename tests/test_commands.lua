local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function create_project(lines, packages)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/pyproject.toml"
  vim.fn.writefile(lines, path)
  helpers.create_uv_lock(dir, packages)
  vim.cmd("edit " .. path)
  helpers.setup_buffer(lines)
  return dir, path
end

local function cleanup(dir)
  if dir then
    vim.fn.delete(dir, "rf")
  end
end

T["update rejects @ reference"] = function()
  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["package @ git+https://github.com/user/repo.git"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("direct reference") then
      notified = true
    end
  end

  commands.update("package")

  vim.notify = original_notify
  MiniTest.expect.equality(notified, true)
  cleanup(dir)
end

T["update rejects https URL"] = function()
  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["package @ https://example.com/package.tar.gz"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("direct reference") then
      notified = true
    end
  end

  commands.update("package")

  vim.notify = original_notify
  MiniTest.expect.equality(notified, true)
  cleanup(dir)
end

T["update rejects file:// URL"] = function()
  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["package @ file:///path/to/package"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("direct reference") then
      notified = true
    end
  end

  commands.update("package")

  vim.notify = original_notify
  MiniTest.expect.equality(notified, true)
  cleanup(dir)
end

T["update rejects relative path"] = function()
  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["package @ ./local/package"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("direct reference") then
      notified = true
    end
  end

  commands.update("package")

  vim.notify = original_notify
  MiniTest.expect.equality(notified, true)
  cleanup(dir)
end

T["update allows version spec"] = function()
  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("direct reference") then
      notified = true
    end
  end

  commands.update("requests")

  vim.notify = original_notify
  MiniTest.expect.equality(notified, false)
  cleanup(dir)
end

T["update escapes pattern characters in version spec"] = function()
  local original_commands = package.loaded["pydeps.commands"]
  local original_pypi = package.loaded["pydeps.providers.pypi"]

  package.loaded["pydeps.commands"] = nil
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb({ info = { version = "2.0.0" } })
    end,
  }

  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["pkg==1.0+cpu"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  commands.update("pkg")

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(vim.tbl_contains(lines, 'dependencies = ["pkg==2.0.0"]'), true)
  cleanup(dir)

  package.loaded["pydeps.commands"] = original_commands
  package.loaded["pydeps.providers.pypi"] = original_pypi
end

T["audit collects lockfile packages and renders result"] = function()
  local original_commands = package.loaded["pydeps.commands"]
  local original_osv = package.loaded["pydeps.providers.osv"]
  local original_security_audit = package.loaded["pydeps.ui.security_audit"]

  local captured_packages = nil
  local captured_show = nil
  package.loaded["pydeps.commands"] = nil
  package.loaded["pydeps.providers.osv"] = {
    audit = function(packages, cb)
      captured_packages = packages
      cb({
        {
          name = "requests",
          version = "2.31.0",
          vulnerabilities = {},
        },
      }, nil)
    end,
  }
  package.loaded["pydeps.ui.security_audit"] = {
    show = function(results, opts)
      captured_show = { results = results, opts = opts }
      return {
        scanned_packages = 2,
        vulnerable_packages = 0,
        total_vulnerabilities = 0,
      }
    end,
  }

  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["requests", "urllib3"]',
  }, {
    requests = "2.31.0",
    urllib3 = "2.2.0",
  })

  commands.audit()
  vim.wait(200, function()
    return captured_show ~= nil
  end, 10)

  MiniTest.expect.equality(captured_packages ~= nil, true)
  MiniTest.expect.equality(#captured_packages, 2)
  MiniTest.expect.equality(captured_packages[1].name, "requests")
  MiniTest.expect.equality(captured_packages[2].name, "urllib3")
  local actual_root = vim.uv.fs_realpath(captured_show.opts.root) or captured_show.opts.root
  local expected_root = vim.uv.fs_realpath(dir) or dir
  MiniTest.expect.equality(actual_root, expected_root)
  MiniTest.expect.equality(captured_show.results[1].name, "requests")

  cleanup(dir)
  package.loaded["pydeps.commands"] = original_commands
  package.loaded["pydeps.providers.osv"] = original_osv
  package.loaded["pydeps.ui.security_audit"] = original_security_audit
end

T["audit warns when uv.lock is missing"] = function()
  local original_commands = package.loaded["pydeps.commands"]
  package.loaded["pydeps.commands"] = nil
  local commands = require("pydeps.commands")

  local dir = create_project({
    "[project]",
    'dependencies = ["requests"]',
  }, {
    requests = "2.31.0",
  })

  local lock_path = dir .. "/uv.lock"
  vim.fn.delete(lock_path)

  local notified = false
  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("uv%.lock not found") then
      notified = true
    end
  end

  commands.audit()

  vim.notify = original_notify
  MiniTest.expect.equality(notified, true)
  cleanup(dir)
  package.loaded["pydeps.commands"] = original_commands
end

T["provenance uses project dependencies outside pyproject buffers"] = function()
  local original_commands = package.loaded["pydeps.commands"]
  local original_provenance_command = package.loaded["pydeps.commands.provenance"]
  local original_provenance_ui = package.loaded["pydeps.ui.provenance"]

  local captured = nil
  package.loaded["pydeps.commands"] = nil
  package.loaded["pydeps.commands.provenance"] = nil
  package.loaded["pydeps.ui.provenance"] = {
    show = function(target, deps, graph)
      captured = {
        target = target,
        deps = deps,
        graph = graph,
      }
      return true
    end,
  }

  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2.31", "rich>=13"]',
  }, {
    requests = "2.31.0",
    rich = "13.7.0",
  })
  local script_path = dir .. "/app.py"
  vim.fn.writefile({ "print('hello')" }, script_path)

  local script_buf = vim.fn.bufadd(script_path)
  vim.fn.bufload(script_buf)
  vim.api.nvim_set_current_buf(script_buf)

  commands.provenance("requests")

  MiniTest.expect.equality(captured ~= nil, true)
  MiniTest.expect.equality(captured.target, "requests")
  MiniTest.expect.equality(#captured.deps, 2)
  MiniTest.expect.equality(captured.deps[1].name, "requests")
  MiniTest.expect.equality(captured.deps[2].name, "rich")

  cleanup(dir)
  package.loaded["pydeps.commands"] = original_commands
  package.loaded["pydeps.commands.provenance"] = original_provenance_command
  package.loaded["pydeps.ui.provenance"] = original_provenance_ui
end

T["info preserves lockfile loading state"] = function()
  local original_cache = package.loaded["pydeps.core.cache"]
  local original_commands = package.loaded["pydeps.commands"]
  local original_info_command = package.loaded["pydeps.commands.info"]
  local original_info = package.loaded["pydeps.ui.info"]

  local captured = nil
  package.loaded["pydeps.core.cache"] = {
    get_pyproject = function()
      return {
        {
          name = "requests",
          spec = "requests>=2.31",
          line = 2,
          col_start = 18,
          col_end = 25,
        },
      }
    end,
    get_lockfile = function()
      return { resolved = {} }, false, true
    end,
  }
  package.loaded["pydeps.commands"] = nil
  package.loaded["pydeps.commands.info"] = nil
  package.loaded["pydeps.ui.info"] = {
    show = function(dep, resolved, opts)
      captured = {
        dep = dep,
        resolved = resolved,
        opts = opts,
      }
    end,
  }

  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2.31"]',
  })

  vim.api.nvim_win_set_cursor(0, { 2, 18 })
  commands.info()

  MiniTest.expect.equality(captured ~= nil, true)
  MiniTest.expect.equality(captured.dep.name, "requests")
  MiniTest.expect.equality(captured.opts.lockfile_loading, true)
  MiniTest.expect.equality(captured.opts.lockfile_missing, false)
  local actual_root = vim.uv.fs_realpath(captured.opts.root) or captured.opts.root
  local expected_root = vim.uv.fs_realpath(dir) or dir
  MiniTest.expect.equality(actual_root, expected_root)

  cleanup(dir)
  package.loaded["pydeps.core.cache"] = original_cache
  package.loaded["pydeps.commands"] = original_commands
  package.loaded["pydeps.commands.info"] = original_info_command
  package.loaded["pydeps.ui.info"] = original_info
end

T["tree warns on unknown options and still invokes uv tree"] = function()
  local original_uv = package.loaded["pydeps.providers.uv"]
  local original_output = package.loaded["pydeps.ui.output"]
  package.loaded["pydeps.providers.uv"] = {
    tree_features_ready = function()
      return true
    end,
    detect_tree_features = function(cb)
      if cb then
        cb()
      end
    end,
    supports_tree_flag = function()
      return false
    end,
    tree_command = function()
      return {
        cmd = { "uv", "tree" },
        cwd = vim.fn.getcwd(),
      }
    end,
  }
  package.loaded["pydeps.ui.output"] = {
    run_command = function() end,
  }

  local commands = require("pydeps.commands")
  local dir = create_project({
    "[project]",
    'dependencies = ["requests>=2"]',
  })
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local notified = false
  local output_called = false
  package.loaded["pydeps.ui.output"].run_command = function()
    output_called = true
  end

  local original_notify = vim.notify
  vim.notify = function(msg, _level)
    if msg:match("unknown tree options") then
      notified = true
    end
  end

  commands.tree("--unknown requests", false, {})

  vim.notify = original_notify
  MiniTest.expect.equality(notified, true)
  MiniTest.expect.equality(output_called, true)

  cleanup(dir)
  package.loaded["pydeps.providers.uv"] = original_uv
  package.loaded["pydeps.ui.output"] = original_output
end

return T
