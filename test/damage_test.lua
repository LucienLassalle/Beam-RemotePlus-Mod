local t = require('minitest')
local damage = require('extensions/beamRemotePlus/damage')

local function reader(values)
  return function(group, name) return values[group .. '.' .. name] end
end

t.describe('vehicle damage summary', function()
  t.it('is empty for a pristine car', function()
    local d = damage.collect(reader({ ['body.FL'] = 0 }), { 'FL', 'FR' })
    t.assertNil(d.bodyDamage)
    t.assertNil(d.engineDamage)
    t.assertNil(d.flatTires)
  end)
  t.it('reports body zones, engine failures, flat tyres and hot brakes', function()
    local d = damage.collect(reader({
      ['body.FL'] = 0.4567, ['body.RR'] = 2, ['engine.radiatorLeak'] = true,
      ['engine.oilpanLeak'] = false, ['wheels.tireFR'] = true, ['wheels.brakeOverHeatRL'] = 1,
    }), { 'FL', 'FR', 'RL', 'RR' })
    t.assertEquals(d.bodyDamage.FL, 0.46)
    t.assertEquals(d.bodyDamage.RR, 1)
    t.assertNil(d.bodyDamage.FR)
    t.assertEquals(#d.engineDamage, 1)
    t.assertEquals(d.engineDamage[1], 'radiatorLeak')
    t.assertEquals(d.flatTires[1], 'FR')
    t.assertEquals(d.hotBrakes[1], 'RL')
  end)
end)
