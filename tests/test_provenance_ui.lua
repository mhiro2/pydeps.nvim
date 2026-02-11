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

return T
