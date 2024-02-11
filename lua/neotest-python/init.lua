local async = require("neotest.async")
local lib = require("neotest.lib")
local base = require("neotest-python.base")
local pytest = require("neotest-python.pytest")

local function get_python_script(filename)
  local paths = vim.api.nvim_get_runtime_file(filename, true)
  for _, path in ipairs(paths) do
    if vim.endswith(path, ("neotest-python%s%s"):format(lib.files.sep, filename)) then
      return path
    end
  end

  error(string.format("%s not found", filename))
end

local function get_config_loading_script()
  return get_python_script("get_pytest_options.py")
end

local function get_main_script()
  return get_python_script("neotest.py")
end

local dap_args
local is_test_file = base.is_test_file
local pytest_discover_instances = false

local function get_strategy_config(strategy, python, program, args)
  local config = {
    dap = function()
      return vim.tbl_extend("keep", {
        type = "python",
        name = "Neotest Debugger",
        request = "launch",
        python = python,
        program = program,
        cwd = async.fn.getcwd(),
        args = args,
      }, dap_args or {})
    end,
  }
  if config[strategy] then
    return config[strategy]()
  end
end

local get_python = function(root)
  if not root then
    root = vim.loop.cwd()
  end
  return base.get_python_command(root)
end

local get_args = function()
  return {}
end

local stored_runners = {}

local get_runner = function(python_command)
  local command_str = table.concat(python_command, " ")
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
  local runner = base.module_exists("pytest", python_command) and "pytest"
      or base.module_exists("django", python_command) and "django"
      or "unittest"
  stored_runners[command_str] = runner
  return runner
end

---@type neotest.Adapter
local PythonNeotestAdapter = { name = "neotest-python" }

PythonNeotestAdapter.root =
    lib.files.match_root_pattern("pyproject.toml", "setup.cfg", "mypy.ini", "pytest.ini", "setup.py")

function PythonNeotestAdapter.is_test_file(file_path)
  return is_test_file(file_path)
end

function PythonNeotestAdapter.filter_dir(name)
  return name ~= "venv"
end

function PythonNeotestAdapter.init_python_functions(python, runner)
  if PythonNeotestAdapter.python_functions == nil then
    local python_functions = "^test"
    if runner == "pytest" and pytest_discover_instances then
      local cmd = vim.tbl_flatten({ python, get_config_loading_script() })
      local _, data = lib.process.run(cmd, { stdout = true, stderr = true })

      for line in vim.gsplit(data.stdout, "\n", true) do
        if string.sub(line, 1, 1) == "{" and string.find(line, "python_functions") ~= nil then
          local config = vim.json.decode(line)
          python_functions = config.python_functions
        end
      end
    end
    PythonNeotestAdapter.python_functions = python_functions
  end
end

---@async
---@return neotest.Tree | nil
function PythonNeotestAdapter.discover_positions(path)
  local root = PythonNeotestAdapter.root(path) or vim.loop.cwd()
  local python = get_python(root)
  local runner = get_runner(python)
  PythonNeotestAdapter.init_python_functions(python, runner)

  local query = string.format([[
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
  ]], PythonNeotestAdapter.python_functions, PythonNeotestAdapter.python_functions)
  local positions = lib.treesitter.parse_positions(path, query, {
    require_namespaces = runner == "unittest",
  })

  if runner == "pytest" and pytest_discover_instances then
    pytest.augment_positions(python, get_main_script(), path, positions, root)
  end

  return positions
end

---@async
---@param args neotest.RunArgs
---@return neotest.RunSpec
function PythonNeotestAdapter.build_spec(args)
  local position = args.tree:data()
  local results_path = async.fn.tempname()
  local stream_path = async.fn.tempname()
  lib.files.write(stream_path, "")

  local root = PythonNeotestAdapter.root(position.path)
  local python = get_python(root)
  local runner = get_runner(python)
  local stream_data, stop_stream = lib.files.stream_lines(stream_path)
  local script_args = vim.tbl_flatten({
    "--results-file",
    results_path,
    "--stream-file",
    stream_path,
    "--runner",
    runner,
  })
  if pytest_discover_instances then
    table.insert(script_args, "--emit-parameterized-ids")
  end

  table.insert(script_args, "--")
  vim.list_extend(script_args, get_args(runner, position, args.strategy))
  if args.extra_args then
    vim.list_extend(script_args, args.extra_args)
  end

  if position then
    table.insert(script_args, position.id)
  end
  local python_script = get_main_script()
  local command = vim.tbl_flatten({
    python,
    python_script,
    script_args,
  })
  local strategy_config = get_strategy_config(args.strategy, python, python_script, script_args)
  ---@type neotest.RunSpec
  return {
    command = command,
    context = {
      results_path = results_path,
      stop_stream = stop_stream,
    },
    stream = function()
      return function()
        local lines = stream_data()
        local results = {}
        for _, line in ipairs(lines) do
          local result = vim.json.decode(line, { luanil = { object = true } })
          results[result.id] = result.result
        end
        return results
      end
    end,
    strategy = strategy_config,
  }
end

---@async
---@param spec neotest.RunSpec
---@param result neotest.StrategyResult
---@return neotest.Result[]
function PythonNeotestAdapter.results(spec, result)
  spec.context.stop_stream()
  local success, data = pcall(lib.files.read, spec.context.results_path)
  if not success then
    data = "{}"
  end
  -- TODO: Find out if this JSON option is supported in future
  local results = vim.json.decode(data, { luanil = { object = true } })
  for _, pos_result in pairs(results) do
    result.output_path = pos_result.output_path
  end
  return results
end

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

setmetatable(PythonNeotestAdapter, {
  __call = function(_, opts)
    is_test_file = opts.is_test_file or is_test_file
    if opts.python then
      get_python = function(root)
        local python = opts.python

        if is_callable(opts.python) then
          python = opts.python(root)
        end

        if type(python) == "string" then
          return { python }
        end
        if type(python) == "table" then
          return python
        end

        return base.get_python(root)
      end
    end
    if is_callable(opts.args) then
      get_args = opts.args
    elseif opts.args then
      get_args = function()
        return opts.args
      end
    end
    if is_callable(opts.runner) then
      get_runner = opts.runner
    elseif opts.runner then
      get_runner = function()
        return opts.runner
      end
    end
    if type(opts.dap) == "table" then
      dap_args = opts.dap
    end
    if opts.pytest_discover_instances ~= nil then
      pytest_discover_instances = opts.pytest_discover_instances
    end
    return PythonNeotestAdapter
  end,
})

return PythonNeotestAdapter
