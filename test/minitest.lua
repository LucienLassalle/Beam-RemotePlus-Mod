-- Tiny dependency-free test framework, runs with a plain `luajit`.
local M = {}

local passed, failed = 0, 0
local currentGroup = ''

function M.describe(name, fn)
  currentGroup = name
  fn()
end

function M.it(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print(string.format('  [PASS] %s > %s', currentGroup, name))
  else
    failed = failed + 1
    print(string.format('  [FAIL] %s > %s', currentGroup, name))
    print('         ' .. tostring(err))
  end
end

local function fmt(message, text)
  return (message and (message .. ': ') or '') .. text
end

function M.assertEquals(actual, expected, message)
  if actual ~= expected then
    error(fmt(message, string.format('expected %s, got %s', tostring(expected), tostring(actual))), 2)
  end
end

function M.assertTrue(value, message)
  if not value then error(fmt(message, 'expected true, got ' .. tostring(value)), 2) end
end

function M.assertFalse(value, message)
  if value then error(fmt(message, 'expected false, got ' .. tostring(value)), 2) end
end

function M.assertNil(value, message)
  if value ~= nil then error(fmt(message, 'expected nil, got ' .. tostring(value)), 2) end
end

function M.assertNotNil(value, message)
  if value == nil then error(fmt(message, 'expected a non-nil value'), 2) end
end

function M.assertCloseTo(actual, expected, tolerance, message)
  tolerance = tolerance or 1e-4
  if type(actual) ~= 'number' or math.abs(actual - expected) > tolerance then
    error(fmt(message, string.format('expected ~%s (+/- %s), got %s',
      tostring(expected), tostring(tolerance), tostring(actual))), 2)
  end
end

function M.assertContains(haystack, needle, message)
  if type(haystack) ~= 'string' or not haystack:find(needle, 1, true) then
    error(fmt(message, string.format('expected %q to contain %q', tostring(haystack), needle)), 2)
  end
end

function M.results() return passed, failed end

function M.summary()
  print(string.format('\n%d passed, %d failed', passed, failed))
  os.exit(failed == 0 and 0 or 1)
end

return M
