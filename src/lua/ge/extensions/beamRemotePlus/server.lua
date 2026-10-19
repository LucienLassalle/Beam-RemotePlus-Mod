-- Core of the mod: routes incoming datagrams, owns the lock on new phones
-- and the per-frame work. Every BeamNG API is injected by main.lua,
-- which keeps this file fully unit-testable (see test/server_test.lua).

local protocol = require('/lua/ge/extensions/beamRemotePlus/protocol')
local clientsModule = require('/lua/ge/extensions/beamRemotePlus/clients')
local commandsModule = require('/lua/ge/extensions/beamRemotePlus/commands')
local telemetryModule = require('/lua/ge/extensions/beamRemotePlus/telemetry')
local optionalModsModule = require('/lua/ge/extensions/beamRemotePlus/optionalMods')
local povModule = require('/lua/ge/extensions/beamRemotePlus/pov')
local versionModule = require('/lua/ge/extensions/beamRemotePlus/version')
local vehicleActions = require('/lua/ge/extensions/beamRemotePlus/vehicleActions')

local M = {}

-- 'dev' in the sources: scripts/build_mod.sh stamps the release version.
M.VERSION = 'dev'
M.MAX_PACKETS_PER_FRAME = 256

-- Holds or releases the handbrake, like the "parking brake (hold)" input
-- action of the game.
function M.handbrakeCode(on)
  return string.format("input.event('parkingbrake', %d, -1)", on and 1 or 0)
end

-- What the watchdog needs of a telemetry snapshot: speed (m/s), whether
-- the car is in reverse, and whether its gearbox is in arcade mode (where
-- the pedals swap in reverse).
function M.motionOf(t)
  local speed = tonumber(t.airspeed) or tonumber(t.speed)
  if not speed then return nil end
  return {
    speed = math.abs(speed),
    reverse = (tonumber(t.gearIndex) or 0) < 0 or t.gear == 'R',
    arcade = t.gearboxMode == 'arcade',
  }
end

-- Asks the vehicle VM which generic commands the vehicle is fitted for
-- (answered through extensions.beamRemotePlus_main.onVehicleFeatures).
M.FEATURES_REQUEST = 'local e = extensions.beamRemotePlus_telemetry if e and e.sendFeatures then e.sendFeatures() end'

