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
---@field docker? neotest-python.DockerConfig

---@param config neotest-python._AdapterConfig
---@return neotest.Adapter
return function(config)
  ---@param run_args neotest.RunArgs
  ---@param results_path string
  ---@param stream_path string
  ---@param runner string
  ---@param docker_config neotest-python.DockerConfig?
  ---@return string[]
  local function build_script_args(run_args, results_path, stream_path, runner, docker_config)
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

    if position then
      vim.list_extend(script_args, config.get_args(runner, position, run_args.strategy))
    else
      -- For full project runs, call get_args with nil position
      vim.list_extend(script_args, config.get_args(runner, nil, run_args.strategy))
    end

    if run_args.extra_args then
      vim.list_extend(script_args, run_args.extra_args)
    end

    if position and position.id then
      local test_path = position.id
      if docker_config then
        test_path = base.translate_path_to_container(position.id, docker_config)
      end
      table.insert(script_args, test_path)
    else
      -- For full project runs, use the root directory
      local root_path = vim.loop.cwd()
      if docker_config then
        root_path = base.translate_path_to_container(root_path, docker_config)
      end
      table.insert(script_args, root_path)
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

      local results_path, stream_path, script_path, container_results_path, container_stream_path
      if config.docker then
        results_path = nio.fn.tempname()
        stream_path = nio.fn.tempname()
        script_path = base.copy_script_to_container(config.docker)

        local unique_id = tostring(math.random(1000000, 9999999))
        container_results_path = "/tmp/neotest_results_" .. unique_id
        container_stream_path = "/tmp/neotest_stream_" .. unique_id

        lib.files.write(stream_path, "")
        lib.files.write(results_path, "{}")
      else
        results_path = nio.fn.tempname()
        stream_path = nio.fn.tempname()
        script_path = base.get_script_path()
        container_results_path = results_path
        container_stream_path = stream_path
        lib.files.write(stream_path, "")
      end

      local stream_data, stop_stream = lib.files.stream_lines(stream_path)

      local script_args = build_script_args(args, container_results_path, container_stream_path, runner, config.docker)

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
          container_results_path = container_results_path,
          stop_stream = stop_stream,
          docker = config.docker,
        },
        stream = function()
          return function()
            if config.docker and config.docker.container then
              local copy_stream_cmd = {
                "docker", "cp",
                config.docker.container .. ":" .. container_stream_path,
                stream_path
              }
              pcall(lib.process.run, copy_stream_cmd)
            end

            local lines = {}
            pcall(function()
              lines = stream_data()
            end)
            local results = {}
            for _, line in ipairs(lines) do
              if line and line ~= "" then
                local success, result = pcall(vim.json.decode, line, { luanil = { object = true } })
                if success and result and result.id then
                  results[result.id] = result.result
                end
              end
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
      pcall(function()
        spec.context.stop_stream()
      end)

      local data = "{}"

      if spec.context.docker then
        if spec.context.docker.container then
          local copy_cmd = {
            "docker", "cp",
            spec.context.docker.container .. ":" .. spec.context.container_results_path,
            spec.context.results_path
          }
          local copy_success = lib.process.run(copy_cmd) == 0
          if copy_success then
            local read_success, file_data = pcall(lib.files.read, spec.context.results_path)
            if read_success then
              data = file_data
            end
          end
        end
      else
        local success, file_data = pcall(lib.files.read, spec.context.results_path)
        if success then
          data = file_data
        end
      end

      local results = {}
      local parse_success, parsed_results = pcall(vim.json.decode, data, { luanil = { object = true } })
      if parse_success and type(parsed_results) == "table" then
        results = parsed_results
      end

      if spec.context.docker then
        local translated_results = {}
        for test_id, test_result in pairs(results) do
          local host_test_id = base.translate_path_to_host(test_id, spec.context.docker)

          if test_result.output_path then
            test_result.output_path = base.translate_path_to_host(test_result.output_path, spec.context.docker)
          end

          translated_results[host_test_id] = test_result
        end
        results = translated_results
      end

      for _, pos_result in pairs(results) do
        if pos_result.output_path then
          result.output_path = pos_result.output_path
        end
      end
      return results
    end,
  }
end
