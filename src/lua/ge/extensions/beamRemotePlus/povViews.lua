-- The game side of the point of view video (pov.lua is the logic): a hidden
-- render view per phone, driven by a camera context of the game (0.40, the
-- split-screen machinery). It follows the car of the phone's player,
-- starting from the driver's seat, never drawn on the PC screen. The
-- context gets an input player of its own (INPUT_PLAYER, counting down), so
-- the player keeps its own camera on the PC, and the phone cycles the
-- cameras of its video through that input player. The game's video
-- streaming (libbngvs, 0.40) encodes the view on the graphics card and sends
-- it to the phone.
--
-- env: the game's globals (_G in the game, a fake in the tests), looked up
-- on each call: RenderViewManagerInstance, RenderSettings, core_camera,
-- startNetworkOutput, stopNetworkOutput, getNetworkOutputStatus,
-- getPlayerVehicle, Point2I, RectI, Frustum, os (os.clockhp, seconds).

local povModule = require('/lua/ge/extensions/beamRemotePlus/pov')

local M = {}

M.INPUT_PLAYER = 63
-- How often the camera of a view is checked (seconds).
M.CAMERA_CHECK_S = 1
-- Time constant of the smooth recentring of a seat camera (95% in 3 of them).
M.RECENTER_S = 0.15
-- Field of view of the views (degrees).
M.FOV = 70

-- Seat cameras: the car's own dashboard is in view (not from the hood).
function M.isInsideCamera(name)
  return name == 'driver' or (name ~= nil and name:find('^occupant%.') ~= nil)
end

-- Render views driven by camera contexts and the video streaming both
-- arrived with 0.40, but the native Linux build of the game ships no video
-- streaming (libbngvs is in Bin64 only, startNetworkOutput is missing from
-- BinLinux, checked on 0.40.1): only the Windows build has it, on Linux
-- through Proton. Returns nil when the game can do it, else why not.
function M.unavailable(env)
  local camera = env.core_camera
  if not (env.RenderViewManagerInstance ~= nil and camera ~= nil and camera.createContext ~= nil) then
    return povModule.UNAVAILABLE_GAME
  end
  if type(env.startNetworkOutput) ~= 'function' then return povModule.UNAVAILABLE_PLATFORM end
  return nil
end

