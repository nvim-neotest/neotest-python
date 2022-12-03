local async = require("neotest.async")
local lib = require("neotest.lib")
local Path = require("plenary.path")
local TOML = require("neotest-python.toml")
local util = require("lspconfig.util")

local M = {}

function M.is_test_file(file_path)
  if not vim.endswith(file_path, ".py") then
    return false
  end
  local elems = vim.split(file_path, Path.path.sep)
  local file_name = elems[#elems]
  return vim.startswith(file_name, "test_") or vim.endswith(file_name, "_test.py")
end

M.module_exists = function(module, python_command)
  return lib.process.run(vim.tbl_flatten({
    python_command,
    "-c",
    "import imp; imp.find_module('" .. module .. "')",
  })) == 0
end

local python_command_mem = {}

---@return string[]
function M.get_python_command(root)
  if python_command_mem[root] then
    return python_command_mem[root]
  end
  -- Use activated virtualenv.
  if vim.env.VIRTUAL_ENV then
    python_command_mem[root] = { Path:new(vim.env.VIRTUAL_ENV, "bin", "python").filename }
    return python_command_mem[root]
  end

  for _, pattern in ipairs({ "*", ".*" }) do
    local match = async.fn.glob(Path:new(root or async.fn.getcwd(), pattern, "pyvenv.cfg").filename)
    if match ~= "" then
      python_command_mem[root] = { (Path:new(match):parent() / "bin" / "python").filename }
      return python_command_mem[root]
    end
  end

  if lib.files.exists("Pipfile") then
    local success, exit_code, data = pcall(lib.process.run, { "pipenv", "--py" }, { stdout = true })
    if success and exit_code == 0 then
      local venv = data.stdout:gsub("\n", "")
      if venv then
        python_command_mem[root] = { Path:new(venv).filename }
        return python_command_mem[root]
      end
    end
  end

  if lib.files.exists("pyproject.toml") then
    local success, exit_code, data = pcall(
      lib.process.run,
      { "poetry", "env", "info", "-p" },
      { stdout = true }
    )
    if success and exit_code == 0 then
      local venv = data.stdout:gsub("\n", "")
      if venv then
        python_command_mem[root] = { Path:new(venv, "bin", "python").filename }
        return python_command_mem[root]
      end
    end
  end

  -- Fallback to system Python.
  python_command_mem[root] = {
    async.fn.exepath("python3") or async.fn.exepath("python") or "python",
  }
  return python_command_mem[root]
end

local function extend(lhs, rhs)
    for _, v in pairs(rhs) do
        table.insert(lhs, v)
    end
    return lhs
end

---@return string
local function assemble_python_path(root, extra_paths)
    local env = ""
    local sep = ""
    for _, extra_path in pairs(extra_paths) do
        env = env .. sep .. Path:new(root, extra_path).filename
        sep = ":"
    end
    return env
end

---@return string
local function get_python_path(pyproject_root, pyproject , fname)
  local tool = pyproject.tool
  if not tool then return "" end
  local pyright = tool.pyright
  if not pyright then return "" end
  local execution_environments = pyright.executionEnvironments
  if not execution_environments then return "" end

  for _, environment in pairs(execution_environments) do
    local environment_root = Path:new(pyproject_root, environment.root)
    if Path:new(fname):make_relative(environment_root.filename) ~= fname then
      local extra_paths = { environment.root }
      if environment.extraPaths then
        extra_paths = extend(extra_paths, environment.extraPaths)
      end
      return assemble_python_path(pyproject_root, extra_paths)
    end
  end
  return ""
end

local function find_pyproject_root(fname)
  local is_pyproject = function(path)
      return Path:new(path, "pyproject.toml"):exists()
  end
  return util.search_ancestors(fname, is_pyproject)
end

---@return string
function M.get_python_path(fname)
  local pyproject_root = find_pyproject_root(fname)
  if pyproject_root then
    io.input(Path:new(pyproject_root, "pyproject.toml").filename)
    local pyproject = TOML.parse(io.read("*all"))
    return get_python_path(pyproject_root, pyproject, fname)
  end
  return ""
end

return M
