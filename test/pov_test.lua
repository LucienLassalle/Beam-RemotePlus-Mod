local t = require('minitest')
local fakes = require('fakes')
local povModule = require('/lua/ge/extensions/beamRemotePlus/pov')

local function setup(opts)
  opts = opts or {}
  local env = { clock = fakes.clock(), views = {}, destroyed = 0, sent = {}, inside = true }
  if opts.frame ~= nil then env.frame = opts.frame else env.frame = 'JPEG' end
  env.pov = povModule.new({
    createView = function(id, player, w, h)
      if opts.noViews then return nil, 'unavailable:render_views' end
      local view = { id = id, player = player, w = w, h = h, active = true }
      env.views[#env.views + 1] = view
      return view
    end,
    destroyView = function() env.destroyed = env.destroyed + 1 end,
    setActive = function(view, on) view.active = on end,
    capture = function(view)
      return type(env.frame) == 'function' and env.frame(view) or env.frame, env.inside
    end,
    cycleCamera = function(view, offset) view.cycled = offset return true end,
    send = function(payload, ip, port) env.sent[#env.sent + 1] = { payload = payload, ip = ip, port = port } end,
    clock = env.clock.fn,
  })
  env.clients = {}
  env.registry = { get = function(ip) return env.clients[ip] end }
  function env.client(ip, player)
    env.clients[ip] = { ip = ip, player = player }
    return env.clients[ip]
  end
  -- Frames sent over one game frame, then one more (render, then capture).
  function env.cycle()
    return env.pov.tick(env.registry) + env.pov.tick(env.registry)
  end
  return env
end

t.describe('pov: frames', function()
  t.it('numbers every frame and part in a 11-byte header', function()
    t.assertEquals(povModule.header(1), 'BRPV\0\0\0\1\0\1\0')
    t.assertEquals(povModule.header(258, 1, 3, povModule.FLAG_INSIDE), 'BRPV\0\0\1\2\1\3\1')
    t.assertEquals(#povModule.header(1), povModule.HEADER_BYTES)
  end)
  t.it('sends the view of the phone player to its POV port', function()
    local env = setup()
    t.assertTrue(env.pov.start(env.client('10.0.0.2', 1)))
    t.assertEquals(env.views[1].player, 1)
    t.assertEquals(env.views[1].w, povModule.QUALITIES[povModule.DEFAULT_QUALITY].width)
    t.assertEquals(env.cycle(), 1)
    t.assertEquals(env.sent[1].ip, '10.0.0.2')
    t.assertEquals(env.sent[1].port, povModule.POV_PORT)
    t.assertEquals(env.sent[1].payload, povModule.header(1, 0, 1, povModule.FLAG_INSIDE) .. 'JPEG')
  end)
  t.it('tells when the camera is outside the car', function()
    local env = setup()
    env.inside = false
    env.pov.start(env.client('10.0.0.2', 0))
    env.cycle()
    t.assertEquals(env.sent[1].payload:byte(11), 0)
  end)
  t.it('cuts the big frames in parts', function()
    local env = setup({ frame = string.rep('a', povModule.PART_BYTES) .. 'bc' })
    env.pov.start(env.client('10.0.0.2', 0), 'high')
    t.assertEquals(env.cycle(), 1)
    t.assertEquals(#env.sent, 2)
    t.assertEquals(env.sent[1].payload:sub(1, povModule.HEADER_BYTES), povModule.header(1, 0, 2, povModule.FLAG_INSIDE))
    t.assertEquals(env.sent[2].payload, povModule.header(1, 1, 2, povModule.FLAG_INSIDE) .. 'bc')
  end)
  t.it('renders a view only in the game frame before its capture', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    t.assertFalse(env.views[1].active)
    t.assertEquals(env.pov.tick(env.registry), 0)
    t.assertTrue(env.views[1].active)
    t.assertEquals(env.pov.tick(env.registry), 1)
    t.assertFalse(env.views[1].active)
  end)
  t.it('never captures two game frames in a row, even when the game is slow', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    t.assertEquals(env.cycle(), 1)
    env.clock.advance(100)
    t.assertEquals(env.pov.tick(env.registry), 0)
    env.clock.advance(100)
    t.assertEquals(env.pov.tick(env.registry), 1)
  end)
  t.it('keeps to the frame rate of its quality when the game is fast', function()
    for quality, fps in pairs({ low = 30, medium = 20, high = 20 }) do
      local env = setup()
      env.pov.start(env.client('10.0.0.2', 0), quality)
      local sent = 0
      for _ = 1, 120 do -- one second at 120 fps
        sent = sent + env.pov.tick(env.registry)
        env.clock.advance(1000 / 120)
      end
      t.assertTrue(sent >= fps - 1 and sent <= fps + 1, quality .. ' sent ' .. sent)
    end
  end)
  t.it('captures every phone in the same game frame', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.clock.advance(10)
    env.pov.start(env.client('10.0.0.3', 1))
    t.assertEquals(env.cycle(), 2)
    t.assertEquals(env.pov.tick(env.registry), 0)
  end)
  t.it('sends nothing before the view has rendered', function()
    local env = setup({ frame = false })
    env.pov.start(env.client('10.0.0.2', 0))
    t.assertEquals(env.cycle(), 0)
    t.assertEquals(#env.sent, 0)
  end)
end)

t.describe('pov: lifecycle', function()
  t.it('needs a player and a known quality', function()
    local env = setup()
    local ok, err = env.pov.start(env.client('10.0.0.2', -1))
    t.assertFalse(ok)
    t.assertEquals(err, 'no_player')
    ok, err = env.pov.start(env.client('10.0.0.2', 0), 'ultra')
    t.assertFalse(ok)
    t.assertEquals(err, 'bad_argument')
  end)
  t.it('reports a game without render views', function()
    local env = setup({ noViews = true })
    local ok, err = env.pov.start(env.client('10.0.0.2', 0))
    t.assertFalse(ok)
    t.assertEquals(err, 'unavailable:render_views')
    t.assertFalse(env.pov.isStreaming('10.0.0.2'))
  end)
  t.it('starting twice keeps one view, another quality makes a new one', function()
    local env = setup()
    env.pov.start(env.client('10.0.0.2', 0))
    env.pov.start(env.clients['10.0.0.2'])
    t.assertEquals(#env.views, 1)
    env.pov.start(env.clients['10.0.0.2'], 'low')
    t.assertEquals(#env.views, 2)
    t.assertEquals(env.destroyed, 1)
    t.assertEquals(env.views[2].w, 640)
    t.assertEquals(env.pov.count(), 1)
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
    env.cycle()
    t.assertEquals(env.destroyed, 1)
    t.assertEquals(env.views[2].player, 2)
    t.assertEquals(#env.sent, 1)
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

