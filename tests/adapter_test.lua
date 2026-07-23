local function noop() end
local fake_positions

package.loaded["nio"] = {
  fn = {
    glob = function()
      return ""
    end,
    exepath = function(command)
      return command
    end,
    getcwd = vim.fn.getcwd,
    mkdir = vim.fn.mkdir,
    tempname = vim.fn.tempname,
  },
  run = function(fn)
    fn()
  end,
}

package.loaded["neotest.logging"] = {
  debug = noop,
  warn = noop,
}

package.loaded["neotest.lib"] = {
  files = {
    sep = "/",
    path = { sep = "/" },
    exists = function()
      return false
    end,
    read = function()
      return ""
    end,
    write = noop,
    stream_lines = function()
      return function()
        return {}
      end, noop
    end,
    match_root_pattern = function()
      return function()
        return vim.fn.resolve(vim.fn.getcwd())
      end
    end,
  },
  process = {
    run = function()
      return 0, { stdout = "", stderr = "" }
    end,
  },
  func_util = {
    index = function(items, value)
      for index, item in ipairs(items) do
        if item == value then
          return index
        end
      end
    end,
  },
  treesitter = {
    parse_positions = function()
      return fake_positions
    end,
  },
}

local Path = { path = { sep = "/" } }
local path_methods = {}

function path_methods:parent()
  return Path:new(vim.fn.fnamemodify(self.filename, ":h"))
end

function Path:new(...)
  local parts = {}
  for _, part in ipairs({ ... }) do
    if part ~= "" then
      table.insert(parts, tostring(part))
    end
  end
  return setmetatable({ filename = table.concat(parts, "/"):gsub("//+", "/") }, {
    __index = path_methods,
    __div = function(path, child)
      return Path:new(path.filename, child)
    end,
  })
end

package.loaded["plenary.path"] = Path

local nio = require("nio")
local base = require("neotest-python.base")
local neotest_python = require("neotest-python")
local pytest = require("neotest-python.pytest")

local function fail(message)
  error(message, 0)
end

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    fail(
      string.format(
        "%s\nexpected: %s\nactual:   %s",
        label,
        vim.inspect(expected),
        vim.inspect(actual)
      )
    )
  end
end

local function assert_matches(actual, pattern, label)
  if not actual:match(pattern) then
    fail(string.format("%s\nexpected pattern: %s\nactual:           %s", label, pattern, actual))
  end
end

local function assert_contains_sequence(items, sequence, label)
  for index = 1, #items - #sequence + 1 do
    local found = true
    for offset = 1, #sequence do
      if items[index + offset - 1] ~= sequence[offset] then
        found = false
        break
      end
    end
    if found then
      return
    end
  end

  fail(
    string.format(
      "%s\nexpected sequence: %s\nactual:            %s",
      label,
      vim.inspect(sequence),
      vim.inspect(items)
    )
  )
end

local function make_tree(position)
  return {
    data = function()
      return position
    end,
  }
end

local function make_positions_tree(positions)
  return {
    iter_nodes = function()
      local index = 0
      return function()
        index = index + 1
        local node_position = positions[index]
        if not node_position then
          return
        end
        return index, make_tree(node_position)
      end
    end,
  }
end

local function find_arg(command, key)
  for index, item in ipairs(command) do
    if item == key then
      return command[index + 1]
    end
  end
end

local function find_path_mapping(path_mappings, local_root)
  for _, mapping in ipairs(path_mappings or {}) do
    if mapping.localRoot == local_root then
      return mapping
    end
  end
end

local root = vim.fn.resolve(vim.fn.getcwd())
local position = {
  id = root .. "/tests/example_test.py::test_demo",
  path = root .. "/tests/example_test.py",
}

local adapter = neotest_python({
  runner = "pytest",
  python = { "python" },
  args = { "-n", "auto", "-q" },
  cwd = function(resolved_root)
    return resolved_root
  end,
  env = function(_, current_position)
    return { TEST_POSITION = current_position.id }
  end,
  path_mappings = { [root] = "/workspace" },
  root = function()
    return root
  end,
})

local attach_adapter = neotest_python({
  runner = "pytest",
  python = function()
    return nil
  end,
  args = { "-q" },
  path_mappings = { [root] = "/workspace" },
  dap = function(_, current_position, _, context)
    return {
      request = "attach",
      connect = { host = "127.0.0.1", port = 5678 },
      position_id = current_position.id,
      remote_script = context.remote_script_path,
    }
  end,
  root = function()
    return root
  end,
})

