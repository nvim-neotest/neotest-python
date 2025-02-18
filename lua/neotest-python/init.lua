local base = require("neotest-python.base")
local create_adapter = require("neotest-python.adapter")

---@class neotest-python.AdapterConfig
---@field dap? table
---@field pytest_discover_instances? boolean
---@field is_test_file? fun(file_path: string):boolean
---@field python? string|string[]|fun(root: string):string[]
---@field args? string[]|fun(runner: string, position: neotest.Position, strategy: string): string[]
---@field runner? string|fun(python_command: string[]): string
---@field use_docker? boolean|fun(): boolean
---@field container? string|fun(): string

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

      return base.get_python(root)
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

  local use_docker = base.use_docker
  if is_callable(config.use_docker) then
    use_docker = config.use_docker
  else
    use_docker = function ()
      return config.use_docker
    end
  end

  local get_container = base.get_container
  if is_callable(config.container) then
    get_container = config.container
  elseif config.container then
    get_container = function ()
      return config.container
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
    use_docker = use_docker,
    get_container = get_container,
  }
end

local PythonNeotestAdapter = create_adapter(augment_config({}))

setmetatable(PythonNeotestAdapter, {
  __call = function(_, config)
    return create_adapter(augment_config(config))
  end,
})

return PythonNeotestAdapter
