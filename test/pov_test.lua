local t = require('minitest')
local fakes = require('fakes')
local povModule = require('/lua/ge/extensions/beamRemotePlus/pov')

local function setup(opts)
  opts = opts or {}
  local env = { clock = fakes.clock(), views = {}, destroyed = 0, sent = {} }
  if opts.frame ~= nil then env.frame = opts.frame else env.frame = 'JPEG' end
  env.pov = povModule.new({
    createView = function(id, player, w, h)
      if opts.noViews then return nil, 'unavailable:render_views' end
      local view = { id = id, player = player, w = w, h = h }
      env.views[#env.views + 1] = view
      return view
    end,
    destroyView = function() env.destroyed = env.destroyed + 1 end,
    capture = function(view) return type(env.frame) == 'function' and env.frame(view) or env.frame end,
    send = function(payload, ip, port) env.sent[#env.sent + 1] = { payload = payload, ip = ip, port = port } end,
    clock = env.clock.fn,
  })
  env.clients = {}
  env.registry = { get = function(ip) return env.clients[ip] end }
  function env.client(ip, player)
    env.clients[ip] = { ip = ip, player = player }
    return env.clients[ip]
  end
  return env
end

t.describe('pov: frames', function()
  t.it('numbers every frame in a 8-byte header', function()
    t.assertEquals(povModule.header(1), 'BRPV\0\0\0\1')
    t.assertEquals(povModule.header(258), 'BRPV\0\0\1\2')
  end)
  t.it('sends the view of the phone player to its POV port', function()
    local env = setup()
    t.assertTrue(env.pov.start(env.client('10.0.0.2', 1)))
    t.assertEquals(env.views[1].player, 1)
    t.assertEquals(env.views[1].w, 640)
    t.assertEquals(env.pov.tick(env.registry), 1)
    t.assertEquals(env.sent[1].ip, '10.0.0.2')
    t.assertEquals(env.sent[1].port, povModule.POV_PORT)
    t.assertEquals(env.sent[1].payload, povModule.header(1) .. 'JPEG')
  end)
  t.it('never captures two game frames in a row, even when the game is slow', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    t.assertEquals(env.pov.tick(env.registry), 1)
    env.clock.advance(100)
    t.assertEquals(env.pov.tick(env.registry), 0)
    env.clock.advance(100)
    t.assertEquals(env.pov.tick(env.registry), 1)
  end)
  t.it('keeps to 30 frames per second when the game is fast', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    local sent = 0
    for _ = 1, 120 do -- one second at 120 fps
      sent = sent + env.pov.tick(env.registry)
      env.clock.advance(1000 / 120)
    end
    t.assertTrue(sent >= 29 and sent <= 31, 'sent ' .. sent)
  end)
  t.it('captures every phone in the same game frame', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.pov.start(env.client('10.0.0.3', 1))
    t.assertEquals(env.pov.tick(env.registry), 2)
    t.assertEquals(env.pov.tick(env.registry), 0)
  end)
  t.it('sends nothing before the view has rendered', function()
    local env = setup({ frame = false })
    env.pov.start(env.client('10.0.0.2', 0))
    t.assertEquals(env.pov.tick(env.registry), 0)
    t.assertEquals(#env.sent, 0)
  end)
  t.it('lowers the resolution when a frame does not fit a datagram', function()
    local env = setup()
    env.frame = function(view) return view.w == 640 and string.rep('x', povModule.MAX_FRAME_BYTES + 1) or 'JPEG' end
    env.pov.start(env.client('10.0.0.2', 0))
    t.assertEquals(env.pov.tick(env.registry), 0)
    t.assertEquals(env.destroyed, 1)
    t.assertEquals(env.views[2].w, 512)
    env.pov.tick(env.registry)
    env.clock.advance(povModule.FRAME_INTERVAL_MS)
    t.assertEquals(env.pov.tick(env.registry), 1)
  end)
end)

t.describe('pov: lifecycle', function()
  t.it('needs a player', function()
    local env = setup()
    local ok, err = env.pov.start(env.client('10.0.0.2', -1))
    t.assertFalse(ok)
    t.assertEquals(err, 'no_player')
  end)
  t.it('reports a game without render views', function()
    local env = setup({ noViews = true })
    local ok, err = env.pov.start(env.client('10.0.0.2', 0))
    t.assertFalse(ok)
    t.assertEquals(err, 'unavailable:render_views')
    t.assertFalse(env.pov.isStreaming('10.0.0.2'))
  end)
  t.it('starting twice keeps one view', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.pov.start(env.clients['10.0.0.2'])
    t.assertEquals(#env.views, 1)
  end)
  t.it('stops and frees the view', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    t.assertTrue(env.pov.stop('10.0.0.2'))
    t.assertEquals(env.destroyed, 1)
    t.assertEquals(env.pov.count(), 0)
    t.assertFalse(env.pov.stop('10.0.0.2'))
  end)
  t.it('stops the video of a phone gone or left without a player', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.pov.start(env.client('10.0.0.3', 1))
    env.clients['10.0.0.2'] = nil
    env.clients['10.0.0.3'].player = -1
    env.pov.tick(env.registry)
    t.assertEquals(env.pov.count(), 0)
    t.assertEquals(env.destroyed, 2)
  end)
  t.it('follows the car of a phone given another player', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.clients['10.0.0.2'].player = 2
    env.pov.tick(env.registry)
    t.assertEquals(env.destroyed, 1)
    t.assertEquals(env.views[2].player, 2)
    t.assertEquals(#env.sent, 1)
  end)
end)
