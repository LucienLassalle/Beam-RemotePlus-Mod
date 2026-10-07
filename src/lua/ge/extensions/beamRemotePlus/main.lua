-- Beam-RemotePlus GE extension entry point (extensions.beamRemotePlus_main).
--
-- This file only binds BeamNG globals to the testable modules next to it;
-- the logic lives in server.lua. Public functions below are also the API
-- used by the input action (Options > Controls) and the in-game UI app.

local MODULE_DIR = '/lua/ge/extensions/beamRemotePlus/'
local SIBLINGS = { 'json', 'protocol', 'config', 'i18n', 'logger', 'clients',
  'commands', 'radar', 'telemetry', 'transport', 'server', 'devReload' }

-- require() caches by path independently of extensions.reload(): without
-- this, reloading the mod would keep running stale sibling modules.
for _, name in ipairs(SIBLINGS) do package.loaded[MODULE_DIR .. name] = nil end

local configModule = require(MODULE_DIR .. 'config')
local i18nModule = require(MODULE_DIR .. 'i18n')
local loggerModule = require(MODULE_DIR .. 'logger')
local transportModule = require(MODULE_DIR .. 'transport')
local serverModule = require(MODULE_DIR .. 'server')
local devReload = require(MODULE_DIR .. 'devReload')
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

local function getSecurityCode()
  local rc = extensions.core_remoteController
  if not (rc and rc.getQRCode) then return nil end
  local code = rc.getQRCode() -- also opens the native socket on first call
  if not code then return nil end
  return tostring(code)
end

local function getHostLabel()
  local ok, name = pcall(function() return Steam and Steam.playerName end)
  if ok and type(name) == 'string' and name ~= '' then
    return i18n.t('beamRemotePlus.label.host', { name = name })
  end
  return 'BeamNG.drive'
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
    getHostLabel = getHostLabel,
    getVehicle = getVehicle,
    listVehicles = listVehicles,
    switchVehicle = switchVehicle,
    cycleCamera = cycleCamera,
    onDeviceCreated = function()
      if core_input_bindings and core_input_bindings.onDeviceChanged then core_input_bindings.onDeviceChanged() end
    end,
  })
end

-- Engine hooks --------------------------------------------------------------

local function onExtensionLoaded()
  server = createServer()
  logger.info('[' .. serverModule.VERSION .. '] loaded, phones ' .. (server.isEnabled() and 'enabled' or 'disabled'))
  return true
end

local function onExtensionUnloaded()
  if server then server.shutdown() end
  server = nil
end

-- Global safety net: whatever happens, an error must never disable the
-- whole extension (and with it the phone controls).
local function onUpdate()
  if devReload.check() then return end
  if not server then return end
  local ok, err = pcall(server.update)
  if not ok then logger.throttled('update', 3000, 'E', 'update error (recovered): ' .. tostring(err)) end
end

local function onInputBindingsChanged(players)
  if not server then return end
  local ok, err = pcall(server.onInputBindingsChanged, players)
  if not ok then logger.warn('onInputBindingsChanged ignored: ' .. tostring(err)) end
end

-- Public API ------------------------------------------------------------------

-- Called from the vehicle VM (lua/vehicle/extensions/beamRemotePlus/telemetry.lua).
local function onTelemetry(vehicleId, snapshot)
  if not server then return end
  local ok, err = pcall(server.onTelemetry, vehicleId, snapshot)
  if not ok then logger.throttled('telemetry', 3000, 'W', 'telemetry dropped: ' .. tostring(err)) end
end

local function setEnabled(enabled) if server then server.setEnabled(enabled) end end
local function toggleEnabled() if server then server.setEnabled(not server.isEnabled()) end end
local function setDebug(enabled) if server then server.setDebug(enabled) end end
local function toggleDebug() if server then server.setDebug(not server.state().debug) end end
local function requestState()
  if server then guihooks.trigger('BeamRemotePlusState', server.state()) end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onInputBindingsChanged = onInputBindingsChanged
M.onTelemetry = onTelemetry
M.setEnabled = setEnabled
M.toggleEnabled = toggleEnabled
M.setDebug = setDebug
M.toggleDebug = toggleDebug
M.requestState = requestState

return M
