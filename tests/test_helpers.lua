local M = {}

---@return nil
function M.close_extra_windows()
  local wins = vim.api.nvim_list_wins()
  for i = #wins, 2, -1 do
    vim.api.nvim_win_close(wins[i], true)
  end
end

---@return table
function M.create_test_set()
  local MiniTest = require("mini.test")
  return MiniTest.new_set({
    hooks = {
      pre_case = function()
        M.close_extra_windows()
        vim.cmd("enew!")
        require("pydeps").setup({
          auto_refresh = false,
          show_virtual_text = true,
          show_missing_virtual_text = false,
          notify_on_missing_lockfile = false,
        })
      end,
    },
  })
end

---@param lines string[]
function M.setup_buffer(lines)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end

---@param lines string[]
---@param suffix string|nil
---@return string
function M.write_temp_file(lines, suffix)
  local name = vim.fn.tempname()
  if suffix then
    name = name .. suffix
  end
  vim.fn.writefile(lines, name)
  return name
end

---@param path string
function M.cleanup_temp_file(path)
  if path and path ~= "" then
    vim.fn.delete(path)
  end
end

---@param dir string
---@param packages? table<string, string> -- package name -> version mapping
function M.create_uv_lock(dir, packages)
  packages = packages
    or {
      requests = "2.31.0",
      rich = "13.7.0",
      ["charset-normalizer"] = "3.3.2",
      idna = "3.6",
    }

  local lines = { "version = 1", "", "[metadata]", "requires-dist = []", "" }
  for name, version in pairs(packages) do
    vim.list_extend(lines, {
      "[[package]]",
      'name = "' .. name .. '"',
      'version = "' .. version .. '"',
      "",
    })
  end

  local lock_path = dir .. "/uv.lock"
  vim.fn.writefile(lines, lock_path)
end

return M
