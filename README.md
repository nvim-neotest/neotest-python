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
      -- Bi-directional path mapping for Docker/Remote integration.
      -- Can be a table or a function to return dynamic values.
      path_mappings = {
        ["/host/project/path"] = "/container/project/path",
        ["/tmp"] = "/tmp",
      },
    }),
  },
})
```

### Pytest-xdist

`neotest-python` does not require Docker and does not manage worker counts
itself. If you use `pytest-xdist`, just pass the usual pytest flags through
`args`:

```lua
require("neotest-python")({
  runner = "pytest",
  args = { "-n", "auto", "--dist", "loadfile" },
})
```

Those arguments are forwarded unchanged to pytest, including when running
through Docker or other remote Python commands.

### Docker/Remote Integration

To run tests in a Docker container or any remote environment, use the `python`
and `path_mappings` options. `neotest-python` will translate host paths (where
Neovim runs) to container paths (where tests run) and back again.

Example using `docker-compose`:

```lua
require("neotest").setup({
  adapters = {
    require("neotest-python")({
      -- Command to run python in the container
      python = { "docker-compose", "exec", "-T", "web", "python" },
      cwd = vim.fn.getcwd(),
      env = {
        PYTHONPATH = "/app",
      },

      -- Map host paths to container paths
      path_mappings = {
        [vim.fn.getcwd()] = "/app",
        -- Mount /tmp so host-container communication (results/streaming) works.
        -- On macOS, `/tmp` mappings also cover the resolved `$TMPDIR` path.
        ["/tmp"] = "/tmp",
      },
    }),
  },
})
```

By making `path_mappings` a function, you can dynamically resolve mounts:

```lua
path_mappings = function()
  -- Logic to query docker inspect or docker-compose for volume mounts
  return {
    [vim.fn.getcwd()] = "/workspace",
  }
end
```

### Monorepo Support

In monorepos where different subdirectories require different containers or
settings, you can either use a single dynamic adapter or multiple adapter
instances.

#### Dynamic Configuration

You can pass the `root` directory to both `python` and `path_mappings` to
dynamically determine the configuration:

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

#### Multiple Instances

You can also override `root` detection to have multiple instances of the
adapter for different parts of your monorepo:

```lua
require("neotest").setup({
  adapters = {
    require("neotest-python")({
      root = function(path)
        return path:match("services/api") and require("neotest-python.base").get_root(path)
      end,
      python = { "docker", "exec", "-T", "api-container", "python" },
      path_mappings = { ["services/api"] = "/app" },
    }),
    require("neotest-python")({
      root = function(path)
        return path:match("services/worker") and require("neotest-python.base").get_root(path)
      end,
      python = { "docker", "exec", "-T", "worker-container", "python" },
      path_mappings = { ["services/worker"] = "/app" },
    }),
  },
})
```
