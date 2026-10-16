-- Core of the mod: routes incoming datagrams, owns the lock on new phones
-- and the per-frame work. Every BeamNG API is injected by main.lua,
-- which keeps this file fully unit-testable (see test/server_test.lua).

local protocol = require('/lua/ge/extensions/beamRemotePlus/protocol')
local clientsModule = require('/lua/ge/extensions/beamRemotePlus/clients')
local commandsModule = require('/lua/ge/extensions/beamRemotePlus/commands')
local telemetryModule = require('/lua/ge/extensions/beamRemotePlus/telemetry')
local optionalModsModule = require('/lua/ge/extensions/beamRemotePlus/optionalMods')

local M = {}

-- 'dev' in the sources: scripts/build_mod.sh stamps the release version.
M.VERSION = 'dev'
M.MAX_PACKETS_PER_FRAME = 256

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
  getVehicle(player)          -> vehicle or nil
  listVehicles()              -> radar descriptions of every car (optional)
  switchVehicle(player, dir)  -> ok, err
  cycleCamera(player, offset) -> ok, err
  onDeviceCreated()           optional, forces an input device rescan
  getMods()                   optional, core_modmanager.getMods()
  fileExists(path)            optional, file in the game's virtual file system
  nativeRemote                optional nativeRemote.new(...) instance: the
                              game's own remote control (UDP 4444)
]]
function M.new(deps)
  local self = {}
  local log = deps.logger
  local clients = clientsModule.new(deps.input, deps.clock)
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

  local function send(client, payload)
    deps.transport.send(payload, client.ip, protocol.CLIENT_PORT)
  end

  local commands = commandsModule.new({
    getVehicle = deps.getVehicle,
    switchVehicle = deps.switchVehicle,
    cycleCamera = deps.cycleCamera,
    pulseButton = function(client, button) clients.pulseButton(client, button) end,
    buttons = { shiftUp = clientsModule.BUTTON_SHIFT_UP, shiftDown = clientsModule.BUTTON_SHIFT_DOWN },
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

  function self.state()
    local phones = {}
    clients.each(function(ip, client)
      phones[#phones + 1] = { ip = ip, device = client.deviceName, player = client.player, protocol = client.version, display = client.display }
    end)
    return {
      version = M.VERSION,
      listening = listening,
      locked = locked,
      debug = deps.config.get('debug'),
      code = listening and deps.getSecurityCode() or nil,
      port = protocol.HOST_PORT,
      phones = phones,
      optionalMods = optionalMods.list(),
    }
  end

  local function publish() pcall(deps.publishState, self.state()) end

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
    log.info('phone kicked: ' .. client.deviceName .. ' (' .. ip .. ')')
    deps.notify(deps.i18n.t('beamRemotePlus.toast.phoneKicked', { device = client.deviceName }), 'warning')
    publish()
    return true
  end

  function self.shutdown() stopListening() end

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
    send(client, protocol.buildSessionMessage({
      modVersion = M.VERSION, player = client.player, commands = commands.names(),
      optionalMods = optionalMods.states(),
    }))
  end

  local function handleCommand(client, data)
    local name, arg = protocol.parseCommand(data)
    if not name then return end
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
    end
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
    return telemetry.dispatch(clients, vehicleId, t)
  end

  function self.onSkeleton(vehicleId, s)
    return telemetry.dispatchSkeleton(clients, vehicleId, s)
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
      deps.notify(deps.i18n.t('beamRemotePlus.toast.phoneDisconnected', { device = client.deviceName }), 'warning')
      publish()
    end

    for _ = 1, M.MAX_PACKETS_PER_FRAME do
      local data, ip = deps.transport.receive()
      if not data then break end
      -- One bad packet must never prevent handling the rest of the queue.
      local ok, err = pcall(self.handlePacket, ip, data)
      if not ok then log.throttled('packet', 3000, 'W', 'packet from ' .. tostring(ip) .. ' dropped: ' .. tostring(err)) end
    end

    telemetry.tick(clients)

    if now - lastHeartbeat > protocol.HEARTBEAT_INTERVAL_MS then
      lastHeartbeat = now
      log.debug('heartbeat: ' .. clients.count() .. ' phone(s) connected')
    end
  end

  log.debugEnabled = deps.config.get('debug')
  return self
end

return M
