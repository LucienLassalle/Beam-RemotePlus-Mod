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

local BUILD_TAG = 'devel-12'
local logTag = 'beamRemotePlus'

-- Chemin VFS du zip et du fichier trigger de hot-reload.
-- Le script de build crée ce trigger après avoir copié le nouveau zip ;
-- onUpdate() le détecte, force le démontage/remontage du zip (nécessaire
-- car BeamNG met en cache le répertoire central du zip à la première
-- activation et ne le relit pas si le fichier est remplacé à chaud), puis
-- recharge l'extension depuis le nouveau contenu.
local MOD_ZIP_PATH   = '/mods/repo/Beam-RemotePlus.zip'
local RELOAD_TRIGGER = '/mods/repo/Beam-RemotePlus-reload.trigger'

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
      'BeamRemotePlus', 'bngremoteplusv1', 3, 2, 0) -- 3 axes, 2 boutons (shiftUp/Down)
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

    -- Sans cet appel, assignedPlayers[deviceInst] reste nil jusqu'à ce que
    -- quelque chose d'autre déclenche un rescan des périphériques d'entrée
    -- (typiquement : désactiver puis réactiver le mod). core_input_bindings
    -- ne détecte pas nativement la création d'un périphérique virtuel via
    -- core_input_virtualInput (contrairement à un vrai périphérique USB, qui
    -- déclenche onDeviceChanged() côté moteur) : on force donc le même
    -- rescan explicitement pour que le device soit assigné à un joueur et
    -- que onInputBindingsChanged (voir plus bas) peuple assignedPlayers
    -- immédiatement, sans attendre.
    if core_input_bindings and core_input_bindings.onDeviceChanged then
      core_input_bindings.onDeviceChanged()
    else
      log('W', logTag, 'core_input_bindings.onDeviceChanged not available, player assignment may be delayed')
    end
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
    local player = assignedPlayers[client.deviceInst] or 0
    extensions.core_input_vehicleSwitching.switchCycleVehicle(player, 1)
    client.forcedEmit = true
    log('I', logTag, 'next vehicle (player=' .. tostring(player) .. ', from ' .. ip .. ')')
  elseif data == protocol.CMD_PREV_VEHICLE then
    local player = assignedPlayers[client.deviceInst] or 0
    extensions.core_input_vehicleSwitching.switchCycleVehicle(player, -1)
    client.forcedEmit = true
    log('I', logTag, 'prev vehicle (player=' .. tostring(player) .. ', from ' .. ip .. ')')
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
  elseif data == protocol.CMD_GEAR_UP then
    -- Impulsion bouton 0 (shiftUp) : pression immédiatement suivie d'un relâchement
    extensions.core_input_virtualInput.emit(client.deviceInst, 'button', 0, 'change', 1)
    extensions.core_input_virtualInput.emit(client.deviceInst, 'button', 0, 'change', 0)
    log('I', logTag, 'gear up (from ' .. ip .. ')')
  elseif data == protocol.CMD_GEAR_DOWN then
    extensions.core_input_virtualInput.emit(client.deviceInst, 'button', 1, 'change', 1)
    extensions.core_input_virtualInput.emit(client.deviceInst, 'button', 1, 'change', 0)
    log('I', logTag, 'gear down (from ' .. ip .. ')')
  elseif data == protocol.CMD_RECOVER_START then
    -- recovery.startRecovering() est la fonction déclenchée par onDown de
    -- l'action native "recover_vehicle" (touche Insert) : elle vit côté
    -- véhicule (VE Lua), d'où le passage par vehicle:queueLuaCommand plutôt
    -- qu'un appel direct comme be:resetVehicle. getPlayerVehicle(player)
    -- scope l'appel au véhicule assigné à ce player slot uniquement.
    local player = assignedPlayers[client.deviceInst] or 0
    local vehicle = getPlayerVehicle(player)
    if vehicle then
      vehicle:queueLuaCommand('recovery.startRecovering()')
      log('I', logTag, 'recover start (player=' .. tostring(player) .. ', from ' .. ip .. ')')
    end
  elseif data == protocol.CMD_RECOVER_STOP then
    -- recovery.stopRecovering() fige le véhicule au point de rembobinage
    -- atteint (voir lua/vehicle/recovery.lua) : un stop quasi immédiat
    -- après un start ressemble donc à une réinitialisation simple, un stop
    -- tardif à une vraie récupération, exactement comme relâcher Insert.
    local player = assignedPlayers[client.deviceInst] or 0
    local vehicle = getPlayerVehicle(player)
    if vehicle then
      vehicle:queueLuaCommand('recovery.stopRecovering()')
      log('I', logTag, 'recover stop (player=' .. tostring(player) .. ', from ' .. ip .. ')')
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

  -- Après un changement de véhicule, forcedEmit=true pour ré-émettre tous les
  -- axes même si les valeurs n'ont pas changé. Sans ça, BeamNG garde keyboard0
  -- en priorité car vinput0 n'a envoyé aucun événement récent sur le nouveau véhicule.
  local forceEmit = client.forcedEmit
  if forceEmit then client.forcedEmit = false end

  if forceEmit or state[1] ~= steering then
    extensions.core_input_virtualInput.emit(client.deviceInst, 'axis', 0, 'change', steering)
  end
  if forceEmit or state[2] ~= throttle then
    extensions.core_input_virtualInput.emit(client.deviceInst, 'axis', 1, 'change', throttle)
  end
  if forceEmit or state[3] ~= brake then
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
    if electrics and electrics.values then
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

  -- Hot-reload : vérifie le trigger toutes les ~3 s (≈180 ticks à 60 Hz).
  -- Le trigger est créé par le script de build après avoir écrit le nouveau
  -- zip. On démonte l'ancien zip (libère le répertoire central mis en cache),
  -- on remonte le nouveau depuis le disque, puis on recharge l'extension.
  -- Le trigger est supprimé AVANT le rechargement pour éviter toute boucle.
  if updateTicks % 180 == 0 and FS:fileExists(RELOAD_TRIGGER) then
    log('I', logTag, '[' .. BUILD_TAG .. '] hot-reload trigger détecté — remontage du zip')
    FS:removeFile(RELOAD_TRIGGER)
    if FS:isMounted(MOD_ZIP_PATH) then
      FS:unmount(MOD_ZIP_PATH)
      FS:mountList({{ srcPath = MOD_ZIP_PATH, mountPath = nil }})
    end
    extensions.reload('beamRemotePlus_main')
    return
  end

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
