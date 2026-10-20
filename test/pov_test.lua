local t = require('minitest')
local fakes = require('fakes')
local povModule = require('/lua/ge/extensions/beamRemotePlus/pov')

local function setup(opts)
  opts = opts or {}
  local env = { clock = fakes.clock(), views = {}, outputs = {}, destroyed = 0, stopped = 0, told = {}, status = 1, inside = true }
  env.pov = povModule.new({
    createView = function(id, player, w, h)
      if opts.noViews then return nil, 'unavailable:render_views' end
      local view = { id = id, player = player, w = w, h = h }
      env.views[#env.views + 1] = view
      return view
    end,
    destroyView = function() env.destroyed = env.destroyed + 1 end,
    startOutput = function(view, url, quality, bitrate)
      if opts.noOutput then return nil, 'no_output' end
      local output = { view = view, url = url, quality = quality, bitrate = bitrate }
      env.outputs[#env.outputs + 1] = output
      return output
    end,
    stopOutput = function() env.stopped = env.stopped + 1 end,
    outputStatus = function() return env.status end,
    update = function() return env.inside end,
    cycleCamera = function(view, offset) view.cycled = offset return true end,
    notify = function(ip, info) env.told[#env.told + 1] = { ip = ip, info = info } end,
    clock = env.clock.fn,
  })
  env.clients = {}
  env.registry = { get = function(ip) return env.clients[ip] end }
  function env.client(ip, player)
    env.clients[ip] = { ip = ip, player = player }
    return env.clients[ip]
  end
  function env.last() return env.told[#env.told].info end
  -- The next check (4 times a second).
  function env.tick()
    env.clock.advance(povModule.CHECK_INTERVAL_MS)
    return env.pov.tick(env.registry)
  end
  return env
end

t.describe('pov: video', function()
  t.it('encodes the view of the phone player to its video port', function()
    local env = setup()
    t.assertTrue(env.pov.start(env.client('10.0.0.2', 1)))
    t.assertEquals(env.views[1].player, 1)
    t.assertEquals(env.views[1].w, 1280)
    t.assertEquals(env.outputs[1].url, 'udp://10.0.0.2:4448?pkt_size=1316')
    t.assertEquals(env.outputs[1].quality, povModule.DEFAULT_QUALITY)
    t.assertEquals(env.last().state, povModule.STARTING)
  end)
  t.it('tells the phone once it is live, and the kind of camera', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.status = 0
    env.tick()
    t.assertEquals(env.last().state, povModule.LIVE)
    t.assertTrue(env.last().inside)
    local told = #env.told
    env.tick()
    t.assertEquals(#env.told, told) -- nothing new
    env.inside = false
    env.tick()
    t.assertFalse(env.last().inside)
  end)
  t.it('offers 1080p', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0), '1080p60')
    t.assertEquals(env.views[1].w, 1920)
    t.assertEquals(env.views[1].h, 1080)
  end)
  t.it('renders the size asked by the phone, the shape of its screen', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0), '720p60', { size = povModule.parseSize('720p60', '1424x640') })
    t.assertEquals(env.views[1].w, 1424)
    t.assertEquals(env.views[1].h, 640)
  end)
  t.it('encodes at the bitrate asked by the phone, within the limit', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0), '720p60')
    t.assertEquals(env.outputs[1].bitrate, 8000000)
    env.pov.start(env.clients['10.0.0.2'], '720p60', { bitrate = 'high' })
    t.assertEquals(env.outputs[2].bitrate, 12000000)
    t.assertEquals(povModule.bitrate('1080p60', 'max'), 32000000)
    local ok, err = env.pov.start(env.clients['10.0.0.2'], '720p60', { bitrate = 'huge' })
    t.assertFalse(ok)
    t.assertEquals(err, 'bad_argument')
  end)
  t.it('never asks for more than the limit', function()
    for quality in pairs(povModule.QUALITIES) do
      for level in pairs(povModule.BITRATES) do
        t.assertTrue(povModule.bitrate(quality, level) <= povModule.MAX_BITRATE)
      end
    end
  end)
  t.it('never makes the game wait for the encoder, a keyframe each second', function()
    t.assertEquals(povModule.encoderOptions('720p60'), 'async_depth=2,g=60')
    t.assertEquals(povModule.encoderOptions('1080p30'), 'async_depth=2,g=30')
  end)
end)

t.describe('pov: picture size', function()
  t.it('reads a size within the pixels of the quality', function()
    local size = povModule.parseSize('720p60', '1424x640')
    t.assertEquals(size.width, 1424)
    t.assertEquals(size.height, 640)
    t.assertEquals(povModule.parseSize('1080p30', '1504x1248').height, 1248)
  end)
  t.it('refuses more pixels than the quality', function()
    t.assertNil(povModule.parseSize('720p60', '1920x1080'))
  end)
  t.it('refuses sides out of the encoder blocks or bounds', function()
    t.assertNil(povModule.parseSize('720p60', '1281x720'))
    t.assertNil(povModule.parseSize('720p60', '5000x160'))
    t.assertNil(povModule.parseSize('720p60', '1280x152'))
  end)
  t.it('refuses anything else', function()
    t.assertNil(povModule.parseSize('720p60', 'big'))
    t.assertNil(povModule.parseSize('720p60', '-1280x720'))
    t.assertNil(povModule.parseSize('4k', '1280x720'))
  end)
end)

