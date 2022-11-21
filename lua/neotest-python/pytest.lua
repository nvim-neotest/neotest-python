local async = require("neotest.async")
local lib = require("neotest.lib")
local logger = require("neotest.logging")

local M = {}

function M.add_test_instances(root, positions, test_instances)
  for _, value in positions:iter_nodes() do
    local data = value:data()
    if data.type ~= "test" then
      goto continue
    end
    local _, end_idx = string.find(data.id, root .. "/", 1, true)
    local comparable_id = string.sub(data.id, end_idx + 1)
    if test_instances[comparable_id] == nil then
      goto continue
    end
    for _, test_instance in pairs(test_instances[comparable_id]) do
      local new_data = vim.tbl_extend("force", data, {
        id = data.id .. test_instance,
        name = data.name .. test_instance,
        range = nil,
      })

      local new_pos = value:new(new_data, {}, value._key, {}, {})
      value:add_child(new_data.id, new_pos)
    end
    ::continue::
  end
end

---@async
---@param path string
---@return boolean
function M.has_parametrize(path)
  local query = [[
    ;; Detect parametrize decorators
    (decorator
      (call
        function:
          (attribute
            attribute: (identifier) @parametrize
            (#eq? @parametrize "parametrize"))))
  ]]
  local content = lib.files.read(path)
  local ts_root, lang = lib.treesitter.get_parse_root(path, content, { fast = true })
  local built_query = lib.treesitter.normalise_query(lang, query)
  return built_query:iter_matches(ts_root, content)() ~= nil
end

function M.discover_instances(python, script, path)
  -- Launch an async job to collect test instances from pytest
  local cmd = table.concat(vim.tbl_flatten({ python, script, "--pytest-collect", path }), " ")
  logger.debug("Running test instance discovery:", cmd)

  local test_instances = {}
  local _, pytest_job = pcall(async.fn.jobstart, cmd, {
    pty = true,
    on_stdout = function(_, data)
      for _, line in pairs(data) do
        local test_id, param_id = string.match(line, "(.+::.+)(%[.+%])\r?")
        if test_id and param_id then
          if test_instances[test_id] == nil then
            test_instances[test_id] = { param_id }
          else
            table.insert(test_instances[test_id], param_id)
          end
        end
      end
    end,
  })
  return pytest_job, test_instances
end

return M
