local t = require('minitest')
local drivetrain = require('extensions/beamRemotePlus/drivetrain')

local function clutch(temp, fields)
  local d = { clutchTemperature = temp, thermalEfficiency = 1, clutchWarningTemp = 200 }
  for k, v in pairs(fields or {}) do d[k] = v end
  return d
end

t.describe('drivetrain clutch thermals', function()
  t.it('reports the temperature, fine below the warning threshold', function()
    local temp, state = drivetrain.clutch({ clutch = clutch(85.4), mainEngine = {} })
    t.assertEquals(temp, 85)
    t.assertNil(state)
  end)
  t.it('hot, overheating then damaged, like the game messages', function()
    t.assertEquals(select(2, drivetrain.clutch({ c = clutch(210) })), 'hot')
    t.assertEquals(select(2, drivetrain.clutch({ c = clutch(260, { thermalEfficiency = 0.8 }) })), 'overheating')
    t.assertEquals(select(2, drivetrain.clutch({ c = clutch(400, { clutchPermanentlyDamaged = true }) })), 'damaged')
  end)
  t.it('keeps the hottest clutch and the worst state', function()
    local temp, state = drivetrain.clutch({ a = clutch(120, { clutchPermanentlyDamaged = true }), b = clutch(220) })
    t.assertEquals(temp, 220)
    t.assertEquals(state, 'damaged')
  end)
  t.it('nothing without a friction clutch (automatic, electric)', function()
    t.assertNil(drivetrain.clutch({ gearbox = { type = 'automaticGearbox' } }))
  end)
end)

t.describe('drivetrain parts', function()
  local devices = {
    mainEngine = { name = 'mainEngine' },
    driveshaft = { name = 'driveshaft', isBroken = true },
    wheelaxleRL = { name = 'wheelaxleRL', isBroken = true },
    wheelaxleRR = { name = 'wheelaxleRR' },
    differential_R = { name = 'differential_R' },
  }
  t.it('lists broken devices, sorted', function()
    local broken = drivetrain.broken(devices)
    t.assertEquals(#broken, 2)
    t.assertEquals(broken[1], 'driveshaft')
    t.assertEquals(broken[2], 'wheelaxleRL')
    t.assertNil(drivetrain.broken({ mainEngine = {} }))
  end)
  t.it('lists the shafts drawn on the schematic', function()
    local shafts = drivetrain.shafts(devices)
    t.assertEquals(#shafts, 3)
    t.assertEquals(shafts[1], 'driveshaft')
    t.assertNil(drivetrain.shafts({ mainEngine = {} }))
  end)
end)

t.describe('engine position', function()
  local function p(y) return { x = 0, y = y, z = 0.5 } end
  -- Car facing -y (BeamNG convention): front bumper at y = -2, rear at 2.
  local nodes = { p(-2), p(-1), p(0), p(1), p(2) }
  t.it('0 = front, 1 = rear', function()
    t.assertEquals(drivetrain.engineAt(p(-1.6), p(-1), p(0), nodes), 0.1)
    t.assertEquals(drivetrain.engineAt(p(1), p(-1), p(0), nodes), 0.75)
  end)
  t.it('nil when unknown', function()
    t.assertNil(drivetrain.engineAt(nil, p(-1), p(0), nodes))
    t.assertNil(drivetrain.engineAt(p(0), p(0), p(0), nodes))
  end)
end)

t.describe('wheelspin and locked wheels', function()
  t.it('spin = tyre faster than the car', function()
    local spin, lock = drivetrain.spinLock({ 10, 18.5, -10 }, 10)
    t.assertEquals(spin, 8.5)
    t.assertEquals(lock, 0)
  end)
  t.it('lock = wheel much slower than the moving car', function()
    local spin, lock = drivetrain.spinLock({ 0, 20, 19 }, 20)
    t.assertEquals(spin, 0)
    t.assertEquals(lock, 20)
    t.assertEquals(select(2, drivetrain.spinLock({ 0 }, 2)), 0)
  end)
end)
