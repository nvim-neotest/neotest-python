local async = require("neotest.async")
local lib = require("neotest.lib")
local Path = require("plenary.path")

local M = {}

function M.is_test_file(file_path)
  if not vim.endswith(file_path, ".py") then
    return false
  end
  local elems = vim.split(file_path, Path.path.sep)
  local file_name = elems[#elems]
  return vim.startswith(file_name, "test_") or vim.endswith(file_name, "_test.py")
end

M.module_exists = function(module, python_command)
  return lib.process.run(vim.tbl_flatten({
    python_command,
    "-c",
    "import imp; imp.find_module('" .. module .. "')",
  })) == 0
end

local python_command_mem = {}

---@return string[]
function M.get_python_command(root)
  if not root then
    root = vim.loop.cwd()
  end
  if python_command_mem[root] then
    return python_command_mem[root]
  end
  -- Use activated virtualenv.
  if vim.env.VIRTUAL_ENV then
    python_command_mem[root] = { Path:new(vim.env.VIRTUAL_ENV, "bin", "python").filename }
    return python_command_mem[root]
  end

  for _, pattern in ipairs({ "*", ".*" }) do
    local match = async.fn.glob(Path:new(root or async.fn.getcwd(), pattern, "pyvenv.cfg").filename)
    if match ~= "" then
      python_command_mem[root] = { (Path:new(match):parent() / "bin" / "python").filename }
      return python_command_mem[root]
    end
  end

  if lib.files.exists("Pipfile") then
    local success, _, data = pcall(lib.process.run, { "pipenv", "--py" }, { stdout = true })
    if success then
      local venv = data.stdout:gsub("\n", "")
      if venv then
        python_command_mem[root] = { Path:new(venv).filename }
        return python_command_mem[root]
      end
    end
  end

  if lib.files.exists("pyproject.toml") then
    local success, _, data = pcall(
      lib.process.run,
      { "poetry", "env", "info", "-p" },
      { stdout = true }
    )
    if success then
      local venv = data.stdout:gsub("\n", "")
      if venv then
        python_command_mem[root] = { Path:new(venv, "bin", "python").filename }
        return python_command_mem[root]
      end
    end
  end

  -- Fallback to system Python.
  python_command_mem[root] = {
    async.fn.exepath("python3") or async.fn.exepath("python") or "python",
  }
  return python_command_mem[root]
end

return M
