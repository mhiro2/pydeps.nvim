local M = {}

---@type table<integer, true>
local active = {}

---@type boolean
local stopping = false

---@param job_id integer
---@return integer
function M.track(job_id)
  if type(job_id) ~= "number" or job_id <= 0 then
    return job_id
  end
  if stopping then
    -- Neovim is exiting; do not let new jobs slip in via rate-limiter
    -- callbacks that fire after stop_all().
    pcall(vim.fn.jobstop, job_id)
    return job_id
  end
  active[job_id] = true
  return job_id
end

---@param job_id integer
function M.untrack(job_id)
  if type(job_id) == "number" then
    active[job_id] = nil
  end
end

---@return boolean
function M.is_stopping()
  return stopping
end

---Stop every tracked job. Used on VimLeavePre so :q doesn't have to wait
---for the OS to reap child processes spawned by pydeps. After this returns,
---is_stopping() stays true so any deferred callback that tries to spawn a
---new job is suppressed.
function M.stop_all()
  stopping = true
  for job_id in pairs(active) do
    pcall(vim.fn.jobstop, job_id)
  end
  -- Do not clear `active` here; on_exit will untrack each job naturally.
end

---Reset state. Intended for tests only.
---@private
function M._reset()
  active = {}
  stopping = false
end

return M
