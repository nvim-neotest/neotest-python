local base = require("neotest-python.base")
local create_adapter = require("neotest-python.adapter")

---@class neotest-python.AdapterConfig
---@field dap? table|fun(root: string, position: neotest.Position, default_config: table, context: table): table
---@field pytest_discover_instances? boolean
---@field is_test_file? fun(file_path: string):boolean
---@field python? string|string[]|fun(root: string):string[]
---@field args? string[]|fun(runner: string, position: neotest.Position, strategy: string): string[]
---@field cwd? string|fun(root: string, position: neotest.Position): string
---@field env? table<string, string>|fun(root: string, position: neotest.Position): table<string, string>
---@field runner? string|fun(python_command: string[]): string
---@field path_mappings? table<string, string>|fun(root: string): table<string, string>
---@field root? fun(path: string): string|nil

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

  local get_cwd = function()
    return nil
  end
  if is_callable(config.cwd) then
    get_cwd = config.cwd
  elseif config.cwd then
    get_cwd = function()
      return config.cwd
    end
  end

  local get_env = function()
    return {}
  end
  if is_callable(config.env) then
    get_env = config.env
  elseif config.env then
    get_env = function()
      return config.env
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

  local get_path_mappings = function()
    return {}
  end
  if is_callable(config.path_mappings) then
    get_path_mappings = config.path_mappings
  elseif config.path_mappings then
    get_path_mappings = function()
      return config.path_mappings
    end
  end

  ---@type neotest-python._AdapterConfig
  return {
    pytest_discovery = config.pytest_discover_instances,
    dap_args = config.dap,
    get_runner = get_runner,
    get_args = get_args,
    get_cwd = get_cwd,
    get_env = get_env,
    is_test_file = config.is_test_file or base.is_test_file,
    get_python_command = get_python_command,
    get_path_mappings = get_path_mappings,
    root = config.root or base.get_root,
  }
end

local PythonNeotestAdapter = create_adapter(augment_config({}))

setmetatable(PythonNeotestAdapter, {
  __call = function(_, config)
    return create_adapter(augment_config(config))
  end,
})

return PythonNeotestAdapter