nio.run(function()
  local run_spec = adapter.build_spec({ tree = make_tree(vim.deepcopy(position)) })

  assert_equal(run_spec.cwd, root, "build_spec should expose configured cwd")
  assert_equal(run_spec.env.TEST_POSITION, position.id, "env callback should receive the position")
  assert_contains_sequence(
    run_spec.command,
    { "--", "-n", "auto", "-q" },
    "build_spec should preserve pytest arguments"
  )
  assert_matches(
    find_arg(run_spec.command, "--results-file"),
    "^/workspace/%.neotest%-python%-",
    "results file should translate to a mapped project temp path"
  )
  assert_matches(
    find_arg(run_spec.command, "--stream-file"),
    "^/workspace/%.neotest%-python%-",
    "stream file should translate to a mapped project temp path"
  )
  assert_matches(
    run_spec.command[#run_spec.command],
    "^/workspace/tests/example_test%.py::test_demo$",
    "position id should translate to the remote path"
  )

  local dap_spec = attach_adapter.build_spec({
    tree = make_tree(vim.deepcopy(position)),
    strategy = "dap",
  })

  assert_equal(dap_spec.command[1] ~= nil, true, "python fallback should use the default command")
  assert_equal(dap_spec.strategy.type, "python", "dap overrides should keep default fields")
  assert_equal(dap_spec.strategy.request, "attach", "dap config should allow attach")
  assert_equal(dap_spec.strategy.connect.port, 5678, "dap config should preserve connect settings")
  assert_equal(
    dap_spec.strategy.position_id,
    position.id,
    "dap callback should receive the position"
  )
  assert_equal(
    dap_spec.strategy.remote_script,
    "/workspace/neotest.py",
    "dap context should expose remote script"
  )
  assert_equal(dap_spec.strategy.program, nil, "attach config should drop launch-only program")
  assert_equal(dap_spec.strategy.args, nil, "attach config should drop launch-only args")

  local project_mapping = find_path_mapping(dap_spec.strategy.pathMappings, root)
  assert_equal(project_mapping.localRoot, root, "attach config should derive local debug mapping")
  assert_equal(
    project_mapping.remoteRoot,
    "/workspace",
    "attach config should derive remote debug mapping"
  )

  local discovery_root = root .. "/tests"
  local discovery_path = discovery_root .. "/example_test.py"
  fake_positions = make_positions_tree({
    {
      id = discovery_path .. "::test_demo",
      path = discovery_path,
      type = "test",
    },
  })

  local copied_runtime_dir
  local removed_runtime_dir
  local discovery_script
  local discovery_remote_path
  local discovery_remote_root
  local original_copy_runtime = base.copy_runtime
  local original_remove_dir = base.remove_dir
  local original_augment_positions = pytest.augment_positions

  base.copy_runtime = function(runtime_root)
    local script_path, runtime_dir = original_copy_runtime(runtime_root)
    copied_runtime_dir = runtime_dir
    return script_path, runtime_dir
  end
  base.remove_dir = function(runtime_dir)
    removed_runtime_dir = runtime_dir
    return original_remove_dir(runtime_dir)
  end
  pytest.augment_positions = function(_, script, path, _, remote_root)
    discovery_script = script
    discovery_remote_path = path
    discovery_remote_root = remote_root
  end

  local discovery_adapter = neotest_python({
    runner = "pytest",
    python = { "python" },
    path_mappings = { [discovery_root] = "/workspace" },
    pytest_discover_instances = true,
    root = function()
      return discovery_root
    end,
  })
  discovery_adapter.discover_positions(discovery_path)

  base.copy_runtime = original_copy_runtime
  base.remove_dir = original_remove_dir
  pytest.augment_positions = original_augment_positions

  assert_equal(
    discovery_script:match("^/workspace/%.neotest%-python%-[^/]+/neotest%.py$") ~= nil,
    true,
    "pytest discovery should use a copied remote script when the plugin path is unmapped"
  )
  assert_equal(
    discovery_remote_path,
    "/workspace/example_test.py",
    "pytest discovery should pass the mapped remote test path"
  )
  assert_equal(
    discovery_remote_root,
    "/workspace",
    "pytest discovery should pass the mapped remote root"
  )
  assert_equal(
    removed_runtime_dir,
    copied_runtime_dir,
    "pytest discovery should clean the copied runtime directory"
  )
  assert_equal(
    (vim.uv or vim.loop).fs_stat(copied_runtime_dir) == nil,
    true,
    "pytest discovery runtime directory should not be left on disk"
  )

  vim.g.neotest_python_adapter_tests_passed = true
  print("adapter tests passed")
end)

if
  not vim.wait(1000, function()
    return vim.g.neotest_python_adapter_tests_passed == true
  end)
then
  fail("adapter tests timed out")
end
