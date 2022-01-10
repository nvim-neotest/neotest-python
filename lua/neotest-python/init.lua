local logger = require("neotest.logging")
local Path = require("plenary.path")
local lib = require("neotest.lib")
local base = require("neotest-python.base")

local function script_path()
  local str = debug.getinfo(2, "S").source:sub(2)
  return str:match("(.*/)")
end

local python_script = (Path.new(script_path()):parent():parent() / "neotest.py").filename

local get_args = function(runner, position)
  if runner == "unittest" then
    runner = "pyunit"
  end
  return lib.vim_test.collect_args("python", runner, position)
end

local get_runner = function()
  local vim_test_runner = vim.g["test#python#runner"]
  if vim_test_runner == "pyunit" then
    return "unittest"
  end
  if vim_test_runner and lib.func_util.index({ "unittest", "pytest" }, vim_test_runner) then
    return vim_test_runner
  end
  if vim.fn.executable("pytest") == 1 then
    return "pytest"
  end
  return "unittest"
end

---@type NeotestAdapter
local PythonNeotestAdapter = { name = "neotest-python" }

function PythonNeotestAdapter.is_test_file(file_path)
  return base.is_test_file(file_path)
end

---@async
---@return Tree | nil
function PythonNeotestAdapter.discover_positions(path)
  local query = [[
    ((function_definition
      name: (identifier) @test.name)
      (#match? @test.name "^test_"))
      @test.definition

    (class_definition
     name: (identifier) @namespace.name)
     @namespace.definition
  ]]
  return lib.treesitter.parse_positions(path, query, {
    require_namespaces = get_runner() == "unittest",
  })
end

---@param args NeotestRunArgs
---@return NeotestRunSpec
function PythonNeotestAdapter.build_spec(args)
  local position = args.tree:data()
  local results_path = vim.fn.tempname()
  local runner = get_runner()
  local python = base.get_python_command(vim.fn.getcwd())
  local script_args = vim.tbl_flatten({
    "--results-file",
    results_path,
    "--runner",
    runner,
    "--",
    get_args(runner, position),
  })
  if position then
    table.insert(script_args, position.id)
  end
  local command = vim.tbl_flatten({
    python,
    python_script,
    script_args,
  })
  return {
    command = command,
    context = {
      results_path = results_path,
    },
    strategy = base.get_strategy_config(args.strategy, python_script, script_args),
  }
end

---@async
---@param spec NeotestRunSpec
---@param result NeotestStrategyResult
---@return NeotestResult[]
function PythonNeotestAdapter.results(spec, result)
  -- TODO: Find out if this JSON option is supported in future
  local success, data = pcall(lib.files.read, spec.context.results_path)
  if not success then
    data = "{}"
  end
  local results = vim.json.decode(data, { luanil = { object = true } })
  for _, pos_result in pairs(results) do
    result.output_path = pos_result.output_path
  end
  return results
end

setmetatable(PythonNeotestAdapter, {
  __call = function(_, opts)
    if type(opts.args) == "function" or (type(opts.args) == "table" and opts.args.__call) then
      get_args = opts.args
    elseif opts.args then
      get_args = function()
        return opts.args
      end
    end
    if type(opts.runner) == "function" or (type(opts.runner) == "table" and opts.runner.__call) then
      get_runner = opts.runner
    elseif opts.runner then
      get_runner = function()
        return opts.runner
      end
    end
  end,
})

return PythonNeotestAdapter

