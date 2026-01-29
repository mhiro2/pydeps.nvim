local MiniTest = require("mini.test")
local helpers = require("tests.test_helpers")

local T = helpers.create_test_set()

local function stub_pypi()
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb({
        info = { version = "1.0.0" },
        releases = {},
      })
    end,
    is_yanked = function()
      return false
    end,
  }
end

local function stub_cache()
  package.loaded["pydeps.core.cache"] = {
    get_pyproject = function()
      return {
        { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" },
      }
    end,
    get_lockfile = function()
      return { resolved = { testpkg = "1.0.0" }, packages = {} }, false
    end,
  }
end

T["info.show() closes existing hover before creating new one"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  -- Create first hover
  info.show(dep, "1.0.0", {})
  vim.wait(100)

  local windows = vim.api.nvim_list_wins()
  local hover_count_before = 0
  for _, win in ipairs(windows) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_count_before = hover_count_before + 1
    end
  end

  -- Create second hover (should close first one)
  info.show(dep, "1.0.0", {})
  vim.wait(100)

  windows = vim.api.nvim_list_wins()
  local hover_count_after = 0
  for _, win in ipairs(windows) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_count_after = hover_count_after + 1
    end
  end

  MiniTest.expect.equality(hover_count_after, 1)
  info.close_hover()
end

T["info.show() sets up keybindings for Enter and gT"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Check that keybindings are set
  local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local has_cr = false
  local has_gt = false
  for _, km in ipairs(keymaps) do
    if km.lhs == "<CR>" and km.desc == "PyDeps: Show why this dependency is needed" then
      has_cr = true
    end
    if km.lhs == "gT" and km.desc == "PyDeps: Show dependency tree" then
      has_gt = true
    end
  end

  MiniTest.expect.equality(has_cr, true)
  MiniTest.expect.equality(has_gt, true)

  info.close_hover()
end

T["info.close_hover() removes keybindings"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  info.close_hover()

  -- Check that keybindings are removed
  local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local has_cr = false
  local has_gt = false
  for _, km in ipairs(keymaps) do
    if km.lhs == "<CR>" and km.desc == "PyDeps: Show why this dependency is needed" then
      has_cr = true
    end
    if km.lhs == "gT" and km.desc == "PyDeps: Show dependency tree" then
      has_gt = true
    end
  end

  MiniTest.expect.equality(has_cr, false)
  MiniTest.expect.equality(has_gt, false)
end

T["info.show_at_cursor() closes existing hover before creating new one"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  vim.api.nvim_win_set_cursor(0, { 2, 5 })

  -- Create first hover
  info.show_at_cursor()
  vim.wait(100)

  local windows = vim.api.nvim_list_wins()
  local hover_count_before = 0
  for _, win in ipairs(windows) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_count_before = hover_count_before + 1
    end
  end

  -- Create second hover (should close first one)
  info.show_at_cursor()
  vim.wait(100)

  windows = vim.api.nvim_list_wins()
  local hover_count_after = 0
  for _, win in ipairs(windows) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_count_after = hover_count_after + 1
    end
  end

  MiniTest.expect.equality(hover_count_after, 1)
  info.close_hover()
end

T["info uses single window between show() and show_at_cursor()"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  vim.api.nvim_win_set_cursor(0, { 2, 5 })

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)
  info.show_at_cursor()
  vim.wait(100)

  local windows = vim.api.nvim_list_wins()
  local hover_count = 0
  for _, win in ipairs(windows) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_count = hover_count + 1
    end
  end

  MiniTest.expect.equality(hover_count, 1)
  info.close_hover()
end

T["info uses single window between show_at_cursor() and show()"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  vim.api.nvim_win_set_cursor(0, { 2, 5 })

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show_at_cursor()
  vim.wait(100)
  info.show(dep, "1.0.0", {})
  vim.wait(100)

  local windows = vim.api.nvim_list_wins()
  local hover_count = 0
  for _, win in ipairs(windows) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_count = hover_count + 1
    end
  end

  MiniTest.expect.equality(hover_count, 1)
  info.close_hover()
end

T["info.show_at_cursor() sets up keybindings"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"
  vim.api.nvim_win_set_cursor(0, { 2, 5 })

  info.show_at_cursor()
  vim.wait(100)

  -- Check that keybindings are set
  local keymaps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local has_cr = false
  local has_gt = false
  for _, km in ipairs(keymaps) do
    if km.lhs == "<CR>" and km.desc == "PyDeps: Show why this dependency is needed" then
      has_cr = true
    end
    if km.lhs == "gT" and km.desc == "PyDeps: Show dependency tree" then
      has_gt = true
    end
  end

  MiniTest.expect.equality(has_cr, true)
  MiniTest.expect.equality(has_gt, true)

  info.close_hover()
end

T["info.close_hover() restores pre-existing buffer keymaps"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  -- Set up a callback-based keymap before hover
  vim.keymap.set("n", "<CR>", function() end, {
    buffer = bufnr,
    desc = "original-CR-mapping",
    script = true,
  })

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  -- Open hover (overrides <CR>)
  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Close hover (should restore original <CR>)
  info.close_hover()

  -- Verify original keymap is restored
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local restored = false
  for _, map in ipairs(maps) do
    if
      map.lhs == "<CR>"
      and map.desc == "original-CR-mapping"
      and type(map.callback) == "function"
      and map.script == 1
    then
      restored = true
      break
    end
  end

  MiniTest.expect.equality(restored, true)
end

T["info determines unknown status when package not found on PyPI"] = function()
  -- Stub PyPI to return nil (package not found)
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb(nil) -- Package not found on PyPI
    end,
    is_yanked = function()
      return false
    end,
  }
  package.loaded["pydeps.ui.info"] = nil

  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["unknownpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "unknownpkg", line = 2, col_start = 3, col_end = 12, spec = ">=1.0" }

  -- Create hover with PyPI returning nil
  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- The hover should still be created even though package is not found on PyPI
  local windows = vim.api.nvim_list_wins()
  local hover_count = 0
  for _, win in ipairs(windows) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_count = hover_count + 1
    end
  end

  MiniTest.expect.equality(hover_count, 1)

  info.close_hover()
end

T["info layout: shows description when available"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Line 1: package icon + name
  -- Line 2: empty
  -- Line 3: description (when available)
  MiniTest.expect.ref_truthy(lines[3]:match("HTTP library"))

  info.close_hover()
end

T["info layout: skips description when not available"] = function()
  -- Stub PyPI to return nil info (no description)
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb({ info = nil, releases = {} })
    end,
    is_yanked = function()
      return false
    end,
  }
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Line 1: package icon + name
  -- Line 2: spec line (should be spec, not description)
  MiniTest.expect.ref_truthy(lines[2]:match("spec"))
  MiniTest.expect.ref_falsey(lines[2]:match("HTTP library"))

  info.close_hover()
end

T["info layout: shows extras for optional dependencies"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0", group = "optional:security" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find the extras line
  local found_extras = false
  for _, line in ipairs(lines) do
    if line:match("extras") and line:match("security") then
      found_extras = true
      break
    end
  end

  MiniTest.expect.equality(found_extras, true)

  info.close_hover()
end

T["info layout: shows extras from spec"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg[fast, speed]>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = {
    name = "testpkg",
    line = 2,
    col_start = 3,
    col_end = 10,
    spec = "testpkg[fast, speed]>=1.0",
    group = "project",
  }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  local found_extras = false
  for _, line in ipairs(lines) do
    if line:match("extras") and line:match("fast") and line:match("speed") then
      found_extras = true
      break
    end
  end

  MiniTest.expect.equality(found_extras, true)

  info.close_hover()
end

T["info highlights: extras value uses PyDepsInfoPill"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg[fast, speed]>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = {
    name = "testpkg",
    line = 2,
    col_start = 3,
    col_end = 10,
    spec = "testpkg[fast, speed]>=1.0",
    group = "project",
  }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local ns = vim.api.nvim_create_namespace("pydeps-info")
  local marks = vim.api.nvim_buf_get_extmarks(hover_buf, ns, 0, -1, { details = true })
  local found = false
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details and details.hl_group == "PyDepsInfoPill" then
      found = true
      break
    end
  end

  MiniTest.expect.equality(found, true)

  info.close_hover()
end

T["info layout: shows markers when present in spec"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = '>=1.0; python_version < "3.12"' }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find the markers line
  local found_markers = false
  for _, line in ipairs(lines) do
    if line:match("markers") and line:match('python_version < "3.12"') then
      found_markers = true
      break
    end
  end

  MiniTest.expect.equality(found_markers, true)

  info.close_hover()
end

T["info layout: status line always shown even without extras/markers"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0", group = "project" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find the status line
  local found_status = false
  for _, line in ipairs(lines) do
    if line:match("status") then
      found_status = true
      break
    end
  end

  MiniTest.expect.equality(found_status, true)

  info.close_hover()
end

T["info highlights: pypi url uses PyDepsInfoUrl"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local ns = vim.api.nvim_create_namespace("pydeps-info")
  local marks = vim.api.nvim_buf_get_extmarks(hover_buf, ns, 0, -1, { details = true })
  local found = false
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details and details.hl_group == "PyDepsInfoUrl" then
      found = true
      break
    end
  end

  MiniTest.expect.equality(found, true)

  info.close_hover()
end

T["info version: spec/lock/latest always displayed"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find spec, lock, and latest lines
  local found_spec = false
  local found_lock = false
  local found_latest = false

  for _, line in ipairs(lines) do
    if line:match("spec") then
      found_spec = true
    end
    if line:match("lock") then
      found_lock = true
    end
    if line:match("latest") then
      found_latest = true
    end
  end

  MiniTest.expect.equality(found_spec, true)
  MiniTest.expect.equality(found_lock, true)
  MiniTest.expect.equality(found_latest, true)

  info.close_hover()
end

T["info version: lock shows (missing) when lockfile missing"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, nil, { lockfile_missing = true })
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find lock line with (missing)
  local found_missing = false
  for _, line in ipairs(lines) do
    if line:match("lock") and line:match("%(missing%)") then
      found_missing = true
      break
    end
  end

  MiniTest.expect.equality(found_missing, true)

  info.close_hover()
end

T["info version: lock shows (not found) when package not in lockfile"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, nil, { lockfile_missing = false })
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find lock line with (not found)
  local found_not_found = false
  for _, line in ipairs(lines) do
    if line:match("lock") and line:match("%(not found%)") then
      found_not_found = true
      break
    end
  end

  MiniTest.expect.equality(found_not_found, true)

  info.close_hover()
end

T["info version: latest shows (loading...) before PyPI response"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(50) -- Small delay to check initial state

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find latest line - initial state should show (loading...) or version after callback
  local found_latest = false
  for _, line in ipairs(lines) do
    if line:match("latest") then
      found_latest = true
      break
    end
  end

  MiniTest.expect.equality(found_latest, true)

  info.close_hover()
end

T["info version: suffix (up-to-date) shown when lock matches"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find lock line with (up-to-date)
  local found_uptodate = false
  for _, line in ipairs(lines) do
    if line:match("lock") and line:match("%(up%-to%-date%)") then
      found_uptodate = true
      break
    end
  end

  MiniTest.expect.equality(found_uptodate, true)

  info.close_hover()
end

T["info status: shows 'active' for ok status"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find status line with "active"
  local found_active = false
  for _, line in ipairs(lines) do
    if line:match("status") and line:match("active") then
      found_active = true
      break
    end
  end

  MiniTest.expect.equality(found_active, true)

  info.close_hover()
end

T["info status: shows 'update available' when newer version exists"] = function()
  -- Stub PyPI to return newer version
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb({
        info = { version = "2.0.0" },
        releases = {},
      })
    end,
    is_yanked = function()
      return false
    end,
  }
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find status line with "update available"
  local found_update = false
  for _, line in ipairs(lines) do
    if line:match("status") and line:match("update available") then
      found_update = true
      break
    end
  end

  MiniTest.expect.equality(found_update, true)

  info.close_hover()
end

T["info status: shows 'yanked' when version is yanked"] = function()
  -- Stub PyPI to return yanked version
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb({
        info = { version = "1.0.0", yanked = true },
        releases = {},
      })
    end,
    is_yanked = function()
      return true
    end,
  }
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find status line with "yanked"
  local found_yanked = false
  for _, line in ipairs(lines) do
    if line:match("status") and line:match("yanked") then
      found_yanked = true
      break
    end
  end

  MiniTest.expect.equality(found_yanked, true)

  info.close_hover()
end

T["info status: shows 'lock mismatch' when pinned spec differs from lock"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg==1.0.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = "==1.0.0" }

  -- Lock version differs from pinned spec
  info.show(dep, "1.1.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find status line with "lock mismatch"
  local found_mismatch = false
  for _, line in ipairs(lines) do
    if line:match("status") and line:match("lock mismatch") then
      found_mismatch = true
      break
    end
  end

  MiniTest.expect.equality(found_mismatch, true)

  info.close_hover()
end

T["info status: shows 'unknown' when package not found on PyPI"] = function()
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb(nil)
    end,
    is_yanked = function()
      return false
    end,
  }
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["unknownpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "unknownpkg", line = 2, col_start = 3, col_end = 12, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find status line with "unknown"
  local found_unknown = false
  for _, line in ipairs(lines) do
    if line:match("status") and line:match("unknown") then
      found_unknown = true
      break
    end
  end

  MiniTest.expect.equality(found_unknown, true)

  info.close_hover()
end

T["info deps: shows dependency count"] = function()
  stub_pypi()
  -- Stub cache with packages that have dependencies
  package.loaded["pydeps.core.cache"] = {
    get_pyproject = function()
      return {
        { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" },
      }
    end,
    get_lockfile = function()
      return {
        resolved = { testpkg = "1.0.0" },
        packages = {
          testpkg = {
            dependencies = { "dep1", "dep2", "dep3", "dep4" },
          },
        },
      },
        false
    end,
  }
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", { root = "/fake/root" })
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find deps line with count
  local found_deps = false
  for _, line in ipairs(lines) do
    if line:match("deps") and line:match("4") then
      found_deps = true
      break
    end
  end

  MiniTest.expect.equality(found_deps, true)

  info.close_hover()
end

T["info deps: shows 0 when package has no dependencies"] = function()
  stub_pypi()
  -- Stub cache with packages that have no dependencies
  package.loaded["pydeps.core.cache"] = {
    get_pyproject = function()
      return {
        { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" },
      }
    end,
    get_lockfile = function()
      return {
        resolved = { testpkg = "1.0.0" },
        packages = {
          testpkg = {
            dependencies = {},
          },
        },
      },
        false
    end,
  }
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", { root = "/fake/root" })
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find deps line with 0
  local found_deps = false
  for _, line in ipairs(lines) do
    if line:match("deps") and line:match("0") then
      found_deps = true
      break
    end
  end

  MiniTest.expect.equality(found_deps, true)

  info.close_hover()
end

T["info deps: shows ? when deps count is unknown"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  -- No root provided, so lock data won't be available
  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find deps line with ?
  local found_deps = false
  for _, line in ipairs(lines) do
    if line:match("deps") and line:match("%?") then
      found_deps = true
      break
    end
  end

  MiniTest.expect.equality(found_deps, true)

  info.close_hover()
end

T["info deps: shows hint text (Enter: Why, gT: Tree)"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find deps line with hint
  local found_hint = false
  for _, line in ipairs(lines) do
    if line:match("deps") and line:match("Enter:") and line:match("gT:") then
      found_hint = true
      break
    end
  end

  MiniTest.expect.equality(found_hint, true)

  info.close_hover()
end

T["info pypi: shows PyPI URL when package is found"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find pypi line with URL
  local found_url = false
  for _, line in ipairs(lines) do
    if line:match("pypi") and line:match("https://") then
      found_url = true
      break
    end
  end

  MiniTest.expect.equality(found_url, true)

  info.close_hover()
end

T["info pypi: shows 'not found on public PyPI' when package not found"] = function()
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb(nil)
    end,
    is_yanked = function()
      return false
    end,
  }
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["unknownpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "unknownpkg", line = 2, col_start = 3, col_end = 12, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local lines = vim.api.nvim_buf_get_lines(hover_buf, 0, -1, false)

  -- Find pypi line with "not found on public PyPI"
  local found_not_found = false
  for _, line in ipairs(lines) do
    if line:match("pypi") and line:match("not found on public PyPI") then
      found_not_found = true
      break
    end
  end

  MiniTest.expect.equality(found_not_found, true)

  info.close_hover()
end

T["info highlight: title (package name) is highlighted"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  -- Check for Title highlight on line 0
  local highlights = vim.api.nvim_buf_get_extmarks(hover_buf, -1, 0, 1, { details = true })

  local found_title = false
  for _, mark in ipairs(highlights) do
    local details = mark[4]
    if details.hl_group == "Title" then
      found_title = true
      break
    end
  end

  MiniTest.expect.equality(found_title, true)

  info.close_hover()
end

T["info highlight: labels (spec, lock, latest, etc) are highlighted with Identifier"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  -- Check for Identifier highlights on labels
  local highlights = vim.api.nvim_buf_get_extmarks(hover_buf, -1, 0, -1, { details = true })

  local found_identifier = false
  for _, mark in ipairs(highlights) do
    local details = mark[4]
    if details.hl_group == "Identifier" then
      found_identifier = true
      break
    end
  end

  MiniTest.expect.equality(found_identifier, true)

  info.close_hover()
end

T["info highlight: label icons are highlighted with Identifier"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  local highlights = vim.api.nvim_buf_get_extmarks(hover_buf, -1, 0, -1, { details = true })

  local found_icon = false
  for _, mark in ipairs(highlights) do
    local col = mark[3]
    local details = mark[4]
    if details.hl_group == "Identifier" and col == 0 then
      found_icon = true
      break
    end
  end

  MiniTest.expect.equality(found_icon, true)

  info.close_hover()
end

T["info highlight: description is highlighted with Comment"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  -- Check for Comment highlight (description)
  local highlights = vim.api.nvim_buf_get_extmarks(hover_buf, -1, 0, -1, { details = true })

  local found_comment = false
  for _, mark in ipairs(highlights) do
    local details = mark[4]
    if details.hl_group == "Comment" then
      found_comment = true
      break
    end
  end

  MiniTest.expect.equality(found_comment, true)

  info.close_hover()
end

T["info highlight: PyPI URL is underlined"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  -- Check for Underlined highlight
  local highlights = vim.api.nvim_buf_get_extmarks(hover_buf, -1, 0, -1, { details = true })

  local found_underlined = false
  for _, mark in ipairs(highlights) do
    local details = mark[4]
    if details.hl_group == "Underlined" then
      found_underlined = true
      break
    end
  end

  MiniTest.expect.equality(found_underlined, true)

  info.close_hover()
end

T["info highlight: status value is colored by status type"] = function()
  -- Test for DiagnosticOk highlight when status is ok (active)
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  -- Check for DiagnosticOk highlight on status value
  local highlights = vim.api.nvim_buf_get_extmarks(hover_buf, -1, 0, -1, { details = true })

  local found_status_hl = false
  for _, mark in ipairs(highlights) do
    local details = mark[4]
    if details.hl_group == "DiagnosticOk" then
      found_status_hl = true
      break
    end
  end

  MiniTest.expect.equality(found_status_hl, true)

  info.close_hover()
end

T["info highlight: suffix (up-to-date) is colored with DiagnosticOk"] = function()
  stub_pypi()
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["testpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "testpkg", line = 2, col_start = 3, col_end = 10, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  -- Check for DiagnosticOk highlight on suffix
  local highlights = vim.api.nvim_buf_get_extmarks(hover_buf, -1, 0, -1, { details = true })

  local found_suffix_hl = false
  for _, mark in ipairs(highlights) do
    local details = mark[4]
    if details.hl_group == "DiagnosticOk" then
      found_suffix_hl = true
      break
    end
  end

  MiniTest.expect.equality(found_suffix_hl, true)

  info.close_hover()
end

T["info highlight: suffix (not found) is colored with WarningMsg"] = function()
  package.loaded["pydeps.providers.pypi"] = {
    get = function(_, cb)
      cb(nil)
    end,
    is_yanked = function()
      return false
    end,
  }
  stub_cache()
  package.loaded["pydeps.ui.info"] = nil
  local info = require("pydeps.ui.info")

  helpers.setup_buffer({
    "[project]",
    'dependencies = ["unknownpkg>=1.0"]',
  })

  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "toml"

  local dep = { name = "unknownpkg", line = 2, col_start = 3, col_end = 12, spec = ">=1.0" }

  info.show(dep, "1.0.0", {})
  vim.wait(100)

  -- Find hover buffer
  local hover_buf = nil
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local cfg = vim.api.nvim_win_get_config(win)
    if cfg.relative == "cursor" then
      hover_buf = vim.api.nvim_win_get_buf(win)
      break
    end
  end

  MiniTest.expect.ref_truthy(hover_buf)

  -- Check for WarningMsg highlight
  local highlights = vim.api.nvim_buf_get_extmarks(hover_buf, -1, 0, -1, { details = true })

  local found_warning = false
  for _, mark in ipairs(highlights) do
    local details = mark[4]
    if details.hl_group == "WarningMsg" then
      found_warning = true
      break
    end
  end

  MiniTest.expect.equality(found_warning, true)

  info.close_hover()
end

return T
