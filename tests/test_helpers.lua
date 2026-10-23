local M = {}

---@type fun()[]
local restores = {}

--- Replace `tbl[key]` until the current case finishes, even when it fails.
---@param tbl table
---@param key any
---@param value any
function M.stub(tbl, key, value)
  local original = tbl[key]
  tbl[key] = value
  table.insert(restores, function()
    tbl[key] = original
  end)
end

---@param name string
---@param value any
function M.stub_module(name, value)
  M.stub(package.loaded, name, value)
end

--- Register cleanup that runs after the current case, even when it fails.
---@param fn fun()
function M.defer(fn)
  table.insert(restores, fn)
end

---@return nil
function M.restore_all()
  local pending = restores
  restores = {}
  local first_err
  for i = #pending, 1, -1 do
    local ok, err = pcall(pending[i])
    if not ok and not first_err then
      first_err = err
    end
  end
  if first_err then
    error(first_err, 0)
  end
end

--- Wait until `cond` holds and fail the case with `msg` otherwise.
---@param cond fun(): boolean
---@param msg string
---@param timeout_ms? integer
function M.wait_for(cond, msg, timeout_ms)
  if not vim.wait(timeout_ms or 2000, cond, 5) then
    error("timed out waiting for " .. msg, 2)
  end
end

--- Let pending timers and scheduled callbacks run for `ms` milliseconds.
---@param ms integer
function M.drain(ms)
  vim.wait(ms, function()
    return false
  end, 5)
end

---@return nil
function M.wipe_other_buffers()
  local current = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= current and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---@return nil
function M.close_extra_windows()
  local wins = vim.api.nvim_list_wins()
  for i = #wins, 2, -1 do
    vim.api.nvim_win_close(wins[i], true)
  end
end

--- MiniTest set whose `post_case` always undoes `stub`/`defer` registrations
--- and drops buffers and windows left behind by the case.
---@param opts? table
---@return table
function M.new_set(opts)
  opts = opts or {}
  local hooks = opts.hooks or {}
  local post_case = hooks.post_case
  hooks.post_case = function()
    local first_err
    -- Run every cleanup step even when an earlier one fails.
    for _, step in ipairs({
      post_case or function() end,
      M.restore_all,
      M.close_extra_windows,
      function()
        vim.cmd("enew!")
      end,
      M.wipe_other_buffers,
    }) do
      local ok, err = pcall(step)
      if not ok and not first_err then
        first_err = err
      end
    end
    if first_err then
      error(first_err, 0)
    end
  end
  opts.hooks = hooks
  return require("mini.test").new_set(opts)
end

---@return table
function M.create_test_set()
  return M.new_set({
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
