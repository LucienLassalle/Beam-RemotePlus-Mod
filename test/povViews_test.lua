local t = require('minitest')
local povViews = require('/lua/ge/extensions/beamRemotePlus/povViews')
local pov = require('/lua/ge/extensions/beamRemotePlus/pov')

-- The game globals povViews uses: render views, camera contexts (one camera
-- per context, cycled by input player like the game does, seat cameras
-- left out), the video streaming and a clock in seconds.
local function fakeGame()
  local game = { time = 10, outputs = {}, destroyed = {}, rotations = {}, moves = {} }
  local contexts = {}
  local main = { upscaleMode = 'dlss', upscaleRenderScale = 0.67, upscaleSharpness = 0.3, currentExposure = 1.7 }
  local configs = {
    { name = 'orbit', enabled = true }, { name = 'driver', enabled = false },
    { name = 'external', enabled = true }, { name = 'unused', enabled = false },
  }
  local cycled = { 'orbit', 'external' } -- what the game cycles through for a view
  game.drivers = { [1] = 'driver', [2] = 'occupant.passenger' }
  game.cams = {}
  game.vehicles = {}
  game.contexts = contexts

  game.env = {
    os = { clockhp = function() return game.time end },
    Point2I = function(x, y) return { x = x, y = y } end,
    RectI = function(x, y, w, h) return { x, y, w, h } end,
    Frustum = { construct = function(_, fov, aspect) return { fov = fov, aspect = aspect } end },
    RenderSettings = { getGlobals = function()
      return { meshDetailAdjust = 1, groundCoverScale = 1, vehicleMirrorsEnabled = true, vehicleDynamicReflectionsEnabled = true }
    end },
    RenderViewManagerInstance = {
      getView = function(_, name) return name == 'main' and main or nil end,
      getOrCreateView = function(_, id) return { id = id } end,
      destroyView = function(_, rv) game.destroyed[#game.destroyed + 1] = rv.id end,
    },
    core_camera = {
      createContext = function(id, _, input, player) contexts[id] = { input = input, player = player, cam = 'orbit' } end,
      destroyContext = function(id) contexts[id] = nil end,
      getContextCameraState = function(id) return contexts[id] and { cam = contexts[id].cam } end,
      setContextCamera = function(id, name) contexts[id].cam = name end,
      getDriverCameraNameById = function(vid) return game.drivers[vid] end,
      getCameraDataById = function(vid) return game.cams[vid] end,
      rotate_yaw_relative = function(v, input) game.rotations[#game.rotations + 1] = { 'yaw', v, input } end,
      rotate_pitch_relative = function(v, input) game.rotations[#game.rotations + 1] = { 'pitch', v, input } end,
      moveforward = function(v, input) game.moves[#game.moves + 1] = { 'forward', v, input } end,
      movebackward = function(v, input) game.moves[#game.moves + 1] = { 'backward', v, input } end,
      getConfigurationReadOnly = function() return configs end,
      setVehicleCameraByIndexOffset = function(input, offset)
        for _, c in pairs(contexts) do
          if c.input == input then
            local i = 1
            for k, name in ipairs(cycled) do if name == c.cam then i = k end end
            c.cam = cycled[(i - 1 + offset) % #cycled + 1]
          end
        end
      end,
    },
    getPlayerVehicle = function(player)
      local vid = game.vehicles[player]
      return vid and { getID = function() return vid end }
    end,
    startNetworkOutput = function(...)
      game.outputs[#game.outputs + 1] = { ... }
      if game.failOutput then return nil end
      return #game.outputs
    end,
    stopNetworkOutput = function() end,
    getNetworkOutputStatus = function() return 0 end,
  }
  return game
end

t.describe('povViews: availability', function()
  t.it('needs the render views and camera contexts of 0.40', function()
    local env = fakeGame().env
    env.core_camera.createContext = nil
    t.assertEquals(povViews.unavailable(env), pov.UNAVAILABLE_GAME)
    env = fakeGame().env
    env.RenderViewManagerInstance = nil
    t.assertEquals(povViews.unavailable(env), pov.UNAVAILABLE_GAME)
  end)
  t.it('needs the video streaming, missing from the native Linux build', function()
    local env = fakeGame().env
    env.startNetworkOutput = nil
    t.assertEquals(povViews.unavailable(env), pov.UNAVAILABLE_PLATFORM)
  end)
  t.it('is available with both', function()
    t.assertNil(povViews.unavailable(fakeGame().env))
  end)
end)

t.describe('povViews: views', function()
  t.it('gives each view an input player of its own, counting down, freed with the view', function()
    local views = povViews.new(fakeGame().env)
    local a = views.createView('a', 0, 1280, 720)
    local b = views.createView('b', 1, 1280, 720)
    t.assertEquals(a.input, povViews.INPUT_PLAYER)
    t.assertEquals(b.input, povViews.INPUT_PLAYER - 1)
    views.destroyView(a)
    t.assertEquals(views.createView('c', 2, 1280, 720).input, povViews.INPUT_PLAYER)
  end)
  t.it('is never drawn on the PC screen', function()
    local game = fakeGame()
    local view = povViews.new(game.env).createView('a', 0, 1424, 640)
    local rect = view.rv.compositeRect
    t.assertTrue(rect[1] < 0 and rect[2] < 0 and rect[3] <= 2 and rect[4] <= 2, 'composited off the window')
    t.assertEquals(view.rv.resolution.x, 1424)
    t.assertCloseTo(view.rv.frustum.aspect, 1424 / 640)
    t.assertEquals(game.contexts.a.player, 0)
  end)
  t.it('cuts the quality like split-screen views, and keeps the PC upscaler and exposure', function()
    local view = povViews.new(fakeGame().env).createView('a', 0, 1280, 720)
    local s = view.rv.settingsOverride
    t.assertTrue(view.rv.settingsOverrideEnabled)
    t.assertFalse(s.vehicleMirrorsEnabled)
    t.assertFalse(s.vehicleDynamicReflectionsEnabled)
    t.assertEquals(s.meshDetailAdjust, 0.5)
    t.assertEquals(view.rv.upscaleMode, 'dlss')
    t.assertEquals(view.rv.currentExposure, 1.7)
  end)
  t.it('destroys the context and the render view', function()
    local game = fakeGame()
    local views = povViews.new(game.env)
    views.destroyView(views.createView('a', 0, 1280, 720))
    t.assertNil(game.contexts.a)
    t.assertEquals(game.destroyed[1], 'a')
  end)
end)

t.describe('povViews: video output', function()
  t.it('streams MPEG-TS at the frame rate of the quality, without audio', function()
    local game = fakeGame()
    local views = povViews.new(game.env)
    local view = views.createView('a', 0, 1920, 1080)
    t.assertEquals(views.startOutput(view, 'udp://x', '1080p30', 12345), 1)
    local args = game.outputs[1]
    t.assertEquals(args[1], 'a')
    t.assertEquals(args[3], 'mpegts')
    t.assertEquals(args[4], 30)
    t.assertEquals(args[5], 12345)
    t.assertEquals(args[6], 0)
  end)
  t.it('tells when the game gives no output', function()
    local game = fakeGame()
    game.failOutput = true
    local views = povViews.new(game.env)
    local id, err = views.startOutput(views.createView('a', 0, 1280, 720), 'udp://x', '720p60', 1)
    t.assertNil(id)
    t.assertEquals(err, 'no_output')
  end)
end)

t.describe('povViews: camera', function()
  local function setup()
    local game = fakeGame()
    game.vehicles[0] = 1
    local views = povViews.new(game.env)
    local view = views.createView('a', 0, 1280, 720)
    return game, views, view
  end

  t.it('starts on the driver seat and goes back to it when the game changes it', function()
    local game, views, view = setup()
    t.assertTrue(views.update(view), 'a seat camera')
    t.assertEquals(game.contexts.a.cam, 'driver')
    game.contexts.a.cam = 'orbit'
    game.time = game.time + povViews.CAMERA_CHECK_S
    views.update(view)
    t.assertEquals(game.contexts.a.cam, 'driver')
  end)
  t.it('checks the camera at most once a second', function()
    local game, views, view = setup()
    views.update(view)
    game.contexts.a.cam = 'orbit'
    game.time = game.time + povViews.CAMERA_CHECK_S / 2
    views.update(view)
    t.assertEquals(game.contexts.a.cam, 'orbit')
  end)
  t.it('takes the seat of the new car when the player changes car', function()
    local game, views, view = setup()
    views.update(view)
    game.vehicles[0] = 2
    game.time = game.time + povViews.CAMERA_CHECK_S
    views.update(view)
    t.assertEquals(game.contexts.a.cam, 'occupant.passenger')
  end)
  t.it('leaves the free camera alone', function()
    local game, views, view = setup()
    views.update(view)
    views.setFree(view, true)
    t.assertEquals(game.contexts.a.cam, 'free')
    game.time = game.time + povViews.CAMERA_CHECK_S
    t.assertFalse(views.update(view), 'not a seat camera')
    t.assertEquals(game.contexts.a.cam, 'free')
    views.setFree(view, false)
    t.assertEquals(game.contexts.a.cam, 'driver')
  end)
  t.it('looks and flies through the input player of the view, not the PC one', function()
    local game, views, view = setup()
    views.look(view, 5, 3)
    views.fly(view, -0.5)
    t.assertEquals(game.rotations[1][3], view.input)
    t.assertEquals(game.rotations[2][2], -3, 'pitch like the mouse: up is negative')
    t.assertEquals(game.moves[1][2], 0, 'no forward')
    t.assertEquals(game.moves[2][2], 0.5, 'backward')
  end)
  t.it('eases a seat camera back to the road, frame after frame', function()
    local game, views, view = setup()
    views.update(view)
    local seat = { relativeYaw = 1, relativePitch = -0.5 }
    game.cams[1] = { driver = seat }
    views.recenter(view)
    views.frame(view)
    game.time = game.time + 0.1
    views.frame(view)
    t.assertCloseTo(seat.relativeYaw, math.exp(-0.1 / povViews.RECENTER_S), 1e-6)
    for _ = 1, 30 do
      game.time = game.time + 0.05
      views.frame(view)
    end
    t.assertEquals(seat.relativeYaw, 0)
    t.assertEquals(seat.relativePitch, 0)
    t.assertNil(view.recentering)
  end)
  t.it('turning the camera stops the easing', function()
    local game, views, view = setup()
    views.update(view)
    local seat = { relativeYaw = 1 }
    game.cams[1] = { driver = seat }
    views.recenter(view)
    views.look(view, 1, 0)
    game.time = game.time + 0.1
    views.frame(view)
    t.assertEquals(seat.relativeYaw, 1)
  end)
  t.it('resets the other cameras at once', function()
    local game, views, view = setup()
    views.update(view)
    game.contexts.a.cam = 'orbit'
    local reset = 0
    game.cams[1] = { orbit = { reset = function() reset = reset + 1 end } }
    views.recenter(view)
    t.assertEquals(reset, 1)
  end)
  t.it('cycles the cameras with the driver seat in the loop', function()
    local game, views, view = setup()
    views.update(view)
    views.cycleCamera(view, 1)
    t.assertEquals(game.contexts.a.cam, 'external')
    views.cycleCamera(view, 1)
    t.assertEquals(game.contexts.a.cam, 'orbit')
    views.cycleCamera(view, 1)
    t.assertEquals(game.contexts.a.cam, 'driver')
    t.assertEquals(view.camera, 'driver')
  end)
end)

t.describe('povViews: frame hitches', function()
  t.it('a long frame does not snap a seat camera back at once', function()
    local game = fakeGame()
    game.vehicles[0] = 1
    local views = povViews.new(game.env)
    local view = views.createView('a', 0, 1280, 720)
    views.update(view)
    local seat = { relativeYaw = 1 }
    game.cams[1] = { driver = seat }
    views.recenter(view)
    views.frame(view)
    game.time = game.time + 2
    views.frame(view)
    t.assertCloseTo(seat.relativeYaw, math.exp(-0.1 / povViews.RECENTER_S), 1e-6)
  end)
end)
