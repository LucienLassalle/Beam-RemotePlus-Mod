-- Registry of connected phones. Each phone owns one virtual input device
-- (3 analog axes + 2 buttons), which is what makes local multiplayer work:
-- BeamNG's multiseat assigns every input device to its own player.
--
-- Dependencies are injected (input = core_input_virtualInput, clock = ms,
-- vehicle = what the watchdog needs of the cars) so the whole connection
-- lifecycle is unit-testable.

local protocol = require('/lua/ge/extensions/beamRemotePlus/protocol')

local M = {}

M.DEVICE_NAME = 'BeamRemotePlus'
M.VIDPID = 'bngremoteplusv1' -- must match settings/inputmaps/<vidpid>.json
M.AXES = 3
M.BUTTONS = 2

M.AXIS_STEERING = 0
M.AXIS_THROTTLE = 1
M.AXIS_BRAKE = 2
M.BUTTON_SHIFT_UP = 0
M.BUTTON_SHIFT_DOWN = 1

--[[
vehicle (optional, for the watchdog):
  motion(client) -> { speed = m/s, reverse = bool, arcade = bool } of the car
                    the phone drives, or nil when unknown
  setHandbrake(client, on)  holds or releases the handbrake of that car
]]
function M.new(input, clock, vehicle)
  vehicle = vehicle or {}
  local self = {}
  local clients = {}

  function self.get(ip) return clients[ip] end

  function self.count()
    local n = 0
    for _ in pairs(clients) do n = n + 1 end
    return n
  end

  -- Iterates over a snapshot so callbacks may disconnect clients safely.
  function self.each(fn)
    local snapshot = {}
    for ip, client in pairs(clients) do snapshot[#snapshot + 1] = { ip, client } end
    for _, entry in ipairs(snapshot) do fn(entry[1], entry[2]) end
  end

  -- Returns client, isNew, errorReason.
  function self.connect(ip, ping)
    local client = clients[ip]
    -- Same phone switching between controller and second-screen roles:
    -- start a fresh session with the new role.
    -- Same for a phone pairing again while its car still brakes after it
    -- left.
    if client and ((client.display == true) ~= (ping.role == protocol.ROLE_DISPLAY) or client.leaving) then
      self.disconnect(ip)
      client = nil
    end
    if client then
      client.lastSeen = clock()
      return client, false
    end
    -- A second-screen phone only reads telemetry: no virtual device (it would
    -- compete with the player's real wheel), it follows player 0.
    if ping.role == protocol.ROLE_DISPLAY then
      client = {
        ip = ip, deviceName = ping.deviceName or ip, version = protocol.negotiateVersion(ping.version),
        appVersion = ping.appVersion,
        display = true, state = { 0.5, 0, 0 }, holds = {}, player = 0, debug = false, lastSeen = clock(),
      }
      clients[ip] = client
      return client, true
    end
    if not input then return nil, false, 'virtual_input_unavailable' end
    -- The product name is what Options > Controls displays: with the phone
    -- name, each player recognises their own phone in local multiplayer.
    local productName = ping.deviceName and (M.DEVICE_NAME .. ' (' .. ping.deviceName .. ')') or M.DEVICE_NAME
    local deviceInst = input.createDevice(productName, M.VIDPID, M.AXES, M.BUTTONS, 0)
    if not deviceInst or deviceInst < 0 then return nil, false, 'device_creation_failed' end
    client = {
      ip = ip,
      deviceInst = deviceInst,
      deviceName = ping.deviceName or ip,
      version = protocol.negotiateVersion(ping.version),
      appVersion = ping.appVersion, -- nil for older apps
      state = { 0.5, 0, 0 },
      holds = {},       -- active "hold" commands (horn...) to release on disconnect
      player = nil,     -- assigned by BeamNG (see assignPlayers)
      debug = false,    -- per-client debug acks
      forceEmit = true, -- first control packet always emits every axis
      lastSeen = clock(),
      lastControl = clock(), -- watchdog, see self.watchdog
      stoppingSince = nil, -- ms: the car is being stopped: the phone went silent or left
      handbrakeSet = nil, -- the watchdog pulled the handbrake of the stopped car
      leaving = false,  -- the player left: disconnected once the car stopped
    }
    clients[ip] = client
    return client, true
  end

  function self.touch(ip)
    local client = clients[ip]
    if client then client.lastSeen = clock() end
    return client
  end

  -- onRelease(client, holdName) is called for every still-active hold so a
  -- phone that drops while honking does not leave the horn stuck on.
  function self.disconnect(ip, onRelease)
    local client = clients[ip]
    if not client then return nil end
    for name in pairs(client.holds) do
      if onRelease then pcall(onRelease, client, name) end
    end
    client.holds = {}
    if input and client.deviceInst then pcall(input.deleteDevice, client.deviceInst) end
    clients[ip] = nil
    return client
  end

  function self.disconnectAll(onRelease)
    self.each(function(ip) self.disconnect(ip, onRelease) end)
  end

  -- Returns the list of clients removed because they stopped sending.
  function self.expire(now, timeoutMs, onRelease)
    local expired = {}
    self.each(function(ip, client)
      if protocol.isClientTimedOut(now, client.lastSeen, timeoutMs) then
        expired[#expired + 1] = self.disconnect(ip, onRelease)
      end
    end)
    return expired
  end

  -- players: { ['vinput<N>'] = playerIndex } from onInputBindingsChanged.
  function self.assignPlayers(players)
    local changed = {}
    for device, player in pairs(players or {}) do
      for _, client in pairs(clients) do
        if client.deviceInst and 'vinput' .. client.deviceInst == device and client.player ~= player then
          client.player = player
          changed[#changed + 1] = client
        end
      end
    end
    return changed
  end

  -- Emits only the axes that changed (or all of them when forceEmit is set,
  -- needed after a vehicle switch so BeamNG gives this device priority).
  local function emitAxes(client, values, force)
    for axis = 0, 2 do
      local v = values[axis + 1]
      if force or client.state[axis + 1] ~= v then
        input.emit(client.deviceInst, 'axis', axis, 'change', v)
      end
    end
    client.state = values
  end

  -- A phone that left keeps braking until the watchdog disconnects it;
  -- a phone back after a silence drives again at once (and the handbrake
  -- the watchdog pulled is released).
  function self.applyControl(client, steering, throttle, brake)
    if client.leaving then return end
    local values = { protocol.clampUnit(steering), protocol.clampUnit(throttle), protocol.clampUnit(brake) }
    local force = client.forceEmit or client.stoppingSince ~= nil
    client.forceEmit = false
    if client.handbrakeSet and vehicle.setHandbrake then pcall(vehicle.setHandbrake, client, false) end
    client.stoppingSince = nil
    client.handbrakeSet = nil
    emitAxes(client, values, force)
    client.lastSeen = clock()
    client.lastControl = clock()
  end

  -- Starts stopping the car of a driving phone (see protocol.SIGNAL_LOST_MS).
  local function startStopping(client, now, onRelease)
    client.stoppingSince = now
    client.handbrakeSet = nil
    for name in pairs(client.holds) do
      if onRelease then pcall(onRelease, client, name) end
    end
    client.holds = {}
    emitAxes(client, { 0.5, 0, 0 }, true)
  end

  -- The player left on purpose: the car is stopped the same way, then the
  -- phone is disconnected.
  function self.leave(ip, onRelease)
    local client = clients[ip]
    if not client then return nil end
    if client.display or not client.deviceInst then return self.disconnect(ip, onRelease) end
    client.leaving = true
    if client.stoppingSince == nil then startStopping(client, clock(), onRelease) end
    return client
  end

  -- One frame of stopping a car. Moving: brake for STOP_DURATION_MS with the
  -- pedal that slows it (in arcade mode, reversing swaps the pedals: the
  -- throttle brakes). Stopped: pedals released and the handbrake pulled, so
  -- an arcade gearbox never takes the brake for "reverse". Returns true once
  -- the car is held by the handbrake (or its motion is unknown and the
  -- braking time is over).
  local function stopStep(client, now)
    local motion = vehicle.motion and vehicle.motion(client)
    local braking = now - client.stoppingSince < protocol.STOP_DURATION_MS
    if motion and (tonumber(motion.speed) or 0) <= protocol.STOPPED_SPEED then
      emitAxes(client, { 0.5, 0, 0 }, false)
      if not client.handbrakeSet then
        client.handbrakeSet = true
        if vehicle.setHandbrake then pcall(vehicle.setHandbrake, client, true) end
      end
      return true
    end
    if motion and braking then
      local pedal = motion.reverse and motion.arcade and 2 or 3
      emitAxes(client, { 0.5, pedal == 2 and protocol.STOP_BRAKE or 0, pedal == 3 and protocol.STOP_BRAKE or 0 }, false)
      return false
    end
    emitAxes(client, { 0.5, 0, 0 }, false)
    return motion == nil and not braking
  end

  -- Per-frame safety of the driving phones. Returns the clients whose car
  -- started stopping (signal lost) and those who left and are now gone.
  function self.watchdog(now, onRelease)
    local lost, gone = {}, {}
    self.each(function(ip, client)
      if client.display or not client.deviceInst then return end
      if client.stoppingSince == nil then
        if not protocol.isSignalLost(now, client.lastControl) then return end
        startStopping(client, now, onRelease)
        lost[#lost + 1] = client
      end
      if stopStep(client, now) and client.leaving then gone[#gone + 1] = self.disconnect(ip, onRelease) end
    end)
    return lost, gone
  end

  -- What the in-game panel shows for a phone still registered.
  function self.status(client, now)
    if client.leaving then return protocol.STATUS_DISCONNECTED end
    if client.display then
      return (now - (client.lastSeen or 0)) > protocol.DISPLAY_SIGNAL_LOST_MS and protocol.STATUS_SIGNAL_LOST
        or protocol.STATUS_CONNECTED
    end
    return client.stoppingSince ~= nil and protocol.STATUS_SIGNAL_LOST or protocol.STATUS_CONNECTED
  end

  function self.pulseButton(client, button)
    input.emit(client.deviceInst, 'button', button, 'change', 1)
    input.emit(client.deviceInst, 'button', button, 'change', 0)
  end

  return self
end

return M
