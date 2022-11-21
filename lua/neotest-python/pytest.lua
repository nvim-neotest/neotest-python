local async = require("neotest.async")
local lib = require("neotest.lib")
local logger = require("neotest.logging")

local M = {}

local pytest_jobs = {}
local test_instances = {}

---@async
local function add_test_instances(root, positions, path)
  local test_instances_for_path = test_instances[path]
  if not test_instances_for_path then
    return
  end
  for _, value in positions:iter_nodes() do
    local data = value:data()
    if data.type ~= "test" then
      goto continue
    end
    local _, end_idx = string.find(data.id, root .. "/", 1, true)
    local comparable_id = string.sub(data.id, end_idx + 1)
    if test_instances_for_path[comparable_id] == nil then
      goto continue
    end
    for _, test_instance in pairs(test_instances_for_path[comparable_id]) do
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

---@async
function M.discover_instances(python, script, path)
  -- Launch an async job to collect test instances from pytest
  local cmd = table.concat(vim.tbl_flatten({ python, script, "--pytest-collect", path }), " ")
  logger.debug("Running test instance discovery:", cmd)

  test_instances[path] = {}
  local test_instances_for_path = test_instances[path]
  _, pytest_jobs[path] = pcall(async.fn.jobstart, cmd, {
    pty = true,
    on_stdout = function(_, data)
      for _, line in pairs(data) do
        local test_id, param_id = string.match(line, "(.+::.+)(%[.+%])\r?")
        if test_id and param_id then
          if test_instances_for_path[test_id] == nil then
            test_instances_for_path[test_id] = { param_id }
          else
            table.insert(test_instances_for_path[test_id], param_id)
          end
        end
      end
    end,
  })
end

---@async
function M.add_discovered_positions(root, positions, path)
  local pytest_job = pytest_jobs[path]
  if pytest_job then
    -- Wait for pytest to complete, and merge its results into the TS tree
    async.fn.jobwait({ pytest_job })

    add_test_instances(root, positions, path)
  end
end

return M
