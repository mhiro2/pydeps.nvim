local M = {}

-- Each file runs in its own Neovim so stubs, autocmds, timers and module
-- state cannot leak from one suite into another.
local FILE_TIMEOUT_MS = 120000
local KILL_GRACE_MS = 5000

---@return string[]
local function collect_files()
  local files = vim.fn.globpath("tests", "test_*.lua", false, true)
  local filter = vim.env.TEST_FILE
  local filtered = {}
  for _, file in ipairs(files) do
    if not file:match("test_helpers%.lua$") and (not filter or filter == "" or file:find(filter, 1, true)) then
      table.insert(filtered, file)
    end
  end
  table.sort(filtered)
  return filtered
end

---@return integer
local function max_parallel()
  local requested = tonumber(vim.env.TEST_JOBS or "")
  if requested and requested >= 1 then
    return math.floor(requested)
  end
  return math.max(1, math.min(8, vim.uv.available_parallelism()))
end

---@param file string
---@return string[]
local function child_cmd(file)
  return {
    vim.v.progpath,
    "--headless",
    "-i",
    "NONE",
    "-u",
    "tests/minimal_init.lua",
    "-c",
    string.format("lua require('tests.run').run_file(%q)", file),
  }
end

---@param file string
function M.run_file(file)
  require("mini.test").run_file(file, {
    execute = { reporter = require("mini.test").gen_reporter.stdout({ group_depth = 1 }) },
  })
end

---@return nil
function M.run()
  local files = collect_files()
  if #files == 0 then
    io.write("No test files matched\n")
    vim.cmd("cquit 1")
    return
  end

  local results = {}
  local next_index = 1
  local running = 0
  local finished = 0

  local function start_next()
    while running < max_parallel() and next_index <= #files do
      local index = next_index
      local file = files[index]
      next_index = next_index + 1
      running = running + 1
      local proc = vim.system(child_cmd(file), { text = true, timeout = FILE_TIMEOUT_MS }, function(out)
        results[index] = { file = file, out = out }
        running = running - 1
        finished = finished + 1
        vim.schedule(start_next)
      end)
      -- The timeout only sends SIGTERM; make sure a wedged child frees its slot.
      vim.defer_fn(function()
        if not results[index] then
          proc:kill("sigkill")
        end
      end, FILE_TIMEOUT_MS + KILL_GRACE_MS)
    end
  end

  start_next()
  vim.wait((FILE_TIMEOUT_MS + KILL_GRACE_MS) * #files, function()
    return finished == #files
  end, 50)

  local failed = {}
  for index, file in ipairs(files) do
    local result = results[index]
    local out = result and result.out
    if out then
      io.write(out.stdout or "")
      if out.stderr and out.stderr ~= "" then
        io.write(out.stderr)
      end
    end
    if not out or out.code ~= 0 or out.signal ~= 0 then
      local reason = not out and "did not finish"
        or (out.signal ~= 0 and ("killed by signal " .. out.signal) or ("exit code " .. out.code))
      table.insert(failed, string.format("%s (%s)", file, reason))
    end
  end

  io.write(string.format("\n%d files, %d failed\n", #files, #failed))
  for _, line in ipairs(failed) do
    io.write("  FAILED " .. line .. "\n")
  end
  vim.cmd(#failed > 0 and "cquit 1" or "qall!")
end

return M
