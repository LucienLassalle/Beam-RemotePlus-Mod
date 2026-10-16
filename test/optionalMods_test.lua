local t = require('minitest')
local optionalMods = require('/lua/ge/extensions/beamRemotePlus/optionalMods')

-- mods: core_modmanager.getMods() content; files: paths present in the
-- game's virtual file system.
local function setup(mods, files)
  local env = { mods = mods or {}, files = files or {} }
  env.registry = optionalMods.new({
    getMods = function() return env.mods end,
    fileExists = function(path) return env.files[path] == true end,
  })
  env.registry.refresh()
  return env
end

local function repoMod(tagid, active) return { active = active, modData = { tagid = tagid } } end

t.describe('optional mods: installed state', function()
  t.it('finds repository mods by their id, enabled or not', function()
    local env = setup({
      f4_lucasbe = repoMod('MYSB93TC7', true),
      cf26 = repoMod('MSH2WZ9QV', false),
      ['tyre-thermals-and-wear'] = repoMod('MXFQY32S5', true),
    })
    t.assertEquals(env.registry.state('f4'), optionalMods.ENABLED)
    t.assertEquals(env.registry.state('cf26'), optionalMods.DISABLED)
    t.assertEquals(env.registry.state('tyreThermals'), optionalMods.ENABLED)
    t.assertEquals(env.registry.state('fr17'), optionalMods.MISSING)
  end)
  t.it('knows both versions of the tyre mod', function()
    t.assertEquals(setup({ luuk = repoMod('MDQKSX6UR', true) }).registry.state('tyreThermals'), optionalMods.ENABLED)
    t.assertEquals(setup({ redux = repoMod('MXFQY32S5', true) }).registry.state('tyreThermals'), optionalMods.ENABLED)
  end)
  t.it('finds a mod installed by hand by one of its files', function()
    local env = setup({ handmade = { active = true } }, { ['/vehicles/FR17/FR17.jbeam'] = true })
    t.assertEquals(env.registry.state('fr17'), optionalMods.ENABLED)
  end)
  t.it('an enabled copy wins over a disabled one', function()
    local env = setup({ a = repoMod('MCSAUJ2PR', false), b = repoMod('MCSAUJ2PR', true) })
    t.assertEquals(env.registry.state('fr17'), optionalMods.ENABLED)
  end)
  t.it('everything is missing while the mod manager is unavailable', function()
    local env = setup(nil)
    env.mods = nil
    env.registry.refresh()
    for _, mod in ipairs(env.registry.list()) do t.assertEquals(mod.state, optionalMods.MISSING) end
  end)
  t.it('survives a crashing mod manager', function()
    local registry = optionalMods.new({ getMods = function() error('boom') end, fileExists = function() return false end })
    t.assertTrue(registry.refresh())
    t.assertEquals(registry.state('f4'), optionalMods.MISSING)
  end)
end)

t.describe('optional mods: changes and lists', function()
  t.it('tells when a state changed, only then', function()
    local env = setup({ cf26 = repoMod('MSH2WZ9QV', false) })
    t.assertFalse(env.registry.refresh())
    env.mods.cf26.active = true
    t.assertTrue(env.registry.refresh())
    t.assertEquals(env.registry.state('cf26'), optionalMods.ENABLED)
  end)
  t.it('lists every supported mod in catalog order, and as a map', function()
    local env = setup({ fr17 = repoMod('MCSAUJ2PR', true) })
    local list = env.registry.list()
    t.assertEquals(#list, #optionalMods.CATALOG)
    t.assertEquals(list[1].id, 'tyreThermals')
    t.assertEquals(list[1].state, optionalMods.MISSING)
    t.assertEquals(list[4].id, 'fr17')
    t.assertEquals(env.registry.states().fr17, optionalMods.ENABLED)
  end)
end)
