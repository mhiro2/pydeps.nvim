local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")
local plan = require("pydeps.core.update_plan")

local T = helpers.new_set()

---@param releases table<string, { requires_python?: string, yanked?: boolean }|false>
---@return PyDepsPyPIMeta
local function meta(releases)
  local data = { info = {}, releases = {} }
  for name, file in pairs(releases) do
    data.releases[name] = file and { file } or {}
  end
  return data
end

T["parse_dry_run reads updates, forks, additions and removals"] = function()
  local output = table.concat({
    "Using CPython 3.12.4",
    "Resolved 7 packages in 274ms",
    "Update Requests v2.31.0 -> v2.32.5, v2.34.2",
    "Add charset_normalizer v3.3.2",
    "Remove chardet v5.2.0",
    "Lockfile changes detected",
  }, "\n")

  MiniTest.expect.equality(plan.parse_dry_run(output), {
    { kind = "update", name = "requests", from = { "2.31.0" }, to = { "2.32.5", "2.34.2" } },
    { kind = "add", name = "charset-normalizer", to = { "3.3.2" } },
    { kind = "remove", name = "chardet", from = { "5.2.0" } },
  })
  MiniTest.expect.equality(plan.parse_dry_run(nil), {})
end

T["rewrite_spec admits the target while keeping the intent of each bound"] = function()
  local cases = {
    { "demo>=2,<3", "3.1.0", "demo>=3.1.0,<4" },
    { "demo>=2.0,<2.1", "2.3.0", "demo>=2.3.0,<2.4" },
    { "demo>=1,<2.0.0", "3.1", "demo>=3.1,<4.0.0" },
    { "demo==1.0+cpu", "2.0.0", "demo==2.0.0" },
    { "demo==1.*", "2.5.1", "demo==2.*" },
    { "demo~=1.4", "2.5.1", "demo~=2.5" },
    { "demo>1,!=2.0.0,<=1.9", "2.0.0", "demo>=2.0.0,<=2.0.0" },
    { "demo[socks] (>=2,<3) ; python_version >= '3.9'", "3.0", "demo[socks]>=3.0,<4; python_version >= '3.9'" },
    { "demo", "1.2", "demo>=1.2" },
    { "demo~=1!1.4", "1!2.5", "demo~=1!2.5" },
    { "demo==1!1.*", "1!2.5", "demo==1!2.*" },
    { "demo>=1!1,<1!2", "1!2.5", "demo>=1!2.5,<1!3" },
  }
  for _, case in ipairs(cases) do
    MiniTest.expect.equality(plan.rewrite_spec(case[1], case[2]), case[3])
  end
  MiniTest.expect.equality(plan.rewrite_spec("demo>=2,<3", "not-a-version"), nil)
  MiniTest.expect.equality(plan.rewrite_spec("demo>>2", "3.0"), nil)
end

T["python_floor reads the lower bound of requires-python"] = function()
  MiniTest.expect.equality(plan.python_floor(">=3.9,<4"), "3.9")
  MiniTest.expect.equality(plan.python_floor("<4, ~=3.10"), "3.10")
  MiniTest.expect.equality(plan.python_floor("==3.11.*"), "3.11")
  MiniTest.expect.equality(plan.python_floor(">=3.8,>=3.10"), "3.10")
  MiniTest.expect.equality(plan.python_floor(">=3.10,>=3.8"), "3.10")
  MiniTest.expect.equality(plan.python_floor("<4"), nil)
  MiniTest.expect.equality(plan.python_floor(nil), nil)
end

T["build separates uv's upgrade, a pin in range and a declaration change"] = function()
  local result = plan.build({
    name = "demo",
    spec = "demo>=2,<3",
    locked = { "2.1.0" },
    python = "3.9",
    meta = meta({
      ["2.1.0"] = {},
      ["2.2.0"] = { requires_python = vim.NIL },
      ["2.4.0"] = { requires_python = ">=3.8" },
      ["2.5.0"] = { yanked = true },
      ["2.6.0rc1"] = {},
      ["3.0.0"] = { requires_python = ">=3.9" },
      ["3.1.0"] = { requires_python = ">=3.11" },
      ["3.2.0"] = false,
    }),
    dry_run = {
      ok = true,
      changes = {
        { kind = "update", name = "demo", from = { "2.1.0" }, to = { "2.3.0" } },
        { kind = "add", name = "idna", to = { "3.7" } },
      },
    },
  })

  MiniTest.expect.equality(result.candidates, {
    {
      kind = "lock",
      version = "2.3.0",
      upgrade = "demo",
      changes = {
        { kind = "update", name = "demo", from = { "2.1.0" }, to = { "2.3.0" } },
        { kind = "add", name = "idna", to = { "3.7" } },
      },
    },
    { kind = "pin", version = "2.4.0", upgrade = "demo==2.4.0", note = "uv resolves 2.3.0" },
    {
      kind = "declare",
      version = "3.0.0",
      upgrade = "demo==3.0.0",
      spec = "demo>=3.0.0,<4",
      note = "newest for Python 3.9",
    },
  })
  MiniTest.expect.equality(result.notes, { "latest 3.1.0 requires Python >=3.11 (project supports 3.9)" })
end

T["build offers nothing newer than the lock and explains a failed dry run"] = function()
  local result = plan.build({
    name = "demo",
    spec = "demo==2.4.0",
    locked = { "2.0.0", "2.4.0" },
    meta = meta({ ["2.4.0"] = {}, ["2.3.0"] = {} }),
    dry_run = { ok = false, changes = {}, error = "error: No solution found" },
  })

  MiniTest.expect.equality(result.candidates, {})
  MiniTest.expect.equality(result.notes, { "uv lock --dry-run failed: error: No solution found" })
end

T["build pins in range when uv keeps the locked version"] = function()
  local result = plan.build({
    name = "demo",
    spec = "demo",
    locked = { "1.0" },
    dry_run = { ok = true, changes = {} },
    meta = meta({ ["1.0"] = {}, ["1.1"] = {} }),
  })

  MiniTest.expect.equality(result.candidates, {
    { kind = "pin", version = "1.1", upgrade = "demo==1.1", note = "uv keeps the locked version" },
  })
end

T["build still offers uv's upgrade without PyPI metadata"] = function()
  local result = plan.build({
    name = "demo",
    spec = "demo>=1",
    locked = { "1.0" },
    dry_run = { ok = true, changes = { { kind = "update", name = "demo", from = { "1.0" }, to = { "1.2", "1.3" } } } },
  })

  MiniTest.expect.equality(result.candidates[1].kind, "lock")
  MiniTest.expect.equality(result.candidates[1].version, "1.2, 1.3")
  MiniTest.expect.equality(#result.candidates, 1)
  MiniTest.expect.equality(result.notes, { "PyPI metadata not available" })
end

T["build offers no release PyPI marks as prerelease or yanked"] = function()
  local data = meta({ ["2.0rc1"] = {}, ["1.9"] = { yanked = true } })
  data.info.version = "2.0rc1"
  local result = plan.build({ name = "demo", spec = "demo>=1", locked = { "1.0" }, meta = data })

  MiniTest.expect.equality(result.candidates, {})
end

return T
