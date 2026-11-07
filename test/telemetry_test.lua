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

t.describe('telemetry router: delta frames', function()
  local protocol = require('/lua/ge/extensions/beamRemotePlus/protocol')
  local snapshot = { rpm = 3000, speed = 20, maxRpm = 7000, tirePressuresNominal = { FL = 193.1 } }

  local function deltaSetup()
    local telemetry, registry, _, sent, clock = setup()
    registry.connect('a', { version = 2, features = { [protocol.FEATURE_DELTA] = true } }).player = 0
    telemetry.tick(registry)
    return telemetry, registry, sent, clock
  end

  t.it('apps without the feature get full frames, the very message they always got', function()
    local telemetry, registry, _, sent = setup()
    registry.connect('a', { version = 2 }).player = 0
    telemetry.tick(registry)
    telemetry.dispatch(registry, 11, snapshot)
    telemetry.dispatch(registry, 11, snapshot)
    local expected = protocol.buildTelemetryMessage({
      rpm = 3000, speed = 20, maxRpm = 7000, tirePressuresNominal = { FL = 193.1 }, player = 0, vehicle = 'scintilla',
    })
    t.assertEquals(sent[1].payload, expected)
    t.assertEquals(sent[2].payload, expected)
  end)
  t.it('starts with a full frame, then sends only what changed', function()
    local telemetry, registry, sent, clock = deltaSetup()
    telemetry.dispatch(registry, 11, snapshot)
    clock.advance(33)
    telemetry.dispatch(registry, 11, { rpm = 3100, speed = 20, maxRpm = 7000, tirePressuresNominal = { FL = 193.1 } })
    t.assertContains(sent[1].payload, '"maxRpm":7000')
    t.assertEquals(sent[2].payload, '{"delta":true,"rpm":3100,"type":"telemetry"}')
  end)
  t.it('sends a field gone as null', function()
    local telemetry, registry, sent, clock = deltaSetup()
    telemetry.dispatch(registry, 11, snapshot)
    clock.advance(33)
    telemetry.dispatch(registry, 11, { rpm = 3000, speed = 20, maxRpm = 7000 })
    t.assertEquals(sent[2].payload, '{"delta":true,"tirePressuresNominal":null,"type":"telemetry"}')
  end)
  t.it('sends a full frame again every second, in case a delta was lost', function()
    local telemetry, registry, sent, clock = deltaSetup()
    telemetry.dispatch(registry, 11, snapshot)
    clock.advance(telemetryModule.FULL_FRAME_MS - 1)
    telemetry.dispatch(registry, 11, snapshot)
    clock.advance(1)
    telemetry.dispatch(registry, 11, snapshot)
    t.assertEquals(sent[2].payload, '{"delta":true,"type":"telemetry"}')
    t.assertContains(sent[3].payload, '"maxRpm":7000')
  end)
  t.it('passes the paced skeleton damage through, and never clears it', function()
    local telemetry, registry, sent, clock = deltaSetup()
    telemetry.dispatch(registry, 11, { rpm = 1, skeletonDamage = '0090' })
    clock.advance(33)
    telemetry.dispatch(registry, 11, { rpm = 1 })
    clock.advance(33)
    telemetry.dispatch(registry, 11, { rpm = 1, skeletonDamage = '0090' })
    t.assertEquals(sent[2].payload, '{"delta":true,"type":"telemetry"}')
    t.assertEquals(sent[3].payload, '{"delta":true,"skeletonDamage":"0090","type":"telemetry"}')
  end)
  t.it('follows each phone on the same car on its own', function()
    local telemetry, registry, sent, clock = deltaSetup()
    telemetry.dispatch(registry, 11, snapshot)
    registry.connect('b', { version = 2, features = { [protocol.FEATURE_DELTA] = true } }).player = 0
    telemetry.tick(registry)
    clock.advance(33)
    telemetry.dispatch(registry, 11, snapshot)
    local byIp = {}
    for _, s in ipairs(sent) do byIp[s.ip] = s.payload end
    t.assertEquals(byIp.a, '{"delta":true,"type":"telemetry"}')
    t.assertContains(byIp.b, '"maxRpm":7000', 'the new phone starts with a full frame')
  end)
end)
