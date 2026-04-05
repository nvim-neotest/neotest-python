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
        args = {"--log-level", "DEBUG"},
        -- Runner to use. Will use pytest if available by default.
        -- Can be a function to return dynamic value.
        runner = "pytest",
        -- Custom python path for the runner.
        -- Can be a string or a list of strings.
        -- Can also be a function to return dynamic value.
        -- If not provided, the path will be inferred by checking for 
        -- virtual envs in the local directory and for Pipenev/Poetry configs
        python = ".venv/bin/python",
        -- Returns if a given file path is a test file.
        -- NB: This function is called a lot so don't perform any heavy tasks within it.
        is_test_file = function(file_path)
          ...
        end,
        -- !!EXPERIMENTAL!! Enable shelling out to `pytest` to discover test
        -- instances for files containing a parametrize mark (default: false)
        pytest_discover_instances = true,
        -- Docker configuration for running tests in containers
        docker = {
          -- Docker container name or ID (required if using container-based execution)
          container = "my-python-container",
          -- OR use Docker image name instead of container
          -- image = "python:3.9",
          -- Custom docker command prefix (default: ["docker", "exec"])
          command = {"docker", "exec"},
          -- Additional docker arguments (e.g., interactive mode, working directory)
          args = {"-i", "-w", "/app"},
          -- Working directory inside container (default: "/app")
          workdir = "/app",
        },
    })
  }
})

```

## Docker Support

This adapter supports running tests inside Docker containers, which is useful for projects that are developed or deployed in containerized environments.

### Configuration

To enable Docker support, configure the `docker` option in your neotest setup:

```lua
require("neotest").setup({
  adapters = {
    require("neotest-python")({
      docker = {
        container = "my-python-container",  -- Required: container name or ID
        args = {"-i", "-w", "/app"},        -- Optional: additional docker arguments
        workdir = "/app",                   -- Optional: working directory (default: "/app")
      }
    })
  }
})
```

### Docker Options

- **`container`** (string): Name or ID of a running Docker container where tests will be executed
- **`image`** (string): Alternatively, specify a Docker image name to run tests in a new container
- **`command`** (table): Custom docker command prefix (default: `{"docker", "exec"}`)
- **`args`** (table): Additional arguments passed to the docker command (e.g., `{"-i", "-w", "/app"}`)
- **`workdir`** (string): Working directory inside the container (default: `"/app"`)

### Requirements

- Docker must be installed and accessible from your system
- The specified container must be running (when using `container` option)
- The container must have Python and your test dependencies installed
- Your project files must be mounted or copied into the container

### Example Configurations

#### Using an existing container:
```lua
docker = {
  container = "web-app",
  args = {"-i"},
  workdir = "/workspace"
}
```

#### Using a Docker image (creates temporary containers):
```lua
docker = {
  image = "python:3.9-slim",
  args = {"-v", "/host/project:/app", "-w", "/app"},
  workdir = "/app"
}
```
