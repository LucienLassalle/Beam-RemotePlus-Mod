-- Beam-RemotePlus: extension complémentaire optionnelle pour l'app mobile
-- Beam-RemotePlus. Ajoute deux choses que le contrôle à distance natif ne
-- fournit pas :
--   1. Une télémétrie fiable (le canal natif appelle une fonction dépréciée
--      côté jeu et n'envoie donc jamais rien).
--   2. Des pédales réellement analogiques (le périphérique virtuel natif
--      n'a qu'un axe et deux boutons tout-ou-rien).
--
-- Réutilise le code de sécurité déjà généré par l'extension native
-- core_remoteController : un seul QR code à scanner, aucune configuration
-- supplémentaire côté jeu.
--
-- La logique testable (sans dépendance à l'environnement BeamNG) vit dans
-- protocol.lua ; voir Beam-RemotePlus-Mod/test/ pour les tests unitaires.

local BUILD_TAG = 'devel-8'
local logTag = 'beamRemotePlus'

-- require() met en cache par chemin (package.loaded), indépendamment du
-- cache d'extensions.lua : sans ce clear, un `extensions.reload()` de ce
-- fichier récupérerait quand même l'ancienne version de protocol.lua si
-- elle a déjà été chargée une fois dans cette session de jeu.
package.loaded['/lua/ge/extensions/beamRemotePlus/protocol'] = nil
local protocol = require('/lua/ge/extensions/beamRemotePlus/protocol')

local M = {}

local udpSocket = nil
local clients = {}          -- [ip] = { deviceInst, state = {steering,throttle,brake}, lastSeen }
local assignedPlayers = {}  -- [deviceInst] = player
local lastTelemetrySent = {}
local lastHeartbeat = 0
local updateTicks = 0

local function ensureSocket()
  if udpSocket then return true end
  local ok, sock = pcall(socket.udp)
  if not ok or not sock then
    log('E', logTag, 'socket.udp() failed: ' .. tostring(sock))
    return false
  end
  udpSocket = sock
  local bound = udpSocket:setsockname('*', protocol.HOST_PORT)
  if bound == nil then
    log('W', logTag, 'unable to bind UDP socket on port ' .. protocol.HOST_PORT .. ' (already in use?)')
    udpSocket = nil
    return false
  end
  udpSocket:settimeout(0)
  log('I', logTag, '[' .. BUILD_TAG .. '] listening on port ' .. protocol.HOST_PORT)
  return true
end

local function getSecurityCode()
  local rc = extensions.core_remoteController
  if not rc then
    log('W', logTag, 'extensions.core_remoteController not found')
    return nil
  end
  if not rc.getQRCode then
    log('W', logTag, 'core_remoteController.getQRCode not found')
    return nil
  end
  local code = rc.getQRCode()
  if code == false then
    log('W', logTag, 'core_remoteController.getQRCode() returned false')
    return nil
  end
  return tostring(code)
end

local function handlePing(ip, data)
  local code = getSecurityCode()
  log('I', logTag, 'ping from ' .. ip .. ': got=' .. data .. ' code=' .. tostring(code))
  if not protocol.pingMatchesCode(data, code) then
    log('W', logTag, 'ping rejected (code mismatch or unavailable)')
    return
  end

  if not clients[ip] then
    local deviceInst = extensions.core_input_virtualInput.createDevice(
      'BeamRemotePlus', 'bngremoteplusv1', 3, 0, 0)
    if not deviceInst or deviceInst < 0 then
      log('E', logTag, 'unable to create virtual input device for ' .. ip)
      return
    end
    clients[ip] = { deviceInst = deviceInst, state = { 0.5, 0, 0 } }
    log('I', logTag, 'client connected: ' .. ip .. ' (deviceInst=' .. tostring(deviceInst) .. ')')
    guihooks.trigger('toastrMsg', {
      type = 'info',
      title = 'Beam-RemotePlus',
      msg = 'Mod actif : téléphone connecté (' .. ip .. ')',
    })
  end
  clients[ip].lastSeen = Engine.Platform.getSystemTimeMS()
  local pong = protocol.buildPongMessage(code)
  udpSocket:sendto(pong, ip, protocol.CLIENT_PORT)
  log('I', logTag, 'pong sent to ' .. ip .. ':' .. protocol.CLIENT_PORT .. ' -> ' .. pong)
end

local function handleCommand(ip, data)
  local client = clients[ip]
  if not client then return end
  client.lastSeen = Engine.Platform.getSystemTimeMS()

  if data == protocol.CMD_NEXT_VEHICLE then
    be:nextVehicle()
    log('I', logTag, 'next vehicle (from ' .. ip .. ')')
  elseif data == protocol.CMD_PREV_VEHICLE then
    be:prevVehicle()
    log('I', logTag, 'prev vehicle (from ' .. ip .. ')')
  elseif data == protocol.CMD_CAM_NEXT then
    local player = assignedPlayers[client.deviceInst] or 0
    if core_camera then
      core_camera.setVehicleCameraByIndexOffset(player, 1)
      log('I', logTag, 'cam next (player=' .. tostring(player) .. ')')
    else
      log('W', logTag, 'core_camera not available for cam_next')
    end
  elseif data == protocol.CMD_CAM_PREV then
    local player = assignedPlayers[client.deviceInst] or 0
    if core_camera then
      core_camera.setVehicleCameraByIndexOffset(player, -1)
      log('I', logTag, 'cam prev (player=' .. tostring(player) .. ')')
    else
      log('W', logTag, 'core_camera not available for cam_prev')
    end
  else
    log('W', logTag, 'unknown command from ' .. ip .. ': ' .. tostring(data))
  end
end

local function handleControl(ip, data)
  local client = clients[ip]
  if not client then return end

  local steering, throttle, brake = protocol.decodeControlPacket(data)
  if steering == nil then
    log('W', logTag, 'control packet from ' .. ip .. ' has wrong size: ' .. #data)
    return
  end
  client.lastSeen = Engine.Platform.getSystemTimeMS()

  steering = protocol.clampUnit(steering)
  throttle = protocol.clampUnit(throttle)
  brake = protocol.clampUnit(brake)
  local state = client.state

  if state[1] ~= steering then
    extensions.core_input_virtualInput.emit(client.deviceInst, 'axis', 0, 'change', steering)
  end
  if state[2] ~= throttle then
    extensions.core_input_virtualInput.emit(client.deviceInst, 'axis', 1, 'change', throttle)
  end
  if state[3] ~= brake then
    extensions.core_input_virtualInput.emit(client.deviceInst, 'axis', 2, 'change', brake)
  end
  client.state = { steering, throttle, brake }
end

-- Lit les données du véhicule assigné à ce client et les renvoie via
-- onTelemetry(). Exécuté côté véhicule car electrics.values n'est
-- accessible que dans ce contexte.
local function requestTelemetry(ip, client)
  local player = assignedPlayers[client.deviceInst]
  if not player then return end
  local vehicle = getPlayerVehicle(player)
  if not vehicle then return end

  -- Duplique volontairement le calcul des feux et le format d'appel de
  -- protocol.lua : ce bloc s'exécute dans l'état Lua du VÉHICULE (VM
  -- séparée de celle du GE, voir queueLuaCommand/queueGameEngineLua), qui
  -- n'a pas accès à ce module GE. Garder buildTelemetryCallExpression et
  -- ce format en synchronisation (le test dédié documente le format
  -- attendu, y compris le bug %q corrigé ici).
  local ipLiteral = string.format('%q', ip)
  local vehicleCommand = [[
    if electrics and electrics.values and electrics.values.watertemp then
      local e = electrics.values
      local lights = 0
      if e.lowbeam == 1 then lights = lights + 1 end
      if e.highbeam == 1 then lights = lights + 2 end
      if e.parkingbrake and e.parkingbrake > 0 then lights = lights + 4 end
      if e.signal_L and e.signal_L ~= 0 then lights = lights + 8 end
      if e.signal_R and e.signal_R ~= 0 then lights = lights + 16 end
      if e.oil and e.oil ~= 0 then lights = lights + 32 end
      if e.hasABS and e.absActive and e.absActive ~= 0 then lights = lights + 64 end
      local shiftLight = e.shouldShift and 1 or 0
      obj:queueGameEngineLua(string.format(
        "extensions.beamRemotePlus_main.onTelemetry(%q, %s, %s, %s, %s, %s, %s, %s, %s)",
  ]] .. ipLiteral .. [[, e.wheelspeed or 0, e.rpm or 0,
        e.maxrpm or 0, (e.gearIndex or -1) + 1,
        e.fuel or 0, e.watertemp or 0, lights, shiftLight))
    end
  ]]
  vehicle:queueLuaCommand(vehicleCommand)
end

local function onTelemetry(ip, speed, rpm, redlineRpm, gear, fuel, engineTemp, lights, shiftLight)
  if not udpSocket or not clients[ip] then return end
  local bytes = protocol.encodeTelemetryPacket(
    speed, rpm, redlineRpm, gear, fuel, engineTemp, lights, shiftLight)
  udpSocket:sendto(bytes, ip, protocol.CLIENT_PORT)
end

local function onUpdate()
  updateTicks = updateTicks + 1
  if not ensureSocket() then return end
  local now = Engine.Platform.getSystemTimeMS()

  if now - lastHeartbeat > protocol.HEARTBEAT_INTERVAL_MS then
    lastHeartbeat = now
    local clientCount = 0
    for _ in pairs(clients) do clientCount = clientCount + 1 end
    log('I', logTag, '[' .. BUILD_TAG .. '] heartbeat: alive, ticks=' .. updateTicks .. ', clients=' .. clientCount)
  end

  for ip, client in pairs(clients) do
    if protocol.isClientTimedOut(now, client.lastSeen, protocol.CLIENT_TIMEOUT_MS) then
      extensions.core_input_virtualInput.deleteDevice(client.deviceInst)
      clients[ip] = nil
      lastTelemetrySent[ip] = nil
      log('I', logTag, 'client timed out: ' .. ip)
    end
  end

  while true do
    local data, ip = udpSocket:receivefrom(64)
    if not data then break end
    if protocol.isPingMessage(data) then
      handlePing(ip, data)
    elseif clients[ip] then
      if protocol.isCmdMessage(data) then
        handleCommand(ip, data)
      else
        handleControl(ip, data)
      end
    else
      log('W', logTag, 'unexpected packet from unknown client ' .. tostring(ip) .. ', ' .. #data .. ' octets')
    end
  end

  for ip, client in pairs(clients) do
    local last = lastTelemetrySent[ip] or 0
    if now - last >= protocol.TELEMETRY_INTERVAL_MS then
      lastTelemetrySent[ip] = now
      requestTelemetry(ip, client)
    end
  end
end

local function onInputBindingsChanged(players)
  for device, player in pairs(players) do
    for _, client in pairs(clients) do
      if 'vinput' .. client.deviceInst == device then
        assignedPlayers[client.deviceInst] = player
        log('I', logTag, 'device ' .. device .. ' assigned to player ' .. tostring(player))
      end
    end
  end
end

local function onExtensionLoaded()
  log('I', logTag, '[' .. BUILD_TAG .. '] onExtensionLoaded')
  return true
end

local function onExtensionUnloaded()
  log('I', logTag, 'onExtensionUnloaded')
  if udpSocket then
    udpSocket:close()
    udpSocket = nil
  end
  for _, client in pairs(clients) do
    extensions.core_input_virtualInput.deleteDevice(client.deviceInst)
  end
  clients = {}
  assignedPlayers = {}
  lastTelemetrySent = {}
end

log('I', logTag, '[' .. BUILD_TAG .. '] module file executed (top-level)')

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onInputBindingsChanged = onInputBindingsChanged
M.onTelemetry = onTelemetry

return M
