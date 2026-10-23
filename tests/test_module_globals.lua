local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.new_set()

---@return string[]
local function plugin_modules()
  local modules = {}
  for _, path in ipairs(vim.fn.globpath("lua", "pydeps/**/*.lua", false, true)) do
    local name = path:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/init$", ""):gsub("/", ".")
    table.insert(modules, name)
  end
  table.sort(modules)
  return modules
end

T["loading plugin modules defines no globals"] = function()
  local modules = plugin_modules()
  MiniTest.expect.equality(#modules > 0, true)

  for name in pairs(package.loaded) do
    if name == "pydeps" or name:sub(1, 7) == "pydeps." then
      helpers.stub_module(name, nil)
    end
  end

  local globals = getfenv(0)
  local before = {}
  for key in pairs(globals) do
    before[key] = true
  end

  for _, name in ipairs(modules) do
    require(name)
  end

  local leaked = {}
  for key in pairs(globals) do
    if not before[key] then
      table.insert(leaked, tostring(key))
    end
  end
  table.sort(leaked)
  MiniTest.expect.equality(leaked, {})
end

return T
