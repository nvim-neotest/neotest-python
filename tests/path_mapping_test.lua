package.loaded["neotest.logging"] = {
  debug = function() end,
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
local temp_root = vim.fn.resolve(vim.env.TMPDIR or (vim.uv or vim.loop).os_tmpdir() or "/tmp")

local mappings = path_mapping.normalize_mappings({
  [cwd] = "/workspace",
  ["/tmp"] = "/tmp",
})

assert_equal(
  path_mapping.to_container_path(join_path(cwd, "lua/neotest-python/adapter.lua"), mappings),
  "/workspace/lua/neotest-python/adapter.lua",
  "project paths should translate to the container root"
)

assert_equal(
  path_mapping.to_container_path(
    join_path(temp_root, "neotest-python/results.json"),
    mappings
  ),
  "/tmp/neotest-python/results.json",
  "resolved temp paths should translate via the /tmp mapping"
)

assert_equal(
  path_mapping.to_host_path("/tmp/neotest-python/results.json", mappings),
  join_path(temp_root, "neotest-python/results.json"),
  "container temp paths should translate back to the active host temp root"
)

assert_equal(
  path_mapping.to_container_path(
    join_path(cwd, "lua/neotest-python/adapter.lua::TestAdapter::test_build_spec"),
    mappings
  ),
  "/workspace/lua/neotest-python/adapter.lua::TestAdapter::test_build_spec",
  "test node ids should preserve their suffix when translated"
)

print("path_mapping tests passed")
