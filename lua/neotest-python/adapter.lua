local Path = require("plenary.path")
local nio = require("nio")
local lib = require("neotest.lib")
local pytest = require("neotest-python.pytest")
local base = require("neotest-python.base")

---@class neotest-python._AdapterConfig
---@field dap_args? table
---@field pytest_discovery? boolean
---@field is_test_file fun(file_path: string):boolean
---@field get_python_command fun(root: string):string[]
---@field get_args fun(runner: string, position: neotest.Position, strategy: string): string[]
---@field get_runner fun(python_command: string[]): string
---@field use_docker? boolean
---@field get_container fun(): string

---@param config neotest-python._AdapterConfig
---@return neotest.Adapter
return function(config)
  ---@param run_args neotest.RunArgs
  ---@param results_path string
  ---@param stream_path string
  ---@param runner string
  ---@return string[]
  local function build_script_args(run_args, results_path, stream_path, runner)
    local script_args = {
      "--results-file",
      results_path,
      "--stream-file",
      stream_path,
      "--runner",
      runner,
    }

    if config.pytest_discovery then
      table.insert(script_args, "--emit-parameterized-ids")
    end

    local position = run_args.tree:data()

    table.insert(script_args, "--")

    vim.list_extend(script_args, config.get_args(runner, position, run_args.strategy))

    if run_args.extra_args then
      vim.list_extend(script_args, run_args.extra_args)
    end

    if position then
      table.insert(script_args, position.id)
    end

    return script_args
  end

  ---@param run_args neotest.RunArgs
  ---@param results_path string
  ---@param runner string
  ---@return string[]
  local function build_docker_args(run_args, results_path, runner)
    local script_args = { "exec" , config.get_container(), runner, "--json="..results_path }

    local position = run_args.tree:data()

    vim.list_extend(script_args, config.get_args(runner, position, run_args.strategy))

    if run_args.extra_args then
      vim.list_extend(script_args, run_args.extra_args)
    end

    if position then
      local relpath = Path:new(position.path):make_relative(vim.loop.cwd())
      table.insert(script_args, relpath)
      if position.type == "test" then
        vim.list_extend(script_args, {'-k', position.name})
      end
    end

    return script_args
  end

  ---@type neotest.Adapter
  return {
    name = "neotest-python",
    root = base.get_root,
    filter_dir = function(name)
      return name ~= "venv"
    end,
    is_test_file = config.is_test_file,
    discover_positions = function(path)
      local root = base.get_root(path) or vim.loop.cwd() or ""

      local python_command = config.get_python_command(root)
      local runner = config.get_runner(python_command)

      local positions = lib.treesitter.parse_positions(path, base.treesitter_queries, {
        require_namespaces = runner == "unittest",
      })

      if runner == "pytest" and config.pytest_discovery then
        pytest.augment_positions(python_command, base.get_script_path(), path, positions, root)
      end

      return positions
    end,
    ---@param args neotest.RunArgs
    ---@return neotest.RunSpec
    build_spec = function(args)
      local command
      local results_path
      local script_args
      local script_path

      local position = args.tree:data()
      local root = base.get_root(position.path) or vim.loop.cwd() or ""
      local stream_path = nio.fn.tempname()
      lib.files.write(stream_path, "")

      local stream_data, stop_stream = lib.files.stream_lines(stream_path)
      local runner = config.get_runner(command)

      if config.use_docker == false then
        command = config.get_python_command(root)

        results_path = nio.fn.tempname()
        script_args = build_script_args(args, results_path, stream_path, runner)
        script_path = base.get_script_path()
      else
        command = {"docker"}
        script_path = "container"
        results_path = "report.json"
        script_args = build_docker_args(args, results_path, runner)
      end

      local strategy_config
      if args.strategy == "dap" then
        strategy_config = base.create_dap_config(command, script_path, script_args, config.dap_args)
      end

      ---@type neotest.RunSpec
      return {
        command = vim.iter({ command, script_path, script_args }):flatten():totable(),
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
    end,
    ---@param spec neotest.RunSpec
    ---@param result neotest.StrategyResult
    ---@return neotest.Result[]
    results = function(spec, result, tree)
      local results = {}
      spec.context.stop_stream()
      local success, data = pcall(lib.files.read, spec.context.results_path)
      if not success then
        data = "{}"
      end
      local report = vim.json.decode(data, { luanil = { object = true } })

      -- Native pytest execution
      if config.use_docker == false then
        for _, pos_result in pairs(results) do
          result.output_path = pos_result.output_path
        end

      -- docker delegated executionù
      else
        -- the path must be recomposed because docker has no the same absolute path
        local path = vim.loop.cwd()

        for _, v in pairs(report['report']['tests']) do
          if v['outcome'] == 'failed' then
            results[path .. "/" .. v['name']] = {
              status = v['outcome'],
              short = v['call']['longrepr']
            }
          else
            results[path .. "/" .. v['name']] = {
              status = v['outcome'],
              short = ""
            }
          end
        end
      end

      return results
    end,
  }
end
