local lib = require("neotest.lib")
local Path = require("plenary.path")

local M = {}

function M.is_test_file(file_path)
	if not vim.endswith(file_path, ".py") then
		return false
	end
	local elems = vim.split(file_path, Path.path.sep)
	local file_name = elems[#elems]
	return vim.startswith(file_name, "test_")
end

---@return string[]
function M.get_python_command(root)
	-- Use activated virtualenv.
	if vim.env.VIRTUAL_ENV then
		return { Path:new(vim.env.VIRTUAL_ENV, "bin", "python").filename }
	end

	for _, pattern in ipairs({ "*", ".*" }) do
		local match = vim.fn.glob(Path:new(root or vim.fn.getcwd(), pattern, "pyvenv.cfg").filename)
		if match ~= "" then
			return { (Path:new(match):parent() / "bin" / "python").filename }
		end
	end

	if lib.files.exists("Pipfile") then
		return { "pipenv", "run", "python" }
	end
	-- Fallback to system Python.
	return { vim.fn.exepath("python3") or vim.fn.exepath("python") or "python" }
end

function M.parse_positions(file_path)
	local query = [[
    ((function_definition
      name: (identifier) @test.name)
      (#match? @test.name "^test_"))
      @test.definition

    (class_definition
     name: (identifier) @namespace.name)
     @namespace.definition
  ]]
	return lib.treesitter.parse_positions(file_path, query)
end

function M.get_strategy_config(strategy, python_script, args)
	local config = {
		dap = function()
			return {
				type = "python",
				name = "Neotest Debugger",
				request = "launch",
				program = python_script,
				cwd = vim.fn.getcwd(),
				args = args,
        justMyCode= false,
			}
		end,
	}
	if config[strategy] then
		return config[strategy]()
	end
end

return M
