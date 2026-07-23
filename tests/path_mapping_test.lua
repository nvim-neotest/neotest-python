package.loaded["nio"] = {
  fn = {
    tempname = vim.fn.tempname,
  },
}

local path_mapping = require("neotest-python.path_mapping")

local function fail(message)
  error(message, 0)
end

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    fail(string.format("%s\nexpected: %s\nactual:   %s", label, expected, actual))
  end
end

local function join_path(root, suffix)
  if root:sub(-1) == "/" then
    return root .. suffix
  end
  return root .. "/" .. suffix
end

local cwd = vim.fn.resolve(vim.fn.getcwd())

local mappings = path_mapping.normalize({
  [cwd] = "/workspace",
})

assert_equal(
  path_mapping.to_remote(join_path(cwd, "lua/neotest-python/adapter.lua"), mappings),
  "/workspace/lua/neotest-python/adapter.lua",
  "project paths should translate to the remote root"
)

assert_equal(
  path_mapping.to_host("/workspace/lua/neotest-python/adapter.lua", mappings),
  join_path(cwd, "lua/neotest-python/adapter.lua"),
  "remote paths should translate back to the host root"
)

assert_equal(
  path_mapping.to_remote(
    join_path(cwd, "lua/neotest-python/adapter.lua::TestAdapter::test_build_spec"),
    mappings
  ),
  "/workspace/lua/neotest-python/adapter.lua::TestAdapter::test_build_spec",
  "test node ids should preserve their suffix when translated"
)

assert_equal(
  path_mapping
    .to_remote(path_mapping.tempname(cwd, mappings), mappings)
    :match("^/workspace/%.neotest%-python%-") ~= nil,
  true,
  "mapped temp files should live under the remote project root"
)

print("path_mapping tests passed")
