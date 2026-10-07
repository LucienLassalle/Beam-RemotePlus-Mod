-- Minimal JSON encoder used for protocol v2 messages.
--
-- BeamNG ships jsonEncode(), but having our own keeps the protocol layer
-- testable outside the game and guarantees the output never contains
-- NaN/inf (invalid JSON that would make the app drop the whole frame).

local M = {}

local escapes = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function encodeNumber(n)
  if n ~= n or n == math.huge or n == -math.huge then return 'null' end
  if n == math.floor(n) and math.abs(n) < 1e15 then
    return string.format('%d', n)
  end
  return string.format('%.4f', n):gsub('0+$', ''):gsub('%.$', '')
end

local function isArray(t)
  local count = 0
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
    count = count + 1
  end
  return count == #t
end

local encode

local function encodeTable(t, depth)
  if depth > 16 then error('json: nesting too deep') end
  local parts = {}
  local mt = getmetatable(t)
  if (mt and mt.__jsonArray and next(t) == nil) or (next(t) ~= nil and isArray(t)) then
    for i = 1, #t do parts[i] = encode(t[i], depth + 1) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = tostring(k) end
  table.sort(keys) -- deterministic output (stable tests, easier diffing)
  for _, k in ipairs(keys) do
    local v = t[k]
    if v == nil then v = t[tonumber(k)] end
    parts[#parts + 1] = encodeString(k) .. ':' .. encode(v, depth + 1)
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

encode = function(v, depth)
  local kind = type(v)
  if kind == 'nil' then return 'null' end
  if kind == 'boolean' then return v and 'true' or 'false' end
  if kind == 'number' then return encodeNumber(v) end
  if kind == 'string' then return encodeString(v) end
  if kind == 'table' then return encodeTable(v, depth or 0) end
  error('json: cannot encode ' .. kind)
end

function M.encode(v)
  return encode(v, 0)
end

return M
