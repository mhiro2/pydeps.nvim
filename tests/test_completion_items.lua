local MiniTest = require("mini.test")

local T = MiniTest.new_set()

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

T["as_items shares the range and inserts new_text over the label"] = function()
  local items = require("pydeps.completion.items")
  local range = {
    start = { line = 1, character = 2 },
    ["end"] = { line = 1, character = 6 },
  }
  local result = items.as_items({ "Linux", "posix" }, range, items.kinds.EnumMember, {
    Linux = { detail = "marker value", label_details = { description = "platform_system" }, new_text = "'Linux'" },
  })

  MiniTest.expect.equality(result, {
    {
      label = "Linux",
      kind = items.kinds.EnumMember,
      detail = "marker value",
      labelDetails = { description = "platform_system" },
      textEdit = { newText = "'Linux'", range = range },
    },
    {
      label = "posix",
      kind = items.kinds.EnumMember,
      textEdit = { newText = "posix", range = range },
    },
  })
end

return T
