local M = {}

local uv = vim.uv

---@param cmd string[]
---@return string|nil output, boolean success
local function run_command(cmd)
  local result = vim.fn.system(cmd)
  local ok = vim.v.shell_error == 0

  if ok and result and result ~= "" then
    return result, true
  end
  return nil, false
end

---@return nil
function M.check()
  vim.health.start("pydeps.nvim")

  -- Check Neovim version
  local nvim_version = vim.version()
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok(string.format("Neovim version: %d.%d.%d", nvim_version.major, nvim_version.minor, nvim_version.patch))
  else
    vim.health.error(
      string.format(
        "Neovim version: %d.%d.%d (expected >= 0.10.0)",
        nvim_version.major,
        nvim_version.minor,
        nvim_version.patch
      )
    )
  end

  -- Check uv
  if vim.fn.executable("uv") == 1 then
    local uv_version, ok = run_command({ "uv", "--version" })
    if ok then
      vim.health.ok("uv: " .. uv_version:gsub("\n", ""))
    else
      vim.health.error("uv: failed to get version")
    end
  else
    vim.health.error("uv: not found in PATH", {
      "Install uv from https://docs.astral.sh/uv/",
      "uv is required for :PyDepsResolve and :PyDepsTree commands",
    })
  end

  -- Check Python
  local python_cmd = nil
  if vim.fn.executable("python3") == 1 then
    python_cmd = "python3"
  elseif vim.fn.executable("python") == 1 then
    python_cmd = "python"
  end

  if python_cmd then
    local python_version, ok = run_command({ python_cmd, "--version" })
    if ok then
      vim.health.ok("Python: " .. python_version:gsub("\n", ""))
    else
      vim.health.warn("Python: failed to get version")
    end
  else
    vim.health.warn("Python: not found in PATH", {
      "Python is optional but recommended for environment detection",
    })
  end

  -- Check curl for PyPI features
  if vim.fn.executable("curl") == 1 then
    local curl_version, ok = run_command({ "curl", "--version" })
    if ok then
      vim.health.ok("curl: " .. curl_version:match("[^\n]+"))
    else
      vim.health.warn("curl: failed to get version")
    end
  elseif python_cmd then
    vim.health.ok("curl: not found, but Python urllib will be used for PyPI features")
  else
    vim.health.warn("curl: not found", {
      "curl or Python is required for PyPI features (completion, version info, yanked detection)",
    })
  end

  -- Check nvim-treesitter and toml parser (required)
  local has_treesitter = pcall(require, "nvim-treesitter.parsers")
  if has_treesitter then
    local parsers = require("nvim-treesitter.parsers")
    if parsers.has_parser("toml") then
      vim.health.ok("nvim-treesitter: toml parser installed")
    else
      vim.health.error("nvim-treesitter: toml parser not installed", {
        "Install toml parser with :TSInstall toml",
        "pydeps.nvim requires the toml parser for accurate inline badge alignment and comment-aware positioning",
      })
    end
  else
    vim.health.error("nvim-treesitter: not installed", {
      "Install nvim-treesitter with the toml parser",
      "pydeps.nvim requires Tree-sitter for accurate inline badge alignment and comment-aware positioning",
    })
  end

  -- Check for pyproject.toml in current directory
  local cwd = uv.cwd()
  local pyproject_path = vim.fs.joinpath(cwd, "pyproject.toml")
  if vim.fn.filereadable(pyproject_path) == 1 then
    vim.health.ok("pyproject.toml: found in " .. cwd)
  else
    vim.health.info("pyproject.toml: not found in current directory", {
      "Open a pyproject.toml file to enable pydeps features",
    })
  end

  -- Check for uv.lock
  local lock_path = vim.fs.joinpath(cwd, "uv.lock")
  if vim.fn.filereadable(lock_path) == 1 then
    vim.health.ok("uv.lock: found in " .. cwd)
  else
    vim.health.info("uv.lock: not found in current directory", {
      "Run :PyDepsResolve to generate uv.lock",
    })
  end

  -- Check completion sources
  local config = require("pydeps.config")
  if config.options.enable_completion then
    local has_cmp = pcall(require, "cmp")
    local has_blink = pcall(require, "blink.cmp")
    if has_cmp then
      vim.health.ok("Completion: nvim-cmp detected")
    elseif has_blink then
      vim.health.ok("Completion: blink.cmp detected")
    else
      vim.health.info("Completion: no completion plugin detected", {
        "Install nvim-cmp or blink.cmp for completion support",
      })
    end
  else
    vim.health.info("Completion: disabled in config")
  end

  -- Check configuration
  vim.health.info("Configuration:")
  vim.health.info("  show_virtual_text: " .. tostring(config.options.show_virtual_text))
  vim.health.info("  enable_diagnostics: " .. tostring(config.options.enable_diagnostics))
  vim.health.info("  auto_refresh: " .. tostring(config.options.auto_refresh))
  vim.health.info("  refresh_debounce_ms: " .. tostring(config.options.refresh_debounce_ms))
end

return M