-- The povViews deps of pov.lua (see server.lua), bound to env.
function M.new(env)
  local self = {}
  local inputs = {} -- input players in use

  local function now() return env.os.clockhp() end

  -- Same quality cut as split-screen views (render/splitScreen.lua): mirrors
  -- and dynamic reflections are each an extra render.
  local function cutQuality(rv)
    local ok, s = pcall(env.RenderSettings.getGlobals)
    if not ok or not s then return end
    s.meshDetailAdjust = s.meshDetailAdjust * 0.5
    s.groundCoverScale = s.groundCoverScale * 0.5
    s.vehicleMirrorsEnabled = false
    s.vehicleDynamicReflectionsEnabled = false
    rv.settingsOverride = s
    rv.settingsOverrideEnabled = true
  end

  -- The PC's anti-aliasing / upscaler and exposure, like split-screen views:
  -- without them edges, wires and foliage shimmer (a grainy picture), and a
  -- new view starts at the default exposure and blows out until it adapts.
  local function likeMainView(rv)
    local main = env.RenderViewManagerInstance:getView('main')
    if not main then return end
    rv.upscaleMode = main.upscaleMode
    rv.upscaleRenderScale = main.upscaleRenderScale
    rv.upscaleSharpness = main.upscaleSharpness
    rv.currentExposure = main.currentExposure
  end

  local function cameraName(view)
    local state = env.core_camera.getContextCameraState(view.id)
    return state and state.cam
  end

  -- The camera object of the view (its own instance, not the PC's).
  local function cameraOf(view)
    local cams = view.vid and env.core_camera.getCameraDataById(view.vid, view.id)
    local name = cams and cameraName(view)
    return name and cams[name]
  end

  function self.createView(id, player, width, height)
    local input = M.INPUT_PLAYER
    while inputs[input] do input = input - 1 end
    local rv = env.RenderViewManagerInstance:getOrCreateView(id)
    rv.luaOwned = true
    rv.renderEditorIcons = false
    rv.namedTexTargetColor = id
    rv.resolution = env.Point2I(width, height)
    rv.viewPort = env.RectI(0, 0, width, height)
    rv.compositeRect = env.RectI(-2, -2, 2, 2) -- off the window: never composited on screen
    rv.frustum = env.Frustum.construct(false, math.rad(M.FOV), width / height, 0.1, 2000)
    cutQuality(rv)
    likeMainView(rv)
    env.core_camera.createContext(id, id, input, player)
    inputs[input] = true
    return { id = id, rv = rv, input = input, player = player, checkAt = 0 }
  end

  function self.destroyView(view)
    env.core_camera.destroyContext(view.id)
    env.RenderViewManagerInstance:destroyView(view.rv)
    inputs[view.input] = nil
  end

  function self.startOutput(view, url, quality, bitrate)
    local q = povModule.QUALITIES[quality]
    -- source, url, container, fps, bitrate, with audio (0 = no), encoder options
    local id = env.startNetworkOutput(view.id, url, 'mpegts', q.fps, bitrate, 0, povModule.encoderOptions(quality))
    if not id then return nil, 'no_output' end
    return id
  end

  function self.stopOutput(output) env.stopNetworkOutput(output) end

  function self.outputStatus(output) return env.getNetworkOutputStatus(output) end

  -- The context starts on the car's default camera, and gets it back when
  -- the car changes: the camera of the video (the driver's seat of each new
  -- car) is selected again. Returns whether the view shows a seat camera.
  function self.update(view)
    local t = now()
    if t >= view.checkAt then
      view.checkAt = t + M.CAMERA_CHECK_S
      local veh = env.getPlayerVehicle(view.player)
      local vid = veh and veh:getID()
      if vid ~= view.vid then
        view.vid = vid
        view.camera = vid and env.core_camera.getDriverCameraNameById(vid)
      end
      local current = view.camera and cameraName(view)
      if not view.free and current and current ~= view.camera then
        env.core_camera.setContextCamera(view.id, view.camera)
      end
    end
    return not view.free and M.isInsideCamera(view.camera)
  end

  -- Like the game's mouse look (core/input/actions/camera.json), through the
  -- view's own input player: the PC's camera does not move.
  function self.look(view, dx, dy)
    view.recentering = nil
    env.core_camera.rotate_yaw_relative(dx, view.input)
    env.core_camera.rotate_pitch_relative(-dy, view.input)
  end

  -- The game resets no camera of a hidden view (core_camera.resetCamera
  -- looks for a car of the view's input player, which has none), and a new
  -- context would reset the PC's cameras too (destroyContext clears the
  -- main view's camera cache). So the view's own camera, from
  -- getCameraDataById, is turned back: smoothly for a seat camera (frame),
  -- with its own reset for the others.
  function self.recenter(view)
    local cam = cameraOf(view)
    if not cam then return end
    if cam.relativeYaw then
      view.recentering = cam
    elseif cam.reset then
      cam:reset()
    end
  end

  -- Every frame: eases a recentring seat camera back to the road.
  function self.frame(view)
    local t = now()
    local dt = math.min(t - (view.frameAt or t), 0.1)
    view.frameAt = t
    local cam = view.recentering
    if not cam then return end
    if cam ~= cameraOf(view) then
      view.recentering = nil
      return
    end
    local keep = math.exp(-dt / M.RECENTER_S)
    cam.relativeYaw, cam.relativePitch = cam.relativeYaw * keep, (cam.relativePitch or 0) * keep
    if math.abs(cam.relativeYaw) + math.abs(cam.relativePitch) < 0.002 then
      cam.relativeYaw, cam.relativePitch = 0, 0
      view.recentering = nil
    end
  end

  -- The game's free camera of the view, starting where the view looks, or
  -- back to the camera it left.
  function self.setFree(view, on)
    view.free = on
    view.recentering = nil
    env.core_camera.setContextCamera(view.id, on and 'free' or view.camera)
    return true
  end

  function self.fly(view, value)
    env.core_camera.moveforward(math.max(value, 0), view.input)
    env.core_camera.movebackward(math.max(-value, 0), view.input)
  end

  function self.cycleCamera(view, offset)
    local camera = env.core_camera
    local current = cameraName(view)
    camera.setVehicleCameraByIndexOffset(view.input, offset)
    local order = {}
    for _, config in ipairs(camera.getConfigurationReadOnly()) do
      if config.enabled or config.name == 'driver' or config.name:find('^occupant%.') then order[#order + 1] = config.name end
    end
    local seat = view.vid and camera.getDriverCameraNameById(view.vid)
    local name = povModule.cycleWithSeat(order, current, cameraName(view), seat, offset)
    if name and name ~= cameraName(view) then camera.setContextCamera(view.id, name) end
    view.camera = name or view.camera
    return true
  end

  return self
end

return M
