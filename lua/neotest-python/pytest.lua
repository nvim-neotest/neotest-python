local lib = require("neotest.lib")

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

return M
