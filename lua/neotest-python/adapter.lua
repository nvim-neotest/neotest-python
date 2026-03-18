local nio = require("nio")
local lib = require("neotest.lib")
local pytest = require("neotest-python.pytest")
local base = require("neotest-python.base")
local path_mapping = require("neotest-python.path_mapping")
local logger = require("neotest.logging")

---@class neotest-python._AdapterConfig
---@field dap_args? table
---@field pytest_discovery? boolean
---@field is_test_file fun(file_path: string):boolean
---@field get_python_command fun(root: string):string[]
---@field get_args fun(runner: string, position: neotest.Position, strategy: string): string[]
---@field get_cwd fun(root: string, position: neotest.Position): string|nil
---@field get_env fun(root: string, position: neotest.Position): table<string, string>
---@field get_runner fun(python_command: string[]): string
---@field get_path_mappings fun(root: string): table<string, string>
---@field root fun(path: string): string|nil

---@param config neotest-python._AdapterConfig
---@return neotest.Adapter
return function(config)
  ---@param run_args neotest.RunArgs
  ---@param results_path string
  ---@param stream_path string
  ---@param runner string
  ---@param mappings table<string, string>
  ---@return string[]
  local function build_script_args(run_args, results_path, stream_path, runner, mappings)
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
      local container_id = path_mapping.to_container_path(position.id, mappings)
      logger.debug("neotest-python: Position ID Host: ", position.id, " Container: ", container_id)
      table.insert(script_args, container_id)
    end

    return script_args
  end

  ---@type neotest.Adapter
  return {

    name = "neotest-python",
    root = config.root,
    filter_dir = function(name)
      return name ~= "venv"
    end,
    is_test_file = config.is_test_file,
    discover_positions = function(path)
      path = vim.fn.resolve(path)
      local root = config.root(path) or vim.loop.cwd() or ""

      local python_command = config.get_python_command(root)
      local runner = config.get_runner(python_command)
      local mappings = path_mapping.normalize_mappings(config.get_path_mappings(root))

      local positions = lib.treesitter.parse_positions(path, base.treesitter_queries(runner, config, python_command), {
        require_namespaces = runner == "unittest",
      })

      if runner == "pytest" and config.pytest_discovery then
        local container_script_path = path_mapping.to_container_path(base.get_script_path(), mappings)
        local container_path = path_mapping.to_container_path(path, mappings)
        local container_root = path_mapping.to_container_path(root, mappings)
        pytest.augment_positions(python_command, container_script_path, container_path, positions, container_root, mappings)
      end

      return positions
    end,
    ---@param args neotest.RunArgs
    ---@return neotest.RunSpec
    build_spec = function(args)
      local position = args.tree:data()
      position.path = vim.fn.resolve(position.path)

      local root = config.root(position.path) or vim.loop.cwd() or ""

      local python_command = config.get_python_command(root)
      local runner = config.get_runner(python_command)
      local mappings = path_mapping.normalize_mappings(config.get_path_mappings(root))
      local cwd = config.get_cwd(root, position)
      local env = config.get_env(root, position) or {}
      if vim.tbl_isempty(env) then
        env = nil
      end

      logger.debug("neotest-python: Root: ", root)
      logger.debug("neotest-python: Mappings: ", mappings.forward)

      local results_path = vim.fn.resolve(nio.fn.tempname())
      local stream_path = vim.fn.resolve(nio.fn.tempname())
      lib.files.write(stream_path, "")

      local stream_data, stop_stream = lib.files.stream_lines(stream_path)

      local container_results_path = path_mapping.to_container_path(results_path, mappings)
      local container_stream_path = path_mapping.to_container_path(stream_path, mappings)

      logger.debug("neotest-python: Results Path Host: ", results_path, " Container: ", container_results_path)
      logger.debug("neotest-python: Stream Path Host: ", stream_path, " Container: ", container_stream_path)

      local script_args = build_script_args(args, container_results_path, container_stream_path, runner, mappings)
      local script_path = vim.fn.resolve(base.get_script_path())
      local container_script_path = path_mapping.to_container_path(script_path, mappings)

      logger.debug("neotest-python: Script Path Host: ", script_path, " Container: ", container_script_path)

      local strategy_config
      if args.strategy == "dap" then
        strategy_config =
          base.create_dap_config(python_command, script_path, script_args, cwd, env, config.dap_args)
      end

      local command = vim.iter({ python_command, container_script_path, script_args }):flatten():totable()
      logger.debug("neotest-python: Full Command: ", table.concat(command, " "))

      ---@type neotest.RunSpec
      return {
        command = command,
        context = {
          results_path = results_path,
          stop_stream = stop_stream,
          mappings = mappings,
        },
        stream = function()
          return function()
            local lines = stream_data()
            local results = {}
            for _, line in ipairs(lines) do
              local result = vim.json.decode(line, { luanil = { object = true } })
              local host_id = path_mapping.to_host_path(result.id, mappings)
              if result.result and result.result.output_path then
                result.result.output_path = path_mapping.to_host_path(result.result.output_path, mappings)
              end
              results[host_id] = result.result
            end
            return results
          end
        end,
        strategy = strategy_config,
        cwd = cwd,
        env = env,
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
      local host_results = {}
      for id, pos_result in pairs(results) do
        local host_id = path_mapping.to_host_path(id, spec.context.mappings)
        if pos_result.output_path then
          pos_result.output_path = path_mapping.to_host_path(pos_result.output_path, spec.context.mappings)
        end
        host_results[host_id] = pos_result
      end
      for _, pos_result in pairs(host_results) do
        result.output_path = pos_result.output_path
      end
      return host_results
    end,
  }
end
