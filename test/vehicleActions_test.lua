local t = require('minitest')
local vehicleActions = require('/lua/ge/extensions/beamRemotePlus/vehicleActions')

local ACTIONS = {
  pigeon__toggle_tailgate = { vehicle = 'pigeon', cat = 'vehicle_specific', order = 1, onDown = 'x',
    title = 'ui.inputActions.pigeon.toggle_tailgate.title' },
  pigeon__crane = { vehicle = 'pigeon', cat = 'vehicle_specific', order = 2, onChange = 'y', title = 'Crane up' },
  pigeon__boom = { vehicle = 'pigeon', cat = 'vehicle_specific', onChange = 'z', isCentered = true, title = 'Boom' },
  pigeon__locked = { vehicle = 'pigeon', cat = 'vehicle_specific_unusable', onDown = 'w', title = 'Locked' },
  covet__other = { vehicle = 'covet', cat = 'vehicle_specific', onDown = 'v', title = 'Other car' },
  horn = { cat = 'vehicle', onDown = 'h', title = 'Horn' },
}

local function translate(key)
  if key == 'ui.inputActions.pigeon.toggle_tailgate.title' then return 'Toggle tailgate' end
  return key
end

t.describe('vehicle actions', function()
  t.it('lists the usable one-way actions of the vehicle, in their order', function()
    local list = vehicleActions.vehicleEntries(ACTIONS, 'pigeon', translate)
    t.assertEquals(#list, 2)
    t.assertEquals(list[1].id, 'v:toggle_tailgate')
    t.assertEquals(list[1].title, 'Toggle tailgate')
    t.assertEquals(list[1].kind, 'press')
    t.assertEquals(list[2].id, 'v:crane')
    t.assertEquals(list[2].kind, 'hold')
    t.assertNil(list[1].order)
  end)
  t.it('falls back to the action name for an untranslated key', function()
    local list = vehicleActions.vehicleEntries(ACTIONS, 'pigeon', nil)
    t.assertEquals(list[1].title, 'toggle_tailgate')
    t.assertEquals(list[2].title, 'Crane up')
  end)
  t.it('lists nothing for a vehicle without actions', function()
    t.assertEquals(#vehicleActions.vehicleEntries(ACTIONS, 'etk800', translate), 0)
    t.assertEquals(#vehicleActions.vehicleEntries(nil, 'etk800', translate), 0)
  end)
  t.it('keeps the generic ids it knows, in the vehicle order', function()
    local list = vehicleActions.genericEntries({ 'four_wd', 'warp_drive', 'couplers' })
    t.assertEquals(#list, 2)
    t.assertEquals(list[1].id, 'g:four_wd')
    t.assertEquals(list[2].id, 'g:couplers')
    t.assertEquals(list[2].kind, 'press')
  end)
end)
