local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

---@param lines string[]
---@return integer
local function toml_buffer(lines)
  helpers.setup_buffer(lines)
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  return bufnr
end

---@param bufnr integer
---@param name string
---@return PyDepsDependency
local function parsed_dep(bufnr, name)
  for _, dep in ipairs(require("pydeps.sources.pyproject").parse(nil, nil, bufnr)) do
    if dep.name == name then
      return dep
    end
  end
  error("dependency not parsed: " .. name, 2)
end

T["replace_dependency rewrites only the dependency string"] = function()
  local edit = require("pydeps.sources.pyproject_edit")
  local bufnr = toml_buffer({
    "[project]",
    "dependencies = [",
    "  \"requests>=2; python_version >= '3.8'\",  # http",
    '  "rich==13.7.0",',
    "]",
  })

  MiniTest.expect.equality(
    edit.replace_dependency(bufnr, parsed_dep(bufnr, "requests"), "requests==2.32.0; python_version >= '3.8'"),
    true
  )

  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
    "[project]",
    "dependencies = [",
    "  \"requests==2.32.0; python_version >= '3.8'\",  # http",
    '  "rich==13.7.0",',
    "]",
  })
end

T["replace_dependency keeps neighbours on an inline array"] = function()
  local edit = require("pydeps.sources.pyproject_edit")
  local bufnr = toml_buffer({
    "[project]",
    "dependencies = ['requests>=2', 'rich==13.7.0', \"click\"] # pinned",
  })

  edit.replace_dependency(bufnr, parsed_dep(bufnr, "rich"), "rich==14.0.0")

  MiniTest.expect.equality(
    vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1],
    "dependencies = ['requests>=2', 'rich==14.0.0', \"click\"] # pinned"
  )
end

T["replace_dependency rejects a dependency without a position"] = function()
  local edit = require("pydeps.sources.pyproject_edit")
  local bufnr = toml_buffer({ "[project]", 'dependencies = ["requests"]' })

  MiniTest.expect.equality(edit.replace_dependency(bufnr, { name = "requests" }, "requests==1"), false)
  MiniTest.expect.equality(vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1], 'dependencies = ["requests"]')
end

return T
