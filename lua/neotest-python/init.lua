local async = require("neotest.async")
local Path = require("plenary.path")
local lib = require("neotest.lib")
local base = require("neotest-python.base")

local function script_path()
  local str = debug.getinfo(2, "S").source:sub(2)
  return str:match("(.*/)")
end

local python_script = (Path.new(script_path()):parent():parent() / "neotest.py").filename

local dap_args
local is_test_file = base.is_test_file

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
  if vim_test_runner and lib.func_util.index({ "unittest", "pytest" }, vim_test_runner) then
    return vim_test_runner
  end
  local runner = base.module_exists("pytest", python_command) and "pytest" or "unittest"
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

---@async
---@return Tree | nil
function PythonNeotestAdapter.discover_positions(path)
  local query = [[
    ((function_definition
      name: (identifier) @test.name)
      (#match? @test.name "^test"))
      @test.definition

    (class_definition
     name: (identifier) @namespace.name)
     @namespace.definition
  ]]
  local root = PythonNeotestAdapter.root(path)
  local python = base.get_python_command(root)
  local runner = get_runner(python)
  return lib.treesitter.parse_positions(path, query, {
    require_namespaces = runner == "unittest",
  })
end

---@async
---@param args neotest.RunArgs
---@return neotest.RunSpec
function PythonNeotestAdapter.build_spec(args)
  local position = args.tree:data()
  local results_path = async.fn.tempname()
  local stream_path = async.fn.tempname()
  local x = io.open(stream_path, "w")
  x:write("")
  x:close()

  local root = PythonNeotestAdapter.root(position.path)
  local python = base.get_python_command(root)
  local runner = get_runner(python)
  local stream_data, stop_stream = lib.files.stream_lines(stream_path)
  local script_args = vim.tbl_flatten({
    "--results-file",
    results_path,
    "--stream-file",
    stream_path,
    "--runner",
    runner,
    "--",
    vim.list_extend(get_args(runner, position), args.extra_args or {}),
  })
  if position then
    table.insert(script_args, position.id)
  end
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
    if type(opts.args) == "function" or (type(opts.args) == "table" and opts.args.__call) then
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
    return PythonNeotestAdapter
  end,
})

return PythonNeotestAdapter
