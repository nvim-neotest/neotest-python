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

      local positions = lib.treesitter.parse_positions(path, base.treesitter_queries(runner, config, python_command), {
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
      local position = args.tree:data()

      local root = base.get_root(position.path) or vim.loop.cwd() or ""

      local python_command = config.get_python_command(root)
      local runner = config.get_runner(python_command)

      local results_path = nio.fn.tempname()
      local stream_path = nio.fn.tempname()
      lib.files.write(stream_path, "")

      local stream_data, stop_stream = lib.files.stream_lines(stream_path)

      local script_args = build_script_args(args, results_path, stream_path, runner)
      local script_path = base.get_script_path()

      local strategy_config
      if args.strategy == "dap" then
        strategy_config =
          base.create_dap_config(python_command, script_path, script_args, config.dap_args)
      end
      ---@type neotest.RunSpec
      return {
        command = vim.iter({ python_command, script_path, script_args }):flatten():totable(),
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
    results = function(spec, result)
      spec.context.stop_stream()
      local success, data = pcall(lib.files.read, spec.context.results_path)
      if not success then
        data = "{}"
      end
      local results = vim.json.decode(data, { luanil = { object = true } })
      for _, pos_result in pairs(results) do
        result.output_path = pos_result.output_path
      end
      return results
    end,
  }
end
