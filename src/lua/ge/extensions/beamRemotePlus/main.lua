-- Beam-RemotePlus GE extension entry point (extensions.beamRemotePlus_main).
--
-- This file only binds BeamNG globals to the testable modules next to it;
-- the logic lives in server.lua. Public functions below are also the API
-- used by the input action (Options > Controls) and the in-game UI app.

local MODULE_DIR = '/lua/ge/extensions/beamRemotePlus/'
local SIBLINGS = { 'json', 'protocol', 'config', 'i18n', 'logger', 'clients',
  'vehicleActions', 'commands', 'radar', 'telemetry', 'transport', 'nativeRemote', 'version', 'optionalMods', 'pov', 'server' }

-- require() caches by path independently of extensions.reload(): without
-- this, reloading the mod would keep running stale sibling modules.
for _, name in ipairs(SIBLINGS) do package.loaded[MODULE_DIR .. name] = nil end

local configModule = require(MODULE_DIR .. 'config')
local i18nModule = require(MODULE_DIR .. 'i18n')
local loggerModule = require(MODULE_DIR .. 'logger')
local transportModule = require(MODULE_DIR .. 'transport')
local nativeRemoteModule = require(MODULE_DIR .. 'nativeRemote')
local serverModule = require(MODULE_DIR .. 'server')
local radar = require(MODULE_DIR .. 'radar')
local vehicleActions = require(MODULE_DIR .. 'vehicleActions')
local povModule = require(MODULE_DIR .. 'pov')

local M = {}

local server = nil
local logger = loggerModule.new(function(...) log(...) end, function() return Engine.Platform.getSystemTimeMS() end)
local i18n = i18nModule.new(function(key) return type(_tr) == 'function' and _tr(key) or nil end)

local function notify(text, kind)
  guihooks.trigger('toastrMsg', {
    type = kind or 'info',
    title = i18n.t('beamRemotePlus.toast.title'),
    msg = text,
    config = { timeOut = 8000 },
  })
end

-- The game's own remote control: its pairing code is the mod's, and its
-- pairing is refused while new phones are locked out (see nativeRemote.lua).
local nativeRemote = nativeRemoteModule.new(function() return extensions.core_remoteController end,
  function() return extensions.core_input_virtualInput end, debug)

local function getSecurityCode() return nativeRemote.getCode() end

local function getHostLabel()
  local ok, name = pcall(function() return Steam and Steam.playerName end)
  if ok and type(name) == 'string' and name ~= '' then
    return i18n.t('beamRemotePlus.label.host', { name = name })
  end
  return 'BeamNG.drive'
end

-- Address of the PC on the local network, for the pairing QR code: the
-- interface of the default route, found by "connecting" a UDP socket (no
-- packet is sent). Nil when offline.
local function getHostAddress()
  local ok, address = pcall(function()
    local udp = socket.udp()
    udp:setpeername('192.0.2.1', 9)
    local ip = udp:getsockname()
    udp:close()
    return ip
  end)
  return ok and address or nil
end

-- Colour of a player (0-based), the one the game tints its name tag above
-- the car with: since 0.40, the colour of its persona (core_multiseat).
local function playerColor(player)
  local multiseat = extensions.core_multiseat
  if not (multiseat and multiseat.getParticipant) then return nil end
  local participant = multiseat.getParticipant(player)
  local hex = participant and participant.persona and participant.persona.colorHex
  return type(hex) == 'string' and hex or nil
end

-- Local multiplayer since 0.40: joins the phone's device as the next free
-- player, like the game's split-screen setup does, then lets the game seat
-- that player in a car (the device rescan does).
local function joinPlayer(client)
  local multiseat = extensions.core_multiseat
  if not (multiseat and multiseat.cycleDevicePlayer) then return false, 'unavailable:multiseat' end
  if multiseat.isConfigurationEditActive and multiseat.isConfigurationEditActive() then return false, 'setup_open' end
  if not multiseat.cycleDevicePlayer('vinput' .. client.deviceInst) then return false, 'refused' end
  if core_input_bindings and core_input_bindings.onDeviceChanged then core_input_bindings.onDeviceChanged() end
  return true
end

local function getVehicle(player)
  if type(getPlayerVehicle) ~= 'function' then return nil end
  return getPlayerVehicle(player)
end

