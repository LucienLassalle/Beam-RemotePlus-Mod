local t = require('minitest')
local tyres = require('extensions/beamRemotePlus/tyres')

local stream = { data = {
  { name = 'FL', temp = { 80.04, 82, 84, 70 }, avg_temp = 81.96, condition = 97.5, working_temp = 85, brake_temp = 300 },
  { name = 'FR', temp = {}, avg_temp = 60 },
} }

t.describe('tyre-thermals integration', function()
  t.it('normalizes the tyre mod stream', function()
    local n = tyres.normalize(stream)
    t.assertEquals(n.FL.temp, 82)
    t.assertEquals(n.FL.core, 70)
    t.assertEquals(n.FL.surface[1], 80)
    t.assertEquals(n.FL.condition, 97.5)
    t.assertEquals(n.FL.working, 85)
    t.assertEquals(n.FR.temp, 60)
    t.assertNil(n.FR.core)
    t.assertNil(n.FR.surface)
  end)
  t.it('ignores anything else', function()
    t.assertNil(tyres.normalize(nil))
    t.assertNil(tyres.normalize({ data = {} }))
  end)
  t.it('listens to gui.send without changing it, once', function()
    local received = {}
    local gui = { send = function(name, data) received[#received + 1] = name return 'ok' end }
    t.assertTrue(tyres.install(gui))
    t.assertFalse(tyres.install(gui)) -- wrapper installed only once, sink refreshed
    t.assertEquals(gui.send('TyreWearThermals', stream), 'ok')
    gui.send('Other', {})
    t.assertEquals(#received, 2)
    t.assertEquals(tyres.read().FL.temp, 82)
  end)
  t.it('forgets data older than 2 s (tyre mod disabled or vehicle changed)', function()
    tyres._set(stream, 0)
    t.assertNil(tyres.read(10))
    t.assertNotNil(tyres.read(1))
  end)
end)
