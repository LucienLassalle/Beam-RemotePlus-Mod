-- Static checks of the files BeamNG loads directly (no Lua module behind
-- them): translations, input actions, UI app, and syntax of every Lua file.
local t = require('minitest')
local i18n = require('/lua/ge/extensions/beamRemotePlus/i18n')

local testDir = arg[0]:match('(.*/)') or './'
local src = testDir .. '../src/'

local function read(path)
  local f = assert(io.open(src .. path, 'rb'), 'missing file ' .. path)
  local content = f:read('*a')
  f:close()
  return content
end

local function translationKeys(path)
  local keys = {}
  for key in read(path):gmatch('"([^"]+)"%s*:') do keys[key] = true end
  return keys
end

local function luaFiles()
  local files = {}
  local p = io.popen('cd "' .. src .. '" && find . -name "*.lua"')
  for line in p:lines() do files[#files + 1] = line:sub(3) end
  p:close()
  return files
end

local en = translationKeys('locales/translations/en-US/beamRemotePlus.translation.json')
local fr = translationKeys('locales/translations/fr_FR/beamRemotePlus.translation.json')

t.describe('assets: translations', function()
  t.it('English and French define exactly the same keys', function()
    for k in pairs(en) do t.assertTrue(fr[k], 'missing in fr_FR: ' .. k) end
    for k in pairs(fr) do t.assertTrue(en[k], 'missing in en-US: ' .. k) end
  end)
  t.it('every Lua fallback string has a translation', function()
    for k in pairs(i18n.FALLBACK) do t.assertTrue(en[k], 'not translated: ' .. k) end
  end)
  t.it('input actions and UI app only use translated keys', function()
    for _, path in ipairs({ 'lua/ge/extensions/core/input/actions/beamRemotePlus.json',
      'ui/modules/apps/BeamRemotePlus/app.json', 'ui/modules/apps/BeamRemotePlus/app.js' }) do
      for key in read(path):gmatch('[\'"]((ui%.inputActions%.beamRemotePlus[%w%.]+))[\'"]') do
        t.assertTrue(en[key], path .. ' uses untranslated ' .. key)
      end
      for key in read(path):gmatch('[\'"](beamRemotePlus%.[%w%.]+)[\'"]') do
        t.assertTrue(en[key], path .. ' uses untranslated ' .. key)
      end
    end
  end)
end)

t.describe('assets: game integration', function()
  t.it('the input action calls existing public functions', function()
    local main = read('lua/ge/extensions/beamRemotePlus/main.lua')
    for fn in read('lua/ge/extensions/core/input/actions/beamRemotePlus.json'):gmatch('beamRemotePlus_main%.(%w+)%(') do
      t.assertContains(main, 'M.' .. fn .. ' = ', 'action calls missing function')
    end
  end)
  t.it('modScript flags the extension as manual (official pattern)', function()
    t.assertContains(read('scripts/modScript.lua'), "setExtensionUnloadMode(extName, 'manual')")
  end)
  t.it('the input map file name matches the virtual device vidpid', function()
    local clients = require('/lua/ge/extensions/beamRemotePlus/clients')
    t.assertNotNil(read('settings/inputmaps/' .. clients.VIDPID .. '.json'))
  end)
  t.it('every Lua file compiles', function()
    local files = luaFiles()
    t.assertTrue(#files >= 12)
    for _, file in ipairs(files) do
      local ok, err = loadfile(src .. file)
      t.assertTrue(ok, tostring(err))
    end
  end)
end)
