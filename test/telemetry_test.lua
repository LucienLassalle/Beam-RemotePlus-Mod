local t = require('minitest')
local fakes = require('fakes')
local clientsModule = require('/lua/ge/extensions/beamRemotePlus/clients')
local telemetryModule = require('/lua/ge/extensions/beamRemotePlus/telemetry')

local function setup()
  local clock = fakes.clock()
  local vehicles = { [0] = fakes.vehicle(11, 'scintilla'), [1] = fakes.vehicle(22, 'bolide') }
  local sent = {}
  local registry = clientsModule.new(fakes.input(), clock.fn)
  local telemetry = telemetryModule.new({
    getVehicle = function(player) return vehicles[player] end,
    send = function(client, payload) sent[#sent + 1] = { ip = client.ip, payload = payload } end,
    clock = clock.fn,
    intervalMs = 33,
  })
  return telemetry, registry, vehicles, sent, clock
end

t.describe('telemetry router', function()
  t.it('requests nothing for phones without an assigned player', function()
    local telemetry, registry = setup()
    registry.connect('a', { version = 2 })
    t.assertEquals(telemetry.tick(registry), 0)
  end)
  t.it('requests each followed vehicle once, even with two phones on it', function()
    local telemetry, registry, vehicles = setup()
    registry.connect('a', { version = 2 }).player = 0
    registry.connect('b', { version = 2 }).player = 0
    registry.connect('c', { version = 2 }).player = 1
    t.assertEquals(telemetry.tick(registry), 2)
    t.assertContains(vehicles[0].commands[1], "extensions.reload('beamRemotePlus_telemetry')")
    t.assertContains(vehicles[0].commands[1], telemetryModule.LOAD_STAMP)
  end)
  t.it('respects the request interval', function()
    local telemetry, registry, _, _, clock = setup()
    registry.connect('a', { version = 2 }).player = 0
    t.assertEquals(telemetry.tick(registry), 1)
    clock.advance(10)
    t.assertEquals(telemetry.tick(registry), 0)
    clock.advance(30)
    t.assertEquals(telemetry.tick(registry), 1)
  end)
  t.it('fans a snapshot out to the phones following that vehicle only', function()
    local telemetry, registry, _, sent = setup()
    registry.connect('a', { version = 2 }).player = 0
    registry.connect('b', { version = 2 }).player = 1
    telemetry.tick(registry)
    t.assertEquals(telemetry.dispatch(registry, 11, { rpm = 1000 }), 1)
    t.assertEquals(sent[1].ip, 'a')
    t.assertContains(sent[1].payload, '"vehicle":"scintilla"')
    t.assertContains(sent[1].payload, '"player":0')
  end)
  t.it('sends the binary format to protocol v1 phones', function()
    local telemetry, registry, _, sent = setup()
    registry.connect('a', { version = 1 }).player = 0
    telemetry.tick(registry)
    telemetry.dispatch(registry, 11, { rpm = 1000 })
    t.assertEquals(#sent[1].payload, 36)
  end)
  t.it('ignores malformed snapshots', function()
    local telemetry, registry = setup()
    t.assertEquals(telemetry.dispatch(registry, 11, 'garbage'), 0)
  end)
end)

t.describe('telemetry router: radar', function()
  t.it('attaches the cars around the followed vehicle', function()
    local clock = fakes.clock()
    local sent = {}
    local registry = clientsModule.new(fakes.input(), clock.fn)
    local telemetry = telemetryModule.new({
      getVehicle = function() return fakes.vehicle(11) end,
      listVehicles = function()
        return { { id = 11, x = 0, y = 0, fx = 0, fy = 1 }, { id = 12, x = 0, y = 20, fx = 0, fy = 1 } }
      end,
      send = function(_, payload) sent[#sent + 1] = payload end,
      clock = clock.fn,
    })
    registry.connect('a', { version = 2 }).player = 0
    telemetry.tick(registry)
    telemetry.dispatch(registry, 11, { rpm = 1 })
    t.assertContains(sent[1], '"radar":[{"heading":0,"length":4.5,"width":1.9,"x":0,"y":20}]')
  end)
end)

t.describe('telemetry router: skeleton', function()
  t.it('sends the geometry to the v2 phones following that vehicle', function()
    local telemetry, registry, _, sent = setup()
    registry.connect('a', { version = 2 }).player = 0
    registry.connect('b', { version = 1 }).player = 0
    registry.connect('c', { version = 2 }).player = 1
    telemetry.tick(registry)
    local s = { id = '1-f', segments = { 0, 0, 10, 10 } }
    t.assertEquals(telemetry.dispatchSkeleton(registry, 11, s), 1)
    t.assertEquals(#sent, 1)
    t.assertEquals(sent[1].ip, 'a')
    t.assertContains(sent[1].payload, '"type":"skeleton"')
    t.assertEquals(telemetry.dispatchSkeleton(registry, 11, 'garbage'), 0)
  end)
end)