t.describe('pov: no video', function()
  t.it('tells the phone when the encoder does not start, without falling back', function()
    local env = setup({ noOutput = true })
    local ok, err = env.pov.start(env.client('10.0.0.2', 0))
    t.assertFalse(ok)
    t.assertEquals(err, povModule.ERR_ENCODER)
    t.assertEquals(env.last().state, povModule.ERROR)
    t.assertEquals(env.last().error, povModule.ERR_ENCODER)
    t.assertEquals(env.destroyed, 1)
    t.assertFalse(env.pov.isStreaming('10.0.0.2'))
  end)
  t.it('tells the phone when the encoder fails, once set up', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.status = -2
    env.tick() -- still setting up
    t.assertEquals(env.last().state, povModule.STARTING)
    env.clock.advance(povModule.START_GRACE_MS)
    local failed = env.tick()
    t.assertEquals(failed['10.0.0.2'], povModule.ERR_ENCODER)
    t.assertEquals(env.last().state, povModule.ERROR)
    t.assertEquals(env.stopped, 1)
    t.assertEquals(env.pov.count(), 0)
  end)
  t.it('needs a player and a known quality', function()
    local env = setup()
    local ok, err = env.pov.start(env.client('10.0.0.2', -1))
    t.assertFalse(ok)
    t.assertEquals(err, 'no_player')
    ok, err = env.pov.start(env.client('10.0.0.2', 0), '4k')
    t.assertFalse(ok)
    t.assertEquals(err, 'bad_argument')
  end)
  t.it('reports a game without render views', function()
    local env = setup({ noViews = true })
    local ok, err = env.pov.start(env.client('10.0.0.2', 0))
    t.assertFalse(ok)
    t.assertEquals(err, 'unavailable:render_views')
  end)
end)

t.describe('pov: lifecycle', function()
  t.it('starting twice keeps one video, another quality makes a new one', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.pov.start(env.clients['10.0.0.2'])
    t.assertEquals(#env.views, 1)
    env.pov.start(env.clients['10.0.0.2'], '1080p30')
    t.assertEquals(#env.views, 2)
    t.assertEquals(env.stopped, 1)
    t.assertEquals(env.destroyed, 1)
    t.assertEquals(env.pov.count(), 1)
  end)
  t.it('another size makes a new video (a folding phone opened)', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0), '720p60', { size = povModule.parseSize('720p60', '1424x640') })
    env.pov.start(env.clients['10.0.0.2'], '720p60', { size = povModule.parseSize('720p60', '1424x640') })
    t.assertEquals(#env.views, 1)
    env.pov.start(env.clients['10.0.0.2'], '720p60', { size = povModule.parseSize('720p60', '1048x872') })
    t.assertEquals(#env.views, 2)
    t.assertEquals(env.views[2].w, 1048)
    t.assertEquals(env.destroyed, 1)
  end)
  t.it('stops the encoder and frees the view', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    t.assertTrue(env.pov.stop('10.0.0.2'))
    t.assertEquals(env.stopped, 1)
    t.assertEquals(env.destroyed, 1)
    t.assertFalse(env.pov.stop('10.0.0.2'))
  end)
  t.it('stops the video of a phone gone or left without a player', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.pov.start(env.client('10.0.0.3', 1))
    env.clients['10.0.0.2'] = nil
    env.clients['10.0.0.3'].player = -1
    env.tick()
    t.assertEquals(env.pov.count(), 0)
    t.assertEquals(env.destroyed, 2)
  end)
  t.it('follows the car of a phone given another player', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.clients['10.0.0.2'].player = 2
    env.tick()
    t.assertEquals(env.destroyed, 1)
    t.assertEquals(env.views[2].player, 2)
    t.assertEquals(#env.outputs, 2)
  end)
  t.it('cycles the camera of the video of a phone, if it has one', function()
    local env = setup()
    t.assertNil(env.pov.cycleCamera('10.0.0.2', 1))
    env.pov.start(env.client('10.0.0.2', 0))
    t.assertTrue(env.pov.cycleCamera('10.0.0.2', -1))
    t.assertEquals(env.views[1].cycled, -1)
  end)
end)

t.describe('pov: cameras of the video', function()
  local order = { 'orbit', 'driver', 'occupant.FL', 'occupant.FR', 'onboard.hood', 'crash' }
  local cycle = povModule.cycleWithSeat
  t.it('puts the driver seat back in the cycle of the game', function()
    t.assertEquals(cycle(order, 'orbit', 'onboard.hood', 'occupant.FL', 1), 'occupant.FL')
    t.assertEquals(cycle(order, 'onboard.hood', 'orbit', 'occupant.FL', -1), 'occupant.FL')
  end)
  t.it('leaves the seat for the next camera, and keeps the rest of the cycle', function()
    t.assertEquals(cycle(order, 'occupant.FL', 'onboard.hood', 'occupant.FL', 1), 'onboard.hood')
    t.assertEquals(cycle(order, 'onboard.hood', 'crash', 'occupant.FL', 1), 'crash')
    t.assertEquals(cycle(order, 'crash', 'orbit', 'occupant.FL', 1), 'orbit')
  end)
  t.it('goes to the seat when the game does not move', function()
    t.assertEquals(cycle(order, 'orbit', 'orbit', 'occupant.FL', 1), 'occupant.FL')
  end)
end)
