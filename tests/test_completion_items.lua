local MiniTest = require("mini.test")

local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      package.loaded["pydeps.completion.items"] = nil
    end,
  },
})

T["uniform_meta applies shared detail and label description"] = function()
  local items = require("pydeps.completion.items")
  local meta = items.uniform_meta({ "requests", "rich" }, "package", "local")

  MiniTest.expect.equality(meta.requests.detail, "package")
  MiniTest.expect.equality(meta.requests.label_details.description, "local")
  MiniTest.expect.equality(meta.rich.label_details.description, "local")
end

T["package_source_meta labels mixed package origins"] = function()
  local items = require("pydeps.completion.items")
  local meta = items.package_source_meta({
    requests = { is_local = true, pypi = true },
    rich = { is_local = true },
    pytest = { pypi = true },
  })

  MiniTest.expect.equality(meta.requests.label_details.description, "local/PyPI")
  MiniTest.expect.equality(meta.rich.label_details.description, "local")
  MiniTest.expect.equality(meta.pytest.label_details.description, "PyPI")
end

T["as_items preserves text edit range and optional metadata"] = function()
  local items = require("pydeps.completion.items")
  local range = {
    start = { line = 1, character = 2 },
    ["end"] = { line = 1, character = 6 },
  }
  local result = items.as_items(
    {
      "requests",
    },
    range,
    items.kinds.Module,
    {
      requests = {
        detail = "package",
        label_details = { description = "local" },
        sort_text = "001",
      },
    }
  )

  MiniTest.expect.equality(#result, 1)
  MiniTest.expect.equality(result[1].label, "requests")
  MiniTest.expect.equality(result[1].detail, "package")
  MiniTest.expect.equality(result[1].labelDetails.description, "local")
  MiniTest.expect.equality(result[1].sortText, "001")
  MiniTest.expect.equality(result[1].textEdit.range, range)
end

return T
