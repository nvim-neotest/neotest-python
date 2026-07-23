local lib = require("neotest.lib")
local pytest = require("neotest-python.pytest")
local base = require("neotest-python.base")
local path_mapping = require("neotest-python.path_mapping")

---@class neotest-python._AdapterConfig
---@field dap_args? table|fun(root: string, position: neotest.Position, default_config: table, context: table): table
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
      table.insert(script_args, path_mapping.to_remote(position.id, mappings))
    end

    return script_args
  end

  local function to_host_results(results, mappings)
    local host_results = {}
    for id, pos_result in pairs(results) do
      local host_id = path_mapping.to_host(id, mappings)
      if pos_result and pos_result.output_path then
        pos_result.output_path = path_mapping.to_host(pos_result.output_path, mappings)
      end
      host_results[host_id] = pos_result
    end
    return host_results
  end

  local function get_script_paths(root, mappings)
    local script_path = vim.fn.resolve(base.get_script_path())
    local remote_script_path = path_mapping.to_remote(script_path, mappings)
    local runtime_dir

    if remote_script_path == script_path and path_mapping.to_remote(root, mappings) ~= root then
      script_path, runtime_dir = base.copy_runtime(root)
      remote_script_path = path_mapping.to_remote(script_path, mappings)
    end

    return script_path, remote_script_path, runtime_dir
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
      local mappings = path_mapping.normalize(config.get_path_mappings(root))

      local positions = lib.treesitter.parse_positions(
        path,
        base.treesitter_queries(runner, config, python_command),
        {
          require_namespaces = runner == "unittest",
        }
      )

      if runner == "pytest" and config.pytest_discovery then
        local _, remote_script_path, runtime_dir = get_script_paths(root, mappings)
        pytest.augment_positions(
          python_command,
          remote_script_path,
          path_mapping.to_remote(path, mappings),
          positions,
          path_mapping.to_remote(root, mappings),
          mappings
        )
        if runtime_dir then
          base.remove_dir(runtime_dir)
        end
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
      local mappings = path_mapping.normalize(config.get_path_mappings(root))
      local cwd = config.get_cwd(root, position)
      local env = config.get_env(root, position) or {}
      if vim.tbl_isempty(env) then
        env = nil
      end

      local results_path = path_mapping.tempname(root, mappings)
      local stream_path = path_mapping.tempname(root, mappings)
      lib.files.write(stream_path, "")

      local stream_data, stop_stream = lib.files.stream_lines(stream_path)

      local remote_results_path = path_mapping.to_remote(results_path, mappings)
      local remote_stream_path = path_mapping.to_remote(stream_path, mappings)

      local script_args =
        build_script_args(args, remote_results_path, remote_stream_path, runner, mappings)
      local script_path, remote_script_path, runtime_dir = get_script_paths(root, mappings)
      local command =
        vim.iter({ python_command, remote_script_path, script_args }):flatten():totable()

      local strategy_config
      if args.strategy == "dap" then
        strategy_config = base.create_dap_config(
          python_command,
          script_path,
          script_args,
          cwd,
          env,
          config.dap_args,
          {
            root = root,
            position = position,
            mappings = mappings,
            command = command,
            python_command = python_command,
            script_path = script_path,
            remote_script_path = remote_script_path,
            script_args = script_args,
            results_path = results_path,
            stream_path = stream_path,
            remote_results_path = remote_results_path,
            remote_stream_path = remote_stream_path,
            runtime_dir = runtime_dir,
            cwd = cwd,
            env = env,
          }
        )
      end

      ---@type neotest.RunSpec
      return {
        command = command,
        context = {
          results_path = results_path,
          stream_path = stream_path,
          runtime_dir = runtime_dir,
          stop_stream = stop_stream,
          mappings = mappings,
        },
        stream = function()
          return function()
            local lines = stream_data()
            local results = {}
            for _, line in ipairs(lines) do
              local result = vim.json.decode(line, { luanil = { object = true } })
              results[result.id] = result.result
            end
            return to_host_results(results, mappings)
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
      local host_results = to_host_results(results, spec.context.mappings)
      for _, pos_result in pairs(host_results) do
        result.output_path = pos_result.output_path
      end
      pcall(vim.loop.fs_unlink, spec.context.results_path)
      pcall(vim.loop.fs_unlink, spec.context.stream_path)
      if spec.context.runtime_dir then
        base.remove_dir(spec.context.runtime_dir)
      end
      return host_results
    end,
  }
end
