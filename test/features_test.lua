local t = require('minitest')
local features = require('extensions/beamRemotePlus/features')

-- controller.getControllersByType of a vehicle fitted with these types.
local function controllers(types)
  local set = {}
  for _, name in ipairs(types) do set[name] = true end
  return function(controllerType) return set[controllerType] and { {} } or {} end
end

t.describe('vehicle features', function()
  t.it('always offers the fog lights and the trailer coupler', function()
    t.assertEquals(table.concat(features.collect(controllers({}), {}), ','), 'fog_lights,couplers')
  end)
  t.it('4WD with a range box and lockable differentials', function()
    local list = features.collect(controllers({ '4wd' }), { r = { type = 'rangeBox' } })
    t.assertEquals(table.concat(list, ','), 'fog_lights,four_wd,range,diff_lock,couplers')
  end)
  t.it('no range without the 4WD controller that switches it', function()
    local list = features.collect(controllers({}), { r = { type = 'rangeBox' } })
    t.assertEquals(table.concat(list, ','), 'fog_lights,couplers')
  end)
  t.it('a differential with several modes can be locked without 4WD', function()
    local diff = { type = 'differential', defaultToggle = true, availableModes = { 'open', 'locked' } }
    t.assertEquals(table.concat(features.collect(controllers({}), { d = diff }), ','), 'fog_lights,diff_lock,couplers')
    diff.availableModes = { 'open' }
    t.assertEquals(table.concat(features.collect(controllers({}), { d = diff }), ','), 'fog_lights,couplers')
  end)
  t.it('drag and emergency equipment', function()
    local list = features.collect(controllers({ 'twoStepLaunch', 'braking/transbrake', 'lineLock', 'nitrousOxideInjection', 'lightbar' }), {})
    t.assertEquals(table.concat(list, ','), 'fog_lights,two_step,transbrake,line_lock,nitrous,lightbar_mode,couplers')
  end)
  t.it('survives a vehicle without controllers', function()
    t.assertEquals(#features.collect(nil, nil), 2)
  end)
end)
