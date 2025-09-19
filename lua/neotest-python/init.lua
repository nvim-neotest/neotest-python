local base = require("neotest-python.base")
local create_adapter = require("neotest-python.adapter")

---@class neotest-python.DockerConfig
---@field container? string Container name or ID
---@field image? string Docker image name (alternative to container)
---@field command? string[] Custom docker command prefix (default: ["docker", "exec"])
---@field args? string[] Additional docker arguments (e.g., ["-i", "-w", "/app"])
---@field workdir? string Working directory inside container (default: "/app")

---@class neotest-python.AdapterConfig
---@field dap? table
---@field pytest_discover_instances? boolean
---@field is_test_file? fun(file_path: string):boolean
---@field python? string|string[]|fun(root: string):string[]
---@field args? string[]|fun(runner: string, position: neotest.Position, strategy: string): string[]
---@field runner? string|fun(python_command: string[]): string
---@field docker? neotest-python.DockerConfig Docker configuration for containerized execution

local is_callable = function(obj)
  return type(obj) == "function" or (type(obj) == "table" and obj.__call)
end

---@param config neotest-python.AdapterConfig
local augment_config = function(config)
  local get_python_command = base.get_python_command
  if config.python then
    get_python_command = function(root)
      local python = config.python

      if is_callable(config.python) then
        python = config.python(root)
      end

      if type(python) == "string" then
        return { python }
      end
      if type(python) == "table" then
        return python
      end

      return base.get_python_command(root)
    end
  end

  if config.docker then
    get_python_command = function(root)
      return base.get_docker_python_command(root, config.docker)
    end
  end

  local get_args = function()
    return {}
  end

  if is_callable(config.args) then
    get_args = config.args
  elseif config.args then
    get_args = function()
      return config.args
    end
  end

  local get_runner = base.get_runner
  if is_callable(config.runner) then
    get_runner = config.runner
  elseif config.runner then
    get_runner = function()
      return config.runner
    end
  end

  ---@type neotest-python._AdapterConfig
  return {
    pytest_discovery = config.pytest_discover_instances,
    dap_args = config.dap,
    get_runner = get_runner,
    get_args = get_args,
    is_test_file = config.is_test_file or base.is_test_file,
    get_python_command = get_python_command,
    docker = config.docker,
  }
end

local PythonNeotestAdapter = create_adapter(augment_config({}))

setmetatable(PythonNeotestAdapter, {
  __call = function(_, config)
    return create_adapter(augment_config(config))
  end,
})

return PythonNeotestAdapter
