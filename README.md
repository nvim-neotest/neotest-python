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
        dap = { justMyCode = false },
        -- Command line arguments for runner
        -- Can also be a function to return dynamic values
        args = {"--log-level", "DEBUG"},
        -- Runner to use. Will use pytest if available by default.
        -- Can be a function to return dynamic value.
        runner = "pytest",

        -- Returns if a given file path is a test file.
        -- NB: This function is called a lot so don't perform any heavy tasks within it.
        is_test_file = function(file_path)
          ...
        end,
        
    })
  }
})

```
