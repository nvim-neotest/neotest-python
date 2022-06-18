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

---@return string[]
function M.get_python_command(root)
  -- Use activated virtualenv.
  if vim.env.VIRTUAL_ENV then
    return { Path:new(vim.env.VIRTUAL_ENV, "bin", "python").filename }
  end

  for _, pattern in ipairs({ "*", ".*" }) do
    local match = async.fn.glob(Path:new(root or async.fn.getcwd(), pattern, "pyvenv.cfg").filename)
    if match ~= "" then
      return { (Path:new(match):parent() / "bin" / "python").filename }
    end
  end

  if lib.files.exists("Pipfile") then
    return { "pipenv", "run", "python" }
  end
  
  if lib.files.exists("pyproject.toml") then
    return { "poetry", "run", "python" }
  end

  -- Fallback to system Python.
  return { async.fn.exepath("python3") or async.fn.exepath("python") or "python" }
end

return M
