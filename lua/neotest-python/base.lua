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

local mem = {}

---@return string[]
function M.get_python_command(root)
  if mem[root] then
    return mem[root]
  end
  -- Use activated virtualenv.
  if vim.env.VIRTUAL_ENV then
    mem[root] = { Path:new(vim.env.VIRTUAL_ENV, "bin", "python").filename }
    return mem[root]
  end

  for _, pattern in ipairs({ "*", ".*" }) do
    local match = async.fn.glob(Path:new(root or async.fn.getcwd(), pattern, "pyvenv.cfg").filename)
    if match ~= "" then
      mem[root] = { (Path:new(match):parent() / "bin" / "python").filename }
      return mem[root]
    end
  end

  if lib.files.exists("Pipfile") then
    local f = assert(io.popen("pipenv --py 2>/dev/null", "r"))
    local venv = assert(f:read("*a")):gsub("\n", "")
    f:close()
    if venv then
      mem[root] = { Path:new(venv).filename }
      return mem[root]
    end
  end

  if lib.files.exists("pyproject.toml") then
    local f = assert(io.popen("poetry env info -p 2>/dev/null", "r"))
    local venv = assert(f:read("*a")):gsub("\n", "")
    f:close()
    if venv then
      mem[root] = { Path:new(venv, "bin", "python").filename }
      return mem[root]
    end
  end

  -- Fallback to system Python.
  mem[root] = { async.fn.exepath("python3") or async.fn.exepath("python") or "python" }
  return mem[root]
end

return M
