local nio = require("nio")
local lib = require("neotest.lib")
local Path = require("plenary.path")

local M = {}
local script_path_mem

---@param mappings { forward: table<string, string>, forward_keys?: string[] }|table<string, string>|nil
---@return { localRoot: string, remoteRoot: string }[]
function M.get_dap_path_mappings(mappings)
  local forward = mappings and mappings.forward or mappings or {}
  local keys = mappings and mappings.forward_keys or {}
  local path_mappings = {}

  if vim.tbl_isempty(keys) then
    for local_root in pairs(forward) do
      table.insert(keys, local_root)
    end
    table.sort(keys, function(a, b)
      return #a > #b
    end)
  end

  for _, local_root in ipairs(keys) do
    path_mappings[#path_mappings + 1] = {
      localRoot = local_root,
      remoteRoot = forward[local_root],
    }
  end

  return path_mappings
end

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
  if script_path_mem then
    return script_path_mem
  end

  local paths = vim.api.nvim_get_runtime_file("neotest.py", true)
  for _, path in ipairs(paths) do
    if vim.endswith(path, ("neotest-python%sneotest.py"):format(lib.files.sep)) then
      script_path_mem = path
      return script_path_mem
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

function M.create_dap_config(python_path, script_path, script_args, cwd, env, dap_args, context)
  local default_config = {
    type = "python",
    name = "Neotest Debugger",
    request = "launch",
    python = python_path,
    program = script_path,
    cwd = cwd or nio.fn.getcwd(),
    env = env,
    args = script_args,
  }

  local dap_config = default_config
  if type(dap_args) == "function" then
    local override = dap_args(context.root, context.position, vim.deepcopy(default_config), context)
    if override then
      dap_config = vim.tbl_deep_extend("force", default_config, override)
    end
  elseif dap_args then
    dap_config = vim.tbl_deep_extend("force", default_config, dap_args)
  end

  if dap_config.request == "attach" then
    dap_config.python = nil
    dap_config.program = nil
    dap_config.args = nil
    if not dap_config.pathMappings and context.mappings then
      dap_config.pathMappings = M.get_dap_path_mappings(context.mappings)
    end
  end

  return dap_config
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