-- Every spawned vehicle object; radar.describe() drops props (cones,
-- barriers) by size. getAllVehiclesByType() is NOT used: it queries the
-- vehicle models database, far too slow (and fragile) for 10 Hz.
local function listVehicles()
  local list = {}
  for _, veh in ipairs(type(getAllVehicles) == 'function' and getAllVehicles() or {}) do
    local d = radar.describe(veh)
    if d then list[#list + 1] = d end
  end
  return list
end

local function switchVehicle(player, direction)
  local switching = extensions.core_input_vehicleSwitching
  if not switching then return false, 'unavailable:vehicle_switching' end
  switching.switchCycleVehicle(player, direction)
  return true
end

local function cycleCamera(player, offset)
  if not core_camera then return false, 'unavailable:camera' end
  core_camera.setVehicleCameraByIndexOffset(player, offset)
  return true
end

-- The vehicle's own actions, as the game lists them in Options > Controls.
local function listVehicleActions(model)
  local actions = extensions.core_input_actions
  if not (actions and actions.getActiveActions) then return {} end
  return vehicleActions.vehicleEntries(actions.getActiveActions(), model, type(_tr) == 'function' and _tr or nil)
end

-- Runs one of them on the vehicle like its key binding would (value 1 =
-- pressed, 0 = released).
local function runVehicleAction(vehicle, name, value)
  local actions = extensions.core_input_actions
  if not (actions and actions.getActiveActions and actions.executeCommand) then return false, 'unavailable:input_actions' end
  local action = actions.getActiveActions()[actions.nameToUniqueName(name, vehicle:getJBeamFilename())]
  if not action then return false, 'unknown_command' end
  actions.executeCommand(action, value, vehicle:getID())
  return true
end

-- Point of view video (pov.lua) ----------------------------------------------
-- A hidden render view per phone, driven by a camera context of the game
-- (0.40, the split-screen machinery): it follows the car of the phone's
-- player, starting from the driver's seat, never drawn on the PC screen. The
-- context gets an input player of its own (POV_INPUT_PLAYER, counting down),
-- so the player keeps its own camera on the PC, and the phone cycles the
-- cameras of its video through that input player. The game's video
-- streaming (libbngvs, 0.40) encodes the view on the graphics card and sends
-- it to the phone.

local POV_INPUT_PLAYER = 63
local POV_CAMERA_CHECK_S = 1
-- Time constant of the smooth recentring of a seat camera (95% in 3 of them).
local POV_RECENTER_S = 0.15
local povInputs = {} -- input players in use

-- Same quality cut as split-screen views (render/splitScreen.lua): mirrors
-- and dynamic reflections are each an extra render.
local function povQuality(rv)
  local ok, s = pcall(RenderSettings.getGlobals)
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
local function povLikeMainView(rv)
  local main = RenderViewManagerInstance:getView('main')
  if not main then return end
  rv.upscaleMode = main.upscaleMode
  rv.upscaleRenderScale = main.upscaleRenderScale
  rv.upscaleSharpness = main.upscaleSharpness
  rv.currentExposure = main.currentExposure
end

-- Seat cameras: the car's own dashboard is in view (not from the hood).
local function isInsideCamera(name)
  return name == 'driver' or (name ~= nil and name:find('^occupant%.') ~= nil)
end

local function povCameraName(view)
  local state = core_camera.getContextCameraState(view.id)
  return state and state.cam
end

-- The camera object of the view (its own instance, not the PC's).
local function povCamera(view)
  local cams = view.vid and core_camera.getCameraDataById(view.vid, view.id)
  local name = cams and povCameraName(view)
  return name and cams[name]
end

-- Render views driven by camera contexts and the video streaming both
-- arrived with 0.40, but the native Linux build of the game ships no video
-- streaming (libbngvs is in Bin64 only, startNetworkOutput is missing from
-- BinLinux, checked on 0.40.1): only the Windows build has it, on Linux
-- through Proton. Returns nil when the game can do it, else why not.
local function povUnavailable()
  if not (RenderViewManagerInstance ~= nil and core_camera ~= nil and core_camera.createContext ~= nil) then
    return povModule.UNAVAILABLE_GAME
  end
  if type(startNetworkOutput) ~= 'function' then return povModule.UNAVAILABLE_PLATFORM end
  return nil
end

local povViews = {
  createView = function(id, player, width, height)
    local input = POV_INPUT_PLAYER
    while povInputs[input] do input = input - 1 end
    local rv = RenderViewManagerInstance:getOrCreateView(id)
    rv.luaOwned = true
    rv.renderEditorIcons = false
    rv.namedTexTargetColor = id
    rv.resolution = Point2I(width, height)
    rv.viewPort = RectI(0, 0, width, height)
    rv.compositeRect = RectI(-2, -2, 2, 2) -- off the window: never composited on screen
    rv.frustum = Frustum.construct(false, math.rad(70), width / height, 0.1, 2000)
    povQuality(rv)
    povLikeMainView(rv)
    core_camera.createContext(id, id, input, player)
    povInputs[input] = true
    return { id = id, rv = rv, input = input, player = player, checkAt = 0 }
  end,
  destroyView = function(view)
    core_camera.destroyContext(view.id)
    RenderViewManagerInstance:destroyView(view.rv)
    povInputs[view.input] = nil
  end,
  startOutput = function(view, url, quality, bitrate)
    local q = povModule.QUALITIES[quality]
    -- source, url, container, fps, bitrate, with audio (0 = no), encoder options
    local id = startNetworkOutput(view.id, url, 'mpegts', q.fps, bitrate, 0, povModule.encoderOptions(quality))
    if not id then return nil, 'no_output' end
    return id
  end,
  stopOutput = function(output)
    stopNetworkOutput(output)
  end,
  outputStatus = function(output)
    return getNetworkOutputStatus(output)
  end,
  update = function(view)
    -- The context starts on the car's default camera, and gets it back when
    -- the car changes: the camera of the video (the driver's seat of each
    -- new car) is selected again.
    local now = os.clockhp()
    if now >= view.checkAt then
      view.checkAt = now + POV_CAMERA_CHECK_S
      local veh = getPlayerVehicle(view.player)
      local vid = veh and veh:getID()
      if vid ~= view.vid then
        view.vid = vid
        view.camera = vid and core_camera.getDriverCameraNameById(vid)
      end
      local current = view.camera and povCameraName(view)
      if not view.free and current and current ~= view.camera then core_camera.setContextCamera(view.id, view.camera) end
    end
    return not view.free and isInsideCamera(view.camera)
  end,
  -- Like the game's mouse look (core/input/actions/camera.json), through the
  -- view's own input player: the PC's camera does not move.
  look = function(view, dx, dy)
    view.recentering = nil
    core_camera.rotate_yaw_relative(dx, view.input)
    core_camera.rotate_pitch_relative(-dy, view.input)
  end,
  -- The game resets no camera of a hidden view (core_camera.resetCamera
  -- looks for a car of the view's input player, which has none), and a new
  -- context would reset the PC's cameras too (destroyContext clears the
  -- main view's camera cache). So the view's own camera, from
  -- getCameraDataById, is turned back: smoothly for a seat camera (frame),
  -- with its own reset for the others.
  recenter = function(view)
    local cam = povCamera(view)
    if not cam then return end
    if cam.relativeYaw then
      view.recentering = cam
    elseif cam.reset then
      cam:reset()
    end
  end,
  frame = function(view)
    local now = os.clockhp()
    local dt = math.min(now - (view.frameAt or now), 0.1)
    view.frameAt = now
    local cam = view.recentering
    if not cam then return end
    if cam ~= povCamera(view) then view.recentering = nil return end
    local keep = math.exp(-dt / POV_RECENTER_S)
    cam.relativeYaw, cam.relativePitch = cam.relativeYaw * keep, (cam.relativePitch or 0) * keep
    if math.abs(cam.relativeYaw) + math.abs(cam.relativePitch) < 0.002 then
      cam.relativeYaw, cam.relativePitch = 0, 0
      view.recentering = nil
    end
  end,
  -- The game's free camera of the view, starting where the view looks, or
  -- back to the camera it left.
  setFree = function(view, on)
    view.free = on
    view.recentering = nil
    core_camera.setContextCamera(view.id, on and 'free' or view.camera)
    return true
  end,
  fly = function(view, value)
    core_camera.moveforward(math.max(value, 0), view.input)
    core_camera.movebackward(math.max(-value, 0), view.input)
  end,
  cycleCamera = function(view, offset)
    local current = povCameraName(view)
    core_camera.setVehicleCameraByIndexOffset(view.input, offset)
    local order = {}
    for _, config in ipairs(core_camera.getConfigurationReadOnly()) do
      if config.enabled or config.name == 'driver' or config.name:find('^occupant%.') then order[#order + 1] = config.name end
    end
    local seat = view.vid and core_camera.getDriverCameraNameById(view.vid)
    local camera = povModule.cycleWithSeat(order, current, povCameraName(view), seat, offset)
    if camera and camera ~= povCameraName(view) then core_camera.setContextCamera(view.id, camera) end
    view.camera = camera or view.camera
    return true
  end,
}

local function createServer()
  local config = configModule.new({ readJson = jsonReadFile, writeJson = jsonWriteFile })
  config.load()
  return serverModule.new({
    transport = transportModule.new(socket),
    input = extensions.core_input_virtualInput,
    config = config,
    i18n = i18n,
    logger = logger,
    clock = function() return Engine.Platform.getSystemTimeMS() end,
    notify = notify,
    publishState = function(state) guihooks.trigger('BeamRemotePlusState', state) end,
    getSecurityCode = getSecurityCode,
    nativeRemote = nativeRemote,
    getHostLabel = getHostLabel,
    getHostAddress = getHostAddress,
    playerColor = playerColor,
    joinPlayer = joinPlayer,
    getVehicle = getVehicle,
    listVehicles = listVehicles,
    switchVehicle = switchVehicle,
    cycleCamera = cycleCamera,
    listVehicleActions = listVehicleActions,
    runVehicleAction = runVehicleAction,
    povViews = not povUnavailable() and povViews or nil,
    povUnavailable = povUnavailable(),
    onDeviceCreated = function()
      if core_input_bindings and core_input_bindings.onDeviceChanged then core_input_bindings.onDeviceChanged() end
    end,
    getMods = function() return core_modmanager and core_modmanager.getMods and core_modmanager.getMods() or nil end,
    fileExists = function(path) return FS ~= nil and FS:fileExists(path) end,
  })
end

-- Engine hooks --------------------------------------------------------------

local function onExtensionLoaded()
  server = createServer()
  logger.info('[' .. serverModule.VERSION .. '] loaded')
  return true
end

local function onExtensionUnloaded()
  if server then server.shutdown() end
  nativeRemote.restore()
  server = nil
end

-- Global safety net: whatever happens, an error must never disable the
-- whole extension (and with it the phone controls).
local function onUpdate()
  if not server then return end
  local ok, err = pcall(server.update)
  if not ok then logger.throttled('update', 3000, 'E', 'update error (recovered): ' .. tostring(err)) end
end

local function onInputBindingsChanged(players)
  if not server then return end
  local ok, err = pcall(server.onInputBindingsChanged, players)
  if not ok then logger.warn('onInputBindingsChanged ignored: ' .. tostring(err)) end
end

-- A local player joined, left or edited its persona (name, colour).
local function onLocalParticipantsChanged()
  if not server then return end
  local ok, err = pcall(server.onParticipantsChanged)
  if not ok then logger.warn('players refresh failed: ' .. tostring(err)) end
end

-- The mod manager finished loading, or a mod was enabled, disabled,
-- installed or removed: the optional mods may have changed.
local function onModsChanged()
  if not server then return end
  local ok, err = pcall(server.refreshOptionalMods)
  if not ok then logger.warn('optional mods check failed: ' .. tostring(err)) end
end

-- Public API ------------------------------------------------------------------

-- Called from the vehicle VM (lua/vehicle/extensions/beamRemotePlus/telemetry.lua).
local function onTelemetry(vehicleId, snapshot)
  if not server then return end
  local ok, err = pcall(server.onTelemetry, vehicleId, snapshot)
  if not ok then logger.throttled('telemetry', 3000, 'W', 'telemetry dropped: ' .. tostring(err)) end
end

-- Called from the vehicle VM when a phone asked for the "More" commands.
local function onVehicleFeatures(vehicleId, ids)
  if not server then return end
  local ok, err = pcall(server.onVehicleFeatures, vehicleId, ids)
  if not ok then logger.warn('vehicle commands dropped: ' .. tostring(err)) end
end

-- Called from the vehicle VM when a phone asked for the skeleton geometry.
local function onSkeleton(vehicleId, skeleton)
  if not server then return end
  local ok, err = pcall(server.onSkeleton, vehicleId, skeleton)
  if not ok then logger.warn('skeleton dropped: ' .. tostring(err)) end
end

local function setDebug(enabled) if server then server.setDebug(enabled) end end
local function toggleDebug() if server then server.setDebug(not server.state().debug) end end
local function setLocked(value) if server then server.setLocked(value) end end
local function toggleLocked() if server then server.setLocked(not server.isLocked()) end end
local function kick(ip) if server then server.kick(ip) end end
local function requestState()
  if server then guihooks.trigger('BeamRemotePlusState', server.state()) end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onInputBindingsChanged = onInputBindingsChanged
M.onLocalParticipantsChanged = onLocalParticipantsChanged
M.onModManagerReady = onModsChanged
M.onModActivated = onModsChanged
M.onModDeactivated = onModsChanged
M.onModManagerStateChanged = onModsChanged
M.onTelemetry = onTelemetry
M.onSkeleton = onSkeleton
M.onVehicleFeatures = onVehicleFeatures
M.setDebug = setDebug
M.toggleDebug = toggleDebug
M.setLocked = setLocked
M.toggleLocked = toggleLocked
M.kick = kick
M.requestState = requestState

return M
