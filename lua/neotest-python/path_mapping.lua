local logger = require("neotest.logging")
local M = {}

---@param path string|nil
---@return string|nil
local function trim_trailing_separators(path)
  if type(path) ~= "string" or path == "" then
    return path
  end
  if path == "/" then
    return path
  end
  path = path:gsub("/+$", "")
  return path == "" and "/" or path
end

---@param path string|nil
---@return string|nil
local function resolve_host_path(path)
  if type(path) ~= "string" or path == "" then
    return path
  end

  local ok, resolved = pcall(vim.fn.resolve, path)
  if ok and resolved ~= "" then
    path = resolved
  end

  return trim_trailing_separators(path)
end

---@return string[]
local function get_temp_roots()
  local uv = vim.uv or vim.loop
  local candidates = {}
  local seen = {}

  local function add(path)
    local normalized = resolve_host_path(path)
    if normalized and normalized ~= "" and not seen[normalized] then
      seen[normalized] = true
      table.insert(candidates, normalized)
    end
  end

  add(uv and uv.os_getenv and uv.os_getenv("TMPDIR") or nil)
  add(uv and uv.os_tmpdir and uv.os_tmpdir() or nil)
  add("/tmp")

  return candidates
end

---@param host_path string
---@param temp_roots string[]
---@return boolean
local function is_temp_mapping(host_path, temp_roots)
  local raw_path = trim_trailing_separators(host_path)
  local resolved_path = resolve_host_path(host_path)

  if raw_path == "/tmp" then
    return true
  end

  for _, temp_root in ipairs(temp_roots) do
    if raw_path == temp_root or resolved_path == temp_root then
      return true
    end
  end

  return false
end

---@param mappings table<string, string>
---@return table<string, string>
local function get_forward_mappings(mappings)
  if mappings and mappings.forward then
    return mappings.forward
  end
  return mappings or {}
end

---@param mappings table<string, string>
---@return table<string, string>
local function get_reverse_mappings(mappings)
  if mappings and mappings.reverse then
    return mappings.reverse
  end

  local inverse_mappings = {}
  for host_path, container_path in pairs(mappings or {}) do
    inverse_mappings[trim_trailing_separators(container_path)] = resolve_host_path(host_path)
  end
  return inverse_mappings
end

---@param mappings table<string, string>
---@return string[]
local function get_sorted_keys(mappings)
  local keys = {}
  for k in pairs(mappings) do
    table.insert(keys, k)
  end
  table.sort(keys, function(a, b)
    return #a > #b
  end)
  return keys
end

---Normalize path mappings for host->container and container->host translation.
---Temp mappings are expanded so a simple `/tmp -> /tmp` config also matches
---macOS temp files created under the resolved `$TMPDIR`.
---@param raw_mappings table<string, string>|nil
---@return { forward: table<string, string>, reverse: table<string, string> }
function M.normalize_mappings(raw_mappings)
  raw_mappings = raw_mappings or {}

  local mappings = {
    forward = {},
    reverse = {},
  }
  local temp_roots = get_temp_roots()
  local preferred_temp_root = temp_roots[1]

  for host_path, container_path in pairs(raw_mappings) do
    local resolved_host_path = resolve_host_path(host_path)
    local normalized_container_path = trim_trailing_separators(container_path)

    if resolved_host_path and normalized_container_path then
      mappings.forward[resolved_host_path] = normalized_container_path

      if is_temp_mapping(host_path, temp_roots) then
        for _, temp_root in ipairs(temp_roots) do
          mappings.forward[temp_root] = normalized_container_path
        end
        mappings.reverse[normalized_container_path] = preferred_temp_root or resolved_host_path
      else
        mappings.reverse[normalized_container_path] = resolved_host_path
      end
    end
  end

  return mappings
end

---Translates a host file path to its corresponding path in the container.
---@param path string The host file path.
---@param mappings table<string, string> Map of host paths to container paths.
---@return string The translated container path.
function M.to_container_path(path, mappings)
  if not mappings or not path then
    return path
  end
  local forward_mappings = get_forward_mappings(mappings)
  local sorted_host_paths = get_sorted_keys(forward_mappings)
  for _, host_path in ipairs(sorted_host_paths) do
    local container_path = forward_mappings[host_path]
    -- Use plain string matching for prefix to avoid regex escaping issues
    if path:sub(1, #host_path) == host_path then
      local next_char = path:sub(#host_path + 1, #host_path + 1)
      -- Check if the match is at a path boundary (slash or end of string)
      if next_char == "" or next_char == "/" or host_path:sub(-1) == "/" then
        local suffix = path:sub(#host_path + 1)
        -- Ensure exactly one slash between container_path and suffix if suffix is not empty
        local result = container_path
        if suffix ~= "" then
          if suffix:sub(1, 1) ~= "/" and container_path:sub(-1) ~= "/" then
            result = result .. "/"
          end
          result = result .. suffix
        end
        -- Clean up double slashes
        result = result:gsub("//+", "/")
        logger.debug("neotest-python: Translated Host Path: ", path, " to Container: ", result)
        return result
      end
    end
  end
  logger.debug("neotest-python: No mapping found for host path: ", path)
  return path
end

---Translates a container file path back to its corresponding path on the host.
---@param path string The container file path.
---@param mappings table<string, string> Map of host paths to container paths.
---@return string The translated host path.
function M.to_host_path(path, mappings)
  if not mappings or not path then
    return path
  end
  local inverse_mappings = get_reverse_mappings(mappings)
  local sorted_container_paths = get_sorted_keys(inverse_mappings)

  for _, container_path in ipairs(sorted_container_paths) do
    local host_path = inverse_mappings[container_path]
    if path:sub(1, #container_path) == container_path then
      local next_char = path:sub(#container_path + 1, #container_path + 1)
      if next_char == "" or next_char == "/" or container_path:sub(-1) == "/" then
        local suffix = path:sub(#container_path + 1)
        local result = host_path
        if suffix ~= "" then
          if suffix:sub(1, 1) ~= "/" and host_path:sub(-1) ~= "/" then
            result = result .. "/"
          end
          result = result .. suffix
        end
        result = result:gsub("//+", "/")
        logger.debug("neotest-python: Translated Container Path: ", path, " to Host: ", result)
        return result
      end
    end
  end
  logger.debug("neotest-python: No mapping found for container path: ", path)
  return path
end

return M
