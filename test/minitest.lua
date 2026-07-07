-- Micro-framework de test autonome (aucune dépendance externe), pensé
-- pour tourner avec `luajit` en dehors du jeu.
local M = {}

local passed = 0
local failed = 0
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

function M.assertEquals(actual, expected, message)
  if actual ~= expected then
    error(string.format(
      '%sattendu %s, obtenu %s',
      message and (message .. ': ') or '',
      tostring(expected), tostring(actual)
    ), 2)
  end
end

function M.assertTrue(value, message)
  if not value then
    error(message or 'attendu true, obtenu ' .. tostring(value), 2)
  end
end

function M.assertFalse(value, message)
  if value then
    error(message or 'attendu false, obtenu ' .. tostring(value), 2)
  end
end

function M.assertNil(value, message)
  if value ~= nil then
    error(message or ('attendu nil, obtenu ' .. tostring(value)), 2)
  end
end

function M.assertNotNil(value, message)
  if value == nil then
    error(message or 'attendu une valeur non-nil', 2)
  end
end

function M.assertCloseTo(actual, expected, tolerance, message)
  tolerance = tolerance or 1e-4
  if math.abs(actual - expected) > tolerance then
    error(string.format(
      '%sattendu ~%s (+/- %s), obtenu %s',
      message and (message .. ': ') or '', tostring(expected), tostring(tolerance), tostring(actual)
    ), 2)
  end
end

function M.summary()
  print(string.format('\n%d passés, %d échoués', passed, failed))
  os.exit(failed == 0 and 0 or 1)
end

return M
