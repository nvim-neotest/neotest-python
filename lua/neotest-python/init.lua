local async = require("neotest.async")
local lib = require("neotest.lib")
local logger = require("neotest.logging")
local base = require("neotest-python.base")

local function get_script()
  local paths = vim.api.nvim_get_runtime_file("neotest.py", true)
  for _, path in ipairs(paths) do
    if vim.endswith(path, ("neotest-python%sneotest.py"):format(lib.files.sep)) then
      return path
    end
  end

  error("neotest.py not found")
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

function PythonNeotestAdapter.filter_dir(name)
  return name ~= "venv"
end


local function add_test_instances(root, positions, test_instances)
  for _, value in positions:iter_nodes() do
    local data = value:data()
    if data.type ~= "test" then
      goto continue
    end
    local _, end_idx = string.find(data.id, root .. "/", 1, true)
    local comparable_id = string.sub(data.id, end_idx + 1)
    if test_instances[comparable_id] == nil then
      goto continue
    end
    for _, test_instance in pairs(test_instances[comparable_id]) do
      local new_data = vim.tbl_extend("force", data, {
        id = data.id .. test_instance,
        name = data.name .. test_instance,
        range = nil,
      })

      local new_pos = value:new(new_data, {}, value._key, {}, {})
      value:add_child(new_data.id, new_pos)
    end
    ::continue::
  end
end

---@async
---@param path string
---@return boolean
local function has_parametrize(path)
  local query = [[
    ;; Detect parametrize decorators
    (decorator
      (call
        function:
          (attribute
            attribute: (identifier) @parametrize
            (#eq? @parametrize "parametrize"))))
  ]]
  local content = lib.files.read(path)
  local ts_root, lang = lib.treesitter.get_parse_root(path, content, { fast = true })
  local built_query = lib.treesitter.normalise_query(lang, query)
  return built_query:iter_matches(ts_root, content)() ~= nil
end

---@async
---@return Tree | nil
function PythonNeotestAdapter.discover_positions(path)
  local root = PythonNeotestAdapter.root(path)
  local python = get_python(root)
  local runner = get_runner(python)

  local pytest_job
  local test_instances = {}
  if runner == "pytest" and pytest_discover_instances and has_parametrize(path) then
    -- Launch an async job to collect test instances from pytest
    local cmd = table.concat(vim.tbl_flatten({ python, get_script(), "--pytest-collect" , path}), " ")
    logger.debug("Running test instance discovery:", cmd)

    _, pytest_job = pcall(async.fn.jobstart, cmd, {
      pty = true,
      on_stdout = function(_, data)
        for _, line in pairs(data) do
          local test_id, param_id = string.match(line, "(.+::.+)(%[.+%])\r?")
          if test_id and param_id then
            if test_instances[test_id] == nil then
              test_instances[test_id] = {param_id}
            else
              table.insert(test_instances[test_id], param_id)
            end
          end
        end
      end,
    })
  end

  -- Parse the file while pytest is running
  local query = [[
    ;; Match undecorated functions
    ((function_definition
      name: (identifier) @test.name)
      (#match? @test.name "^test"))
      @test.definition
    ;; Match decorated function, including decorators in definition
    (decorated_definition
      ((function_definition
        name: (identifier) @test.name)
        (#match? @test.name "^test")))
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
  ]]
  local positions = lib.treesitter.parse_positions(path, query, {
    require_namespaces = runner == "unittest",
  })

  if pytest_job then
    -- Wait for pytest to complete, and merge its results into the TS tree
    async.fn.jobwait({pytest_job})

    add_test_instances(root, positions, test_instances)
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
    "--",
    vim.list_extend(get_args(runner, position), args.extra_args or {}),
  })
  if position then
    table.insert(script_args, position.id)
  end
  local python_script = get_script()
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
