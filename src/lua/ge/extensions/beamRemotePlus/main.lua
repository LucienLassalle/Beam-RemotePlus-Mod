-- Beam-RemotePlus GE extension entry point (extensions.beamRemotePlus_main).
--
-- This file only binds BeamNG globals to the testable modules next to it;
-- the logic lives in server.lua. Public functions below are also the API
-- used by the input action (Options > Controls) and the in-game UI app.

local MODULE_DIR = '/lua/ge/extensions/beamRemotePlus/'
local SIBLINGS = { 'json', 'protocol', 'config', 'i18n', 'logger', 'clients',
  'commands', 'radar', 'telemetry', 'transport', 'nativeRemote', 'version', 'optionalMods', 'server' }

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
    getVehicle = getVehicle,
    listVehicles = listVehicles,
    switchVehicle = switchVehicle,
    cycleCamera = cycleCamera,
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
M.onModManagerReady = onModsChanged
M.onModActivated = onModsChanged
M.onModDeactivated = onModsChanged
M.onModManagerStateChanged = onModsChanged
M.onTelemetry = onTelemetry
M.onSkeleton = onSkeleton
M.setDebug = setDebug
M.toggleDebug = toggleDebug
M.setLocked = setLocked
M.toggleLocked = toggleLocked
M.kick = kick
M.requestState = requestState

return M