--[[
deps:
  transport   { open(port) -> ok, err ; close() ; receive() -> data, ip ; send(payload, ip, port) }
  input       core_input_virtualInput-like { createDevice, deleteDevice, emit }
  config      config.new(...) instance
  i18n        i18n.new(...) instance
  logger      logger.new(...) instance
  clock()     -> ms
  notify(text, kind)          in-game toast
  publishState(state)         pushes state to the in-game UI app
  getSecurityCode()           -> string or nil
  getHostLabel()              -> string
  getHostAddress()            optional, -> the PC address on the local network
  playerColor(player)         optional, -> "#rrggbb", the colour the game gives that player
  getVehicle(player)          -> vehicle or nil
  listVehicles()              -> radar descriptions of every car (optional)
  switchVehicle(player, dir)  -> ok, err
  cycleCamera(player, offset) -> ok, err
  onDeviceCreated()           optional, forces an input device rescan
  joinPlayer(client)          optional, joins the phone to the local players
                              (it had none, 0.40 multiseat) -> ok, err
  getMods()                   optional, core_modmanager.getMods()
  fileExists(path)            optional, file in the game's virtual file system
  nativeRemote                optional nativeRemote.new(...) instance: the
                              game's own remote control (UDP 4444)
  listVehicleActions(model)   optional, the vehicle's own actions (vehicleActions.vehicleEntries)
  povViews                    optional { createView, destroyView, setActive, capture }: the
                              game's hidden views for the point of view video (pov.lua)
  runVehicleAction(vehicle, name, value)  optional, runs one of them -> ok, err
]]
function M.new(deps)
  local self = {}
  local log = deps.logger
  -- Last known motion of each car (from its telemetry), for the watchdog.
  local motions = {}
  local clients = clientsModule.new(deps.input, deps.clock, {
    motion = function(client) return client.vehicleId and motions[client.vehicleId] or nil end,
    setHandbrake = function(client, on)
      local vehicle = deps.getVehicle(client.player or 0)
      if vehicle then vehicle:queueLuaCommand(M.handbrakeCode(on)) end
    end,
  })
  local listening = false
  local lastDiscoverToast = 0
  local lastHeartbeat = 0
  local pairingToastShown = false
  -- Locked: new phones are refused, connected ones keep driving. Session
  -- only (never saved), so a restart never leaves phones locked out.
  local locked = false
  -- The game's own remote control accepts the same pairing code: kept in
  -- sync with the lock and checked again every second, in case the game
  -- reloaded the module the lock relies on.
  local NATIVE_SYNC_MS = 1000
  local lastNativeSync = nil
  local nativeWarned = false
  -- Phones disconnected in the last DISCONNECTED_SHOWN_MS, still listed by
  -- the panel (greyed out), and what it last showed of every phone.
  local gone = {}
  local lastStatuses = ''

  -- Phones to join to the local players on the next frame (ips).
  local pendingJoins = {}

  local function send(client, payload)
    deps.transport.send(payload, client.ip, protocol.CLIENT_PORT)
  end

  -- Phones waiting for the "More" commands of a vehicle: [vehicleId] =
  -- { model, ips = { [ip] = true } }, answered by onVehicleFeatures.
  local pendingActions = {}

  local function requestActions(client)
    if client.version < 2 then return false, commandsModule.ERR_UNAVAILABLE end
    local vehicle = deps.getVehicle(client.player or 0)
    if not vehicle then return false, commandsModule.ERR_NO_VEHICLE end
    local id = vehicle:getID()
    local pending = pendingActions[id] or { ips = {} }
    pending.model = vehicle.getJBeamFilename and vehicle:getJBeamFilename() or nil
    pending.ips[client.ip] = true
    pendingActions[id] = pending
    vehicle:queueLuaCommand(M.FEATURES_REQUEST)
    return true
  end

  local function runVehicleAction(client, name, value)
    local vehicle = deps.getVehicle(client.player or 0)
    if not vehicle then return false, commandsModule.ERR_NO_VEHICLE end
    if not deps.runVehicleAction then return false, commandsModule.ERR_UNAVAILABLE end
    return deps.runVehicleAction(vehicle, name, value)
  end

  local pov = deps.povViews and povModule.new({
    createView = deps.povViews.createView,
    destroyView = deps.povViews.destroyView,
    setActive = deps.povViews.setActive,
    capture = deps.povViews.capture,
    send = function(payload, ip, port) deps.transport.send(payload, ip, port) end,
    clock = deps.clock,
  }) or nil

  -- quality: false = off, true = default, else a quality of pov.lua.
  local function setPov(client, quality)
    if not quality then
      if pov.stop(client.ip) then log.info('point of view video stopped for ' .. client.deviceName) end
      return true
    end
    quality = quality ~= true and quality or nil
    local ok, err = pov.start(client, quality)
    if ok then
      log.info('point of view video for ' .. client.deviceName .. ' (player ' .. tostring(client.player) .. ', '
        .. (quality or povModule.DEFAULT_QUALITY) .. ')')
    end
    return ok, err
  end

  local commands = commandsModule.new({
    getVehicle = deps.getVehicle,
    switchVehicle = deps.switchVehicle,
    cycleCamera = deps.cycleCamera,
    pulseButton = function(client, button) clients.pulseButton(client, button) end,
    buttons = { shiftUp = clientsModule.BUTTON_SHIFT_UP, shiftDown = clientsModule.BUTTON_SHIFT_DOWN },
    requestActions = requestActions,
    runVehicleAction = runVehicleAction,
    setPov = pov and setPov or nil,
  })

  local telemetry = telemetryModule.new({
    getVehicle = deps.getVehicle,
    listVehicles = deps.listVehicles,
    clock = deps.clock,
    send = send,
  })

  local optionalMods = optionalModsModule.new({
    getMods = deps.getMods or function() return nil end,
    fileExists = deps.fileExists or function() return false end,
  })
  optionalMods.refresh()

  local function releaseHold(client, name) commands.release(client, name) end

  self.clients = clients

  function self.isListening() return listening end
  function self.isLocked() return locked end

  local function forget(ip)
    for i = #gone, 1, -1 do
      if gone[i].ip == ip then table.remove(gone, i) end
    end
  end

  -- Colour of the player of a driving phone, as the game shows it above its
  -- car in local multiplayer; nil for a second screen or while unassigned.
  local function colorOf(client)
    if client.display or client.player == nil or client.player < 0 or not deps.playerColor then return nil end
    local ok, color = pcall(deps.playerColor, client.player)
    return ok and color or nil
  end

  local function rememberGone(client)
    forget(client.ip)
    gone[#gone + 1] = {
      ip = client.ip, device = client.deviceName, player = client.player, display = client.display,
      appVersion = client.appVersion, color = colorOf(client), at = deps.clock(),
    }
  end

  -- One "ip=status" per phone: the panel is refreshed when it changes.
  local function statuses(now)
    local list = {}
    clients.each(function(ip, client) list[#list + 1] = ip .. '=' .. clients.status(client, now) end)
    for _, entry in ipairs(gone) do list[#list + 1] = entry.ip .. '=' .. protocol.STATUS_DISCONNECTED end
    table.sort(list)
    return table.concat(list, ',')
  end

  function self.state()
    local now = deps.clock()
    local phones = {}
    clients.each(function(ip, client)
      phones[#phones + 1] = {
        ip = ip, device = client.deviceName, player = client.player, protocol = client.version, display = client.display,
        status = clients.status(client, now),
        color = colorOf(client),
        -- update: 'app' or 'mod' when that side is older than the other one.
        appVersion = client.appVersion, update = versionModule.outdated(M.VERSION, client.appVersion),
      }
    end)
    -- Disconnected phones last, without the update warning (nothing to do).
    for _, entry in ipairs(gone) do
      phones[#phones + 1] = {
        ip = entry.ip, device = entry.device, player = entry.player, display = entry.display,
        appVersion = entry.appVersion, status = protocol.STATUS_DISCONNECTED,
        color = entry.color,
      }
    end
    return {
      version = M.VERSION,
      listening = listening,
      locked = locked,
      debug = deps.config.get('debug'),
      code = listening and deps.getSecurityCode() or nil,
      -- QR code of the panel, null until the pairing code is known.
      pairingUri = listening and protocol.buildPairingUri(deps.getSecurityCode(),
        deps.getHostAddress and deps.getHostAddress()) or nil,
      port = protocol.HOST_PORT,
      phones = phones,
      optionalMods = optionalMods.list(),
    }
  end

  local function publish()
    lastStatuses = statuses(deps.clock())
    pcall(deps.publishState, self.state())
  end

  local function startListening()
    if listening then return true end
    local ok, err = deps.transport.open(protocol.HOST_PORT)
    if not ok then
      log.throttled('bind', 30000, 'W', 'cannot listen on UDP ' .. protocol.HOST_PORT .. ': ' .. tostring(err))
      return false
    end
    listening = true
    log.info('[' .. M.VERSION .. '] listening on UDP ' .. protocol.HOST_PORT)
    publish()
    return true
  end

  local function stopListening()
    clients.disconnectAll(releaseHold)
    if listening then deps.transport.close() end
    listening = false
    publish()
  end

  function self.setDebug(enabled)
    deps.config.set('debug', enabled and true or false)
    log.debugEnabled = enabled and true or false
    publish()
  end

  -- Open while new phones are allowed (the apps pair through it first);
  -- while they are locked out, it cannot pair new phones either.
  local function syncNative()
    local native = deps.nativeRemote
    if not native then return end
    lastNativeSync = deps.clock()
    local ok, enforced = pcall(native.setLocked, locked)
    if not locked then
      nativeWarned = false
      pcall(native.open)
      return
    end
    if ok and enforced then return end
    if not nativeWarned then
      nativeWarned = true
      log.warn('cannot lock the game remote control (UDP 4444): ' .. tostring(enforced))
      deps.notify(deps.i18n.t('beamRemotePlus.toast.nativeOpen'), 'error')
    end
  end

  function self.setLocked(value)
    value = value and true or false
    if locked == value then return end
    locked = value
    log.info(locked and 'new phones locked out' or 'new phones allowed again')
    syncNative()
    deps.notify(deps.i18n.t(locked and 'beamRemotePlus.toast.locked' or 'beamRemotePlus.toast.unlocked'),
      locked and 'warning' or 'info')
    publish()
  end

  -- Kick = disconnect now. The phone may pair again (unless locked): v2
  -- apps are told so they stop reconnecting on their own; v1 apps cannot
  -- be told and reconnect at their next ping.
  function self.kick(ip)
    local client = clients.get(ip)
    if not client then return false end
    if client.version >= 2 then send(client, protocol.buildKickedMessage()) end
    clients.disconnect(ip, releaseHold)
    rememberGone(client)
    log.info('phone kicked: ' .. client.deviceName .. ' (' .. ip .. ')')
    deps.notify(deps.i18n.t('beamRemotePlus.toast.phoneKicked', { device = client.deviceName }), 'warning')
    publish()
    return true
  end

  function self.shutdown()
    if pov then pov.stopAll() end
    stopListening()
  end

  -- Packet handlers ---------------------------------------------------------

  local function handleDiscover(ip, data)
    -- Locked: the PC must not hand its pairing code to new phones.
    if locked then
      log.throttled('locked:' .. ip, 5000, 'I', 'discover from ' .. ip .. ' ignored: new phones are locked out')
      return
    end
    local code = deps.getSecurityCode()
    if not code then
      log.warn('discover from ' .. ip .. ' ignored: pairing code unavailable')
      return
    end
    deps.transport.send(protocol.buildHelloMessage(code, deps.getHostLabel(), protocol.discoverPrefix(data)), ip, protocol.CLIENT_PORT)
    log.debug('discover from ' .. ip .. ' -> hello sent')
    local now = deps.clock()
    if now - lastDiscoverToast > 5000 then -- the app probes ~2x/s
      lastDiscoverToast = now
      deps.notify(deps.i18n.t('beamRemotePlus.toast.autoPairing', { ip = ip }), 'info')
    end
  end

  local function handlePing(ip, data)
    local code = deps.getSecurityCode()
    if not protocol.pingMatchesCode(data, code) then
      log.warn('ping from ' .. ip .. ' rejected (wrong or unavailable pairing code)')
      return
    end
    if locked and not clients.get(ip) then
      log.throttled('locked:' .. ip, 5000, 'I', 'ping from ' .. ip .. ' ignored: new phones are locked out')
      return
    end
    local ping = protocol.parsePing(data)
    local client, isNew, err = clients.connect(ip, ping)
    if not client then
      log.error('cannot connect ' .. ip .. ': ' .. tostring(err))
      return
    end
    deps.transport.send(protocol.buildPongMessage(code, client.version, ping.prefix), ip, protocol.CLIENT_PORT)
    if isNew then
      forget(ip)
      -- BeamNG does not notice virtual devices on its own: without a rescan
      -- the device is not assigned to a player until something else
      -- triggers one (e.g. toggling the mod).
      if deps.onDeviceCreated then pcall(deps.onDeviceCreated) end
      log.info('phone connected: ' .. client.deviceName .. ' (' .. ip .. ', protocol v' .. client.version .. ')')
      deps.notify(deps.i18n.t('beamRemotePlus.toast.phoneConnected',
        { device = client.deviceName, player = (client.player or 0) + 1 }), 'success')
      publish()
    end
  end

  local function sendSession(client)
    if client.version < 2 then return end
    client.sentColor = colorOf(client)
    send(client, protocol.buildSessionMessage({
      modVersion = M.VERSION, player = client.player, commands = commands.names(),
      playerColor = client.sentColor,
      optionalMods = optionalMods.states(),
    }))
  end

  local function handleCommand(client, data)
    local name, arg = protocol.parseCommand(data)
    if not name then return end
    -- The player left: the car brakes, then the phone is disconnected.
    if name == protocol.LEAVE_COMMAND then
      if clients.leave(client.ip, releaseHold) and client.display then
        rememberGone(client)
        log.info('phone left: ' .. client.deviceName .. ' (' .. client.ip .. ')')
        deps.notify(deps.i18n.t('beamRemotePlus.toast.phoneDisconnected', { device = client.deviceName }), 'warning')
        publish()
      else
        log.info('phone leaving, its car stops: ' .. client.deviceName .. ' (' .. client.ip .. ')')
      end
      return
    end
    local ok, err, canonical
    if client.display and not commandsModule.DISPLAY_COMMANDS[name] then
      ok, err, canonical = false, 'display_only', name
    else
      ok, err, canonical = commands.execute(client, name, arg)
    end
    if ok then
      log.debug('command ' .. canonical .. (arg and ('|' .. arg) or '') .. ' from ' .. client.ip)
    else
      log.warn('command ' .. tostring(canonical) .. ' from ' .. client.ip .. ' failed: ' .. tostring(err))
    end
    if canonical == 'debug' and ok then sendSession(client) end
    -- Failures are always reported (v2 apps show them in debug mode);
    -- successes only when the phone asked for debug acks.
    if client.version >= 2 and (not ok or client.debug) then
      send(client, protocol.buildAckMessage(name .. (arg and ('|' .. arg) or ''), ok, err))
    end
  end

  function self.handlePacket(ip, data)
    if protocol.isDiscoverMessage(data) then return handleDiscover(ip, data) end
    if protocol.isPingMessage(data) then return handlePing(ip, data) end
    local client = clients.get(ip)
    if not client then
      log.throttled('unknown:' .. tostring(ip), 5000, 'W', 'packet from unpaired ' .. tostring(ip) .. ' ignored')
      return
    end
    client.lastSeen = deps.clock()
    if protocol.isCmdMessage(data) then return handleCommand(client, data) end
    local steering, throttle, brake = protocol.decodeControlPacket(data)
    if steering == nil then
      log.throttled('size:' .. ip, 5000, 'W', 'unexpected ' .. #data .. '-byte packet from ' .. ip)
      return
    end
    if deps.input and not client.display then clients.applyControl(client, steering, throttle, brake) end
  end

  -- Engine callbacks ----------------------------------------------------------

  function self.onInputBindingsChanged(players)
    for _, client in ipairs(clients.assignPlayers(players)) do
      log.info('phone ' .. client.deviceName .. ' assigned to player ' .. tostring(client.player))
      sendSession(client)
      -- Local multiplayer since 0.40: a new device has no player (-1) until
      -- it joins. A phone joins once, as the next free player, like every
      -- device did before; the player may still take it out of the game.
      if client.player == -1 and not client.joinTried and deps.joinPlayer then
        client.joinTried = true
        pendingJoins[#pendingJoins + 1] = client.ip
      end
    end
    publish()
  end

  -- The local players changed (0.40 personas): a player may have picked
  -- another colour, its phone is told.
  function self.onParticipantsChanged()
    clients.each(function(_, client)
      if colorOf(client) ~= client.sentColor then sendSession(client) end
    end)
    publish()
  end

  -- A mod was enabled, disabled, installed or removed: the panel and every
  -- phone are told when an optional mod changed.
  function self.refreshOptionalMods()
    if not optionalMods.refresh() then return false end
    local enabled = {}
    for _, mod in ipairs(optionalMods.list()) do
      if mod.state == optionalModsModule.ENABLED then enabled[#enabled + 1] = mod.id end
    end
    log.info('optional mods enabled: ' .. (#enabled > 0 and table.concat(enabled, ', ') or 'none'))
    clients.each(function(_, client) sendSession(client) end)
    publish()
    return true
  end

  function self.onTelemetry(vehicleId, t)
    if type(t) == 'table' then motions[vehicleId] = M.motionOf(t) end
    return telemetry.dispatch(clients, vehicleId, t)
  end

  function self.onSkeleton(vehicleId, s)
    return telemetry.dispatchSkeleton(clients, vehicleId, s)
  end

  -- Answer of the vehicle VM to FEATURES_REQUEST: the phones waiting get
  -- the generic commands found, then the vehicle's own ones. Returns the
  -- number of phones answered.
  function self.onVehicleFeatures(vehicleId, ids)
    local pending = pendingActions[vehicleId]
    pendingActions[vehicleId] = nil
    if not pending then return 0 end
    local entries = vehicleActions.genericEntries(ids)
    if pending.model and deps.listVehicleActions then
      for _, entry in ipairs(deps.listVehicleActions(pending.model) or {}) do entries[#entries + 1] = entry end
    end
    local message = protocol.buildActionsMessage(pending.model, entries)
    local sent = 0
    for ip in pairs(pending.ips) do
      local client = clients.get(ip)
      if client then
        send(client, message)
        sent = sent + 1
      end
    end
    return sent
  end

  -- Per-frame work ----------------------------------------------------------

  function self.update()
    if not startListening() then return end

    if lastNativeSync == nil or deps.clock() - lastNativeSync >= NATIVE_SYNC_MS then syncNative() end

    -- Shows the pairing code once: the
    -- game's own QR UI is unreliable since 0.39.
    if not pairingToastShown and deps.config.get('showPairingToast') then
      local code = deps.getSecurityCode()
      if code then
        pairingToastShown = true
        deps.notify(deps.i18n.t('beamRemotePlus.toast.pairingCode', { code = code }), 'info')
        publish()
      end
    end

    local now = deps.clock()
    for _, client in ipairs(clients.expire(now, protocol.CLIENT_TIMEOUT_MS, releaseHold)) do
      log.info('phone timed out: ' .. client.deviceName .. ' (' .. client.ip .. ')')
      rememberGone(client)
      deps.notify(deps.i18n.t('beamRemotePlus.toast.phoneDisconnected', { device = client.deviceName }), 'warning')
      publish()
    end

    local lost, left = clients.watchdog(now, releaseHold)
    for _, client in ipairs(lost) do
      log.warn('no controls from ' .. client.deviceName .. ' (' .. client.ip .. '): its car brakes')
    end
    for _, client in ipairs(left) do
      rememberGone(client)
      log.info('phone left: ' .. client.deviceName .. ' (' .. client.ip .. ')')
      deps.notify(deps.i18n.t('beamRemotePlus.toast.phoneDisconnected', { device = client.deviceName }), 'warning')
      publish()
    end

    -- Joined here, not from inside the game's onInputBindingsChanged hook:
    -- joining assigns the device again, which fires that hook.
    local joins = pendingJoins
    pendingJoins = {}
    for _, ip in ipairs(joins) do
      local client = clients.get(ip)
      if client and client.player == -1 then
        local ok, joined, err = pcall(deps.joinPlayer, client)
        if ok and joined then
          log.info('phone ' .. client.deviceName .. ' joined the local players')
        else
          log.warn('phone ' .. client.deviceName .. ' could not join the local players: ' .. tostring(ok and err or joined))
          deps.notify(deps.i18n.t('beamRemotePlus.toast.noPlayer', { device = client.deviceName }), 'warning')
        end
      end
    end

    for _ = 1, M.MAX_PACKETS_PER_FRAME do
      local data, ip = deps.transport.receive()
      if not data then break end
      -- One bad packet must never prevent handling the rest of the queue.
      local ok, err = pcall(self.handlePacket, ip, data)
      if not ok then log.throttled('packet', 3000, 'W', 'packet from ' .. tostring(ip) .. ' dropped: ' .. tostring(err)) end
    end

    -- Live status of the phones in the panel: signal lost or back, and
    -- disconnected phones dropped from the list after a while.
    for i = #gone, 1, -1 do
      if now - gone[i].at > protocol.DISCONNECTED_SHOWN_MS then table.remove(gone, i) end
    end
    if statuses(now) ~= lastStatuses then publish() end

    telemetry.tick(clients)

    if now - lastHeartbeat > protocol.HEARTBEAT_INTERVAL_MS then
      lastHeartbeat = now
      log.debug('heartbeat: ' .. clients.count() .. ' phone(s) connected')
    end
  end

  -- Point of view captures, just before the game renders its frame (measured
  -- cheaper there than in onUpdate).
  function self.onPreRender()
    if pov then pov.tick(clients) end
  end

  log.debugEnabled = deps.config.get('debug')
  return self
end

return M
