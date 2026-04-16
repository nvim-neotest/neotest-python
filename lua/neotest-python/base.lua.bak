local nio = require("nio")
local lib = require("neotest.lib")
local Path = require("plenary.path")

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
  return lib.process.run(vim
    .iter({
      python_command,
      "-c",
      "import " .. module,
    })
    :flatten()
    :totable()) == 0
end

local python_command_mem = {}
local venv_bin = vim.loop.os_uname().sysname:match("Windows") and "Scripts" or "bin"

---@return string[]
function M.get_python_command(root)
  root = root or vim.loop.cwd()
  if python_command_mem[root] then
    return python_command_mem[root]
  end
  -- Use activated virtualenv.
  if vim.env.VIRTUAL_ENV then
    python_command_mem[root] = { Path:new(vim.env.VIRTUAL_ENV, venv_bin, "python").filename }
    return python_command_mem[root]
  end

  for _, pattern in ipairs({ "*", ".*" }) do
    local match = nio.fn.glob(Path:new(root or nio.fn.getcwd(), pattern, "pyvenv.cfg").filename)
    if match ~= "" then
      python_command_mem[root] = { (Path:new(match):parent() / venv_bin / "python").filename }
      return python_command_mem[root]
    end
  end

  if lib.files.exists("Pipfile") then
    local success, exit_code, data = pcall(lib.process.run, { "pipenv", "--py" }, { stdout = true })
    if success and exit_code == 0 then
      local venv = data.stdout:gsub("\r?\n", "")
      if venv then
        python_command_mem[root] = { Path:new(venv).filename }
        return python_command_mem[root]
      end
    end
  end

  if lib.files.exists("pyproject.toml") then
    local success, exit_code, data = pcall(
      lib.process.run,
      { "poetry", "run", "poetry", "env", "info", "-p" },
      { stdout = true }
    )
    if success and exit_code == 0 then
      local venv = data.stdout:gsub("\r?\n", "")
      if venv then
        python_command_mem[root] = { Path:new(venv, venv_bin, "python").filename }
        return python_command_mem[root]
      end
    end
  end

  if lib.files.exists("uv.lock") then
    local success, exit_code, data = pcall(
      lib.process.run,
      { "uv", "run", "python", "-c", "import sys; print(sys.executable)" },
      { stdout = true }
    )
    if success and exit_code == 0 then
      python_command_mem[root] = { Path:new(data).filename }
      return python_command_mem[root]
    end
  end

  -- Fallback to system Python.
  python_command_mem[root] = {
    nio.fn.exepath("python3") or nio.fn.exepath("python") or "python",
  }
  return python_command_mem[root]
end

---@return string
function M.get_script_path()
  local paths = vim.api.nvim_get_runtime_file("neotest.py", true)
  for _, path in ipairs(paths) do
    if vim.endswith(path, ("neotest-python%sneotest.py"):format(lib.files.sep)) then
      return path
    end
  end

  error("neotest.py not found")
end

---@param python_command string[]
---@param config neotest-python._AdapterConfig
---@param runner string
---@return string
local function scan_test_function_pattern(runner, config, python_command)
  local test_function_pattern = "^test"
  if runner == "pytest" and config.pytest_discovery then
    local cmd = vim.tbl_flatten({ python_command, M.get_script_path(), "--pytest-extract-test-name-template" })
    local _, data = lib.process.run(cmd, { stdout = true, stderr = true })

    for line in vim.gsplit(data.stdout, "\n", true) do
      if string.sub(line, 1, 1) == "{" and string.find(line, "python_functions") ~= nil then
        local pytest_option = vim.json.decode(line)
        test_function_pattern = pytest_option.python_functions
      end
    end
  end
  return test_function_pattern
end

---@param python_command string[]
---@param config neotest-python._AdapterConfig
---@param runner string
---@return string
M.treesitter_queries = function(runner, config, python_command)
  local test_function_pattern = scan_test_function_pattern(runner, config, python_command)
  return string.format([[
    ;; Match undecorated functions
    ((function_definition
      name: (identifier) @test.name)
      (#match? @test.name "%s"))
      @test.definition

    ;; Match decorated function, including decorators in definition
    (decorated_definition
      ((function_definition
        name: (identifier) @test.name)
        (#match? @test.name "%s")))
        @test.definition

    ;; Match decorated classes, including decorators in definition
    (decorated_definition
      (class_definition
       name: (identifier) @namespace.name))
      @namespace.definition

    ;; Match undecorated classes: namespaces nest so #not-has-parent is used
    ;; to ensure each namespace is annotated only once
    (
     (class_definition
      name: (identifier) @namespace.name)
      @namespace.definition
     (#not-has-parent? @namespace.definition decorated_definition)
    )
  ]], test_function_pattern, test_function_pattern)
end

M.get_root =
  lib.files.match_root_pattern("pyproject.toml", "setup.cfg", "mypy.ini", "pytest.ini", "setup.py")

function M.create_dap_config(python_path, script_path, script_args, dap_args)
  return vim.tbl_extend("keep", {
    type = "python",
    name = "Neotest Debugger",
    request = "launch",
    python = python_path,
    program = script_path,
    cwd = nio.fn.getcwd(),
    args = script_args,
  }, dap_args or {})
end

local stored_runners = {}

function M.get_runner(python_path)
  local command_str = table.concat(python_path, " ")
  if stored_runners[command_str] then
    return stored_runners[command_str]
  end
  local vim_test_runner = vim.g["test#python#runner"]
  if vim_test_runner == "pyunit" then
    return "unittest"
  end
  if
    vim_test_runner and lib.func_util.index({ "unittest", "pytest", "django" }, vim_test_runner)
  then
    return vim_test_runner
  end
  local runner = M.module_exists("pytest", python_path) and "pytest"
    or M.module_exists("django", python_path) and "django"
    or "unittest"
  stored_runners[command_str] = runner
  return runner
end

return M
