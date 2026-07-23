local nio = require("nio")

local M = {}

local function trim(path)
  if type(path) ~= "string" or path == "" or path == "/" then
    return path
  end

  return path:gsub("/+$", "")
end

local function resolve(path)
  if type(path) ~= "string" or path == "" then
    return path
  end

  local ok, resolved = pcall(vim.fn.resolve, path)
  if ok and resolved ~= "" then
    path = resolved
  end

  return trim(path)
end

local function sorted_keys(paths)
  local keys = {}
  for path in pairs(paths) do
    table.insert(keys, path)
  end
  table.sort(keys, function(a, b)
    return #a > #b
  end)
  return keys
end

---@param raw_mappings table<string, string>|nil
---@return { forward: table<string, string>, reverse: table<string, string>, forward_keys: string[], reverse_keys: string[] }
function M.normalize(raw_mappings)
  local mappings = {
    forward = {},
    reverse = {},
    forward_keys = {},
    reverse_keys = {},
  }

  for host_path, remote_path in pairs(raw_mappings or {}) do
    host_path = resolve(host_path)
    remote_path = trim(remote_path)
    if host_path and remote_path then
      mappings.forward[host_path] = remote_path
      mappings.reverse[remote_path] = host_path
    end
  end

  mappings.forward_keys = sorted_keys(mappings.forward)
  mappings.reverse_keys = sorted_keys(mappings.reverse)

  return mappings
end

local function translate(path, paths, keys)
  if not path then
    return path
  end

  for _, from_path in ipairs(keys or {}) do
    if path:sub(1, #from_path) == from_path then
      local next_char = path:sub(#from_path + 1, #from_path + 1)
      if next_char == "" or next_char == "/" then
        local suffix = path:sub(#from_path + 1)
        local mapped_path = trim(paths[from_path])
        if suffix == "" then
          return mapped_path
        end
        if mapped_path == "/" then
          return "/" .. suffix:gsub("^/", "")
        end
        return mapped_path .. suffix
      end
    end
  end

  return path
end

---@param path string
---@param mappings { forward: table<string, string>, forward_keys: string[] }
---@return string
function M.to_remote(path, mappings)
  if not mappings then
    return path
  end
  return translate(path, mappings.forward, mappings.forward_keys)
end

---@param path string
---@param mappings { reverse: table<string, string>, reverse_keys: string[] }
---@return string
function M.to_host(path, mappings)
  if not mappings then
    return path
  end
  return translate(path, mappings.reverse, mappings.reverse_keys)
end

---@param root string
---@param mappings { forward: table<string, string>, forward_keys: string[] }
---@return string
function M.tempname(root, mappings)
  root = resolve(root)
  local path = nio.fn.tempname()
  if root and M.to_remote(root, mappings) ~= root then
    return root .. "/.neotest-python-" .. path:match("[^/]+$")
  end

  return resolve(path)
end

---@param mappings { forward: table<string, string>, forward_keys: string[] }
---@return { localRoot: string, remoteRoot: string }[]
function M.to_dap_path_mappings(mappings)
  local path_mappings = {}
  for _, local_root in ipairs(mappings and mappings.forward_keys or {}) do
    path_mappings[#path_mappings + 1] = {
      localRoot = local_root,
      remoteRoot = mappings.forward[local_root],
    }
  end
  return path_mappings
end

return M
