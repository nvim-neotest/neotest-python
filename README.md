# neotest-python

[Neotest](https://github.com/rcarriga/neotest) adapter for python.
Supports Pytest and unittest test files.

Requires [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) and the parser for python.

```lua
require("neotest").setup({
  adapters = {
    require("neotest-python")
  }
})
```

You can optionally supply configuration settings:

```lua
require("neotest").setup({
  adapters = {
    require("neotest-python")({
      -- Extra arguments for nvim-dap configuration
      -- See https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings for values
      dap = { justMyCode = false },
      -- Command line arguments for runner
      -- Can also be a function to return dynamic values
      args = { "--log-level", "DEBUG" },
      -- Working directory for spawned test processes.
      -- Can also be a function receiving (root, position).
      cwd = vim.fn.getcwd(),
      -- Extra environment variables for spawned test processes.
      -- Can also be a function receiving (root, position).
      env = { PYTHONPATH = vim.fn.getcwd() },
      -- Runner to use. Will use pytest if available by default.
      -- Can be a function to return dynamic value.
      runner = "pytest",
      -- Custom python path for the runner.
      -- Can be a string or a list of strings.
      -- Can also be a function to return dynamic value.
      -- If not provided, the path will be inferred by checking for
      -- virtual envs in the local directory and for Pipenv/Poetry configs.
      python = ".venv/bin/python",
      -- Returns if a given file path is a test file.
      -- NB: This function is called a lot so don't perform any heavy tasks within it.
      is_test_file = function(file_path)
        ...
      end,
      -- !!EXPERIMENTAL!! Enable shelling out to `pytest` to discover test
      -- instances for files containing a parametrize mark (default: false)
      pytest_discover_instances = true,
    }),
  },
})
```

### Docker/Remote Integration

For Docker or other remote execution, use `python` for the command and
`path_mappings` when remote paths differ from local paths.

`neotest-python` writes result and stream files inside the mapped project root,
so a normal project mount is enough; no separate `/tmp` or plugin-directory
mount is required.

```lua
require("neotest").setup({
  adapters = {
    require("neotest-python")({
      python = { "docker", "compose", "exec", "-T", "-w", "/app", "web", "python" },
      cwd = vim.fn.getcwd(),
      env = { PYTHONPATH = "/app" },
      path_mappings = {
        [vim.fn.getcwd()] = "/app",
      },
    }),
  },
})
```

### Docker Debugging

For remote debugging, return an attach config from `dap`. Attach configs get
debugpy `pathMappings` from `path_mappings` unless you provide your own.

```lua
require("neotest-python")({
  python = { "docker", "compose", "exec", "-T", "-w", "/app", "web", "python" },
  path_mappings = {
    [vim.fn.getcwd()] = "/app",
  },
  dap = function(_, _, _, context)
    return {
      request = "attach",
      connect = { host = "127.0.0.1", port = 5678 },
      before = function()
        -- Start debugpy in the container here.
        -- `context.remote_script_path` and `context.script_args`
        -- already contain the translated paths for this test run.
      end,
    }
  end,
})
```

If your remote debug flow should not stop on pytest internal exceptions, set
`NEOTEST_PYTHON_DISABLE_POSTMORTEM=1` in the debuggee environment.

`path_mappings` can also be a function, which is useful in monorepos:

```lua
require("neotest-python")({
  python = function(root)
    if root:match("services/api") then
      return { "docker", "exec", "-T", "api-container", "python" }
    end
    return { "python" }
  end,
  path_mappings = function(root)
    if root:match("services/api") then
      return { [root] = "/app" }
    end
    return {}
  end,
})
```
