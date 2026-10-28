local MiniTest = require("mini.test")

local T = MiniTest.new_set()

---@param test_fn fun()
---@return nil
local function with_stubs(test_fn)
  local original_output = package.loaded["pydeps.ui.output"]
  local original_info = package.loaded["pydeps.ui.info"]
  local original_module = package.loaded["pydeps.ui.provenance"]

  local ok, err = pcall(test_fn)

  package.loaded["pydeps.ui.output"] = original_output
  package.loaded["pydeps.ui.info"] = original_info
  package.loaded["pydeps.ui.provenance"] = original_module

  if not ok then
    error(err)
  end
end

T["ui.provenance.show renders grouped path summary"] = function()
  with_stubs(function()
    local captured = nil
    local suspend_calls = 0
    local resume_calls = 0

    package.loaded["pydeps.ui.output"] = {
      show = function(title, lines, opts)
        captured = { title = title, lines = lines, opts = opts }
        if opts and opts.on_close then
          opts.on_close()
        end
      end,
    }
    package.loaded["pydeps.ui.info"] = {
      suspend_close = function()
        suspend_calls = suspend_calls + 1
      end,
      resume_close = function()
        resume_calls = resume_calls + 1
      end,
    }
    package.loaded["pydeps.ui.provenance"] = nil

    local provenance_ui = require("pydeps.ui.provenance")
    local ok, err = provenance_ui.show("certifi", {
      { name = "requests", group = "project" },
      { name = "rich", group = "dev" },
    }, {
      requests = { "urllib3" },
      urllib3 = { "certifi" },
      rich = { "certifi" },
      certifi = {},
    })

    MiniTest.expect.equality(ok, true)
    MiniTest.expect.equality(err, nil)
    MiniTest.expect.equality(captured.title, "PyDeps Why: certifi")
    MiniTest.expect.equality(captured.opts.mode, "float")
    MiniTest.expect.equality(captured.opts.anchor, "hover")
    MiniTest.expect.equality(suspend_calls, 1)
    MiniTest.expect.equality(resume_calls, 1)
    MiniTest.expect.equality(vim.tbl_contains(captured.lines, "Target: certifi"), true)
    MiniTest.expect.equality(vim.tbl_contains(captured.lines, "Direct: no"), true)

    local has_summary = false
    local has_dev_path = false
    for _, line in ipairs(captured.lines) do
      if line == "Roots with path: 2 (project(1), dev(1))" then
        has_summary = true
      end
      if line == "  - rich [dev] -> certifi" then
        has_dev_path = true
      end
    end
    MiniTest.expect.equality(has_summary, true)
    MiniTest.expect.equality(has_dev_path, true)
  end)
end

T["ui.provenance.show resumes hover close when output fails"] = function()
  with_stubs(function()
    local suspend_calls = 0
    local resume_calls = 0

    package.loaded["pydeps.ui.output"] = {
      show = function()
        error("boom")
      end,
    }
    package.loaded["pydeps.ui.info"] = {
      suspend_close = function()
        suspend_calls = suspend_calls + 1
      end,
      resume_close = function()
        resume_calls = resume_calls + 1
      end,
    }
    package.loaded["pydeps.ui.provenance"] = nil

    local provenance_ui = require("pydeps.ui.provenance")
    local ok, err = provenance_ui.show("certifi", {
      { name = "requests", group = "project" },
    }, {
      requests = { "certifi" },
      certifi = {},
    })

    MiniTest.expect.equality(ok, nil)
    MiniTest.expect.equality(type(err), "string")
    MiniTest.expect.equality(err:match("boom") ~= nil, true)
    MiniTest.expect.equality(suspend_calls, 1)
    MiniTest.expect.equality(resume_calls, 1)
  end)
end

T["ui.provenance.show only follows roots the context keeps"] = function()
  with_stubs(function()
    local captured = nil
    package.loaded["pydeps.ui.output"] = {
      show = function(_, lines)
        captured = lines
      end,
    }
    package.loaded["pydeps.ui.info"] = { suspend_close = function() end, resume_close = function() end }
    package.loaded["pydeps.ui.provenance"] = nil

    local deps = {
      { name = "requests", group = "project" },
      { name = "pywin32", group = "project" },
    }
    require("pydeps.ui.provenance").show("pywin32", deps, {
      requests = {},
      pywin32 = {},
    }, { active_deps = { deps[1] }, context = "python 3.13.1 · darwin · extras all · groups all" })

    MiniTest.expect.equality(captured[1], "Target: pywin32")
    MiniTest.expect.equality(captured[2], "Context: python 3.13.1 · darwin · extras all · groups all")
    MiniTest.expect.equality(captured[3], "Direct: yes (inactive)")
    MiniTest.expect.equality(captured[4], "No path from active roots.")

    -- A package declared in an excluded extra and a selected group is labelled by the group.
    local orm_deps = {
      { name = "orm", group = "optional:postgres" },
      { name = "orm", group = "group:test" },
    }
    require("pydeps.ui.provenance").show("orm", orm_deps, { orm = {} }, { active_deps = { orm_deps[2] } })
    MiniTest.expect.equality(captured[2], "Direct: yes (group:test)")
    MiniTest.expect.equality(vim.tbl_contains(captured, "  - orm [group:test]"), true)

    require("pydeps.ui.provenance").show("orm", orm_deps, { orm = {} }, { active_deps = {} })
    MiniTest.expect.equality(captured[2], "Direct: yes (optional:postgres, inactive)")
  end)
end

return T
