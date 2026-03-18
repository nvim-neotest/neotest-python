local nio = require("nio")
local neotest_python = require("neotest-python")

local function fail(message)
  error(message, 0)
end

local function assert_equal(actual, expected, label)
  if actual ~= expected then
    fail(string.format("%s\nexpected: %s\nactual:   %s", label, vim.inspect(expected), vim.inspect(actual)))
  end
end

local function assert_starts_with(actual, prefix, label)
  if not vim.startswith(actual, prefix) then
    fail(string.format("%s\nexpected prefix: %s\nactual:          %s", label, prefix, actual))
  end
end

local function assert_contains_sequence(items, sequence, label)
  for index = 1, #items - #sequence + 1 do
    local matches = true
    for offset = 1, #sequence do
      if items[index + offset - 1] ~= sequence[offset] then
        matches = false
        break
      end
    end
    if matches then
      return
    end
  end

  fail(string.format("%s\nexpected sequence: %s\nactual:            %s", label, vim.inspect(sequence), vim.inspect(items)))
end

local function make_tree(position)
  return {
    data = function()
      return position
    end,
  }
end

local root = vim.fn.resolve(vim.fn.getcwd())
local position = {
  id = root .. "/tests/example_test.py::test_demo",
  path = root .. "/tests/example_test.py",
}

local adapter = neotest_python({
  runner = "pytest",
  python = { "python" },
  args = function()
    return { "-n", "auto", "-q" }
  end,
  cwd = function(resolved_root)
    return resolved_root
  end,
  env = function(_, current_position)
    return {
      TEST_ENV = "set",
      TEST_POSITION = current_position.id,
    }
  end,
  path_mappings = {
    [root] = "/workspace",
    ["/tmp"] = "/tmp",
  },
  root = function()
    return root
  end,
})

local function find_arg(command, key)
  for index, item in ipairs(command) do
    if item == key then
      return command[index + 1]
    end
  end
end

nio.run(function()
  local run_spec = adapter.build_spec({
    tree = make_tree(vim.deepcopy(position)),
  })

  assert_equal(run_spec.cwd, root, "build_spec should expose configured cwd")
  assert_equal(run_spec.env.TEST_ENV, "set", "build_spec should expose configured env")
  assert_equal(run_spec.env.TEST_POSITION, position.id, "env callback should receive the position")
  assert_contains_sequence(
    run_spec.command,
    { "--", "-n", "auto", "-q" },
    "build_spec should preserve pytest-xdist arguments"
  )

  assert_starts_with(
    find_arg(run_spec.command, "--results-file"),
    "/tmp/",
    "results file should translate to the container temp path"
  )
  assert_starts_with(
    find_arg(run_spec.command, "--stream-file"),
    "/tmp/",
    "stream file should translate to the container temp path"
  )
  assert_starts_with(
    run_spec.command[#run_spec.command],
    "/workspace/tests/example_test.py::test_demo",
    "position id should translate to the container path"
  )

  local dap_spec = adapter.build_spec({
    tree = make_tree(vim.deepcopy(position)),
    strategy = "dap",
  })

  assert_equal(dap_spec.strategy.cwd, root, "dap config should inherit configured cwd")
  assert_equal(dap_spec.strategy.env.TEST_ENV, "set", "dap config should inherit configured env")

  vim.g.neotest_python_adapter_tests_passed = true
  print("adapter tests passed")
end)

if not vim.wait(1000, function()
  return vim.g.neotest_python_adapter_tests_passed == true
end) then
  fail("adapter tests timed out")
end
