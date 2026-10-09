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
  t.it('reports molten brakes, torn off wheels and a leaking fuel tank', function()
    local d = damage.collect(reader({
      ['wheels.brakeFL'] = true, ['wheels.RR'] = true, ['energyStorage.mainTank'] = true,
    }), { 'FL', 'FR', 'RL', 'RR' }, { 'mainTank' })
    t.assertEquals(d.brokenBrakes[1], 'FL')
    t.assertEquals(d.brokenWheels[1], 'RR')
    t.assertTrue(d.fuelLeak)
    t.assertNil(damage.collect(reader({}), { 'FL' }, { 'mainTank' }).fuelLeak)
  end)
  t.it('reports a damaged traction battery', function()
    local d = damage.collect(reader({ ['energyStorage.mainBattery'] = true }), {}, {}, { 'mainBattery' })
    t.assertTrue(d.batteryDamaged)
    t.assertNil(d.fuelLeak)
  end)
  t.it('relays the live engine dangers and grinding gears', function()
    local d = damage.collect(reader({
      ['engine.turbochargerHot'] = true, ['engine.overRevDanger'] = true, ['gearbox.synchroWear'] = true,
    }), {})
    t.assertEquals(#d.engineDamage, 2)
    t.assertTrue(d.gearGrinding)
  end)
end)
