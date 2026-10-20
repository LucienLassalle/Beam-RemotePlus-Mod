-- Text commands sent by the app ("cmd|<name>[|<arg>]").
--
-- Commands are data, not an if/elseif chain: adding one is a single table
-- entry. Vehicle commands run the exact same vehicle-Lua code as the game's
-- own input actions (lua/ge/extensions/core/input/actions/vehicle.json), so
-- they behave like the matching keyboard keys.
--
-- Kinds:
--   press: one-shot ("cmd|hazard")
--   hold : "cmd|horn|1" on press, "cmd|horn|0" on release; held commands are
--          released automatically when the phone disconnects.

local vehicleActions = require('/lua/ge/extensions/beamRemotePlus/vehicleActions')
local povModule = require('/lua/ge/extensions/beamRemotePlus/pov')

local M = {}

M.ERR_UNKNOWN = 'unknown_command'
M.ERR_NO_VEHICLE = 'no_vehicle'
M.ERR_BAD_ARGUMENT = 'bad_argument'
M.ERR_UNAVAILABLE = 'unavailable'
M.ERR_NO_VIDEO = 'no_video' -- a camera command of the video while the phone has none

-- Key in client.holds of a "More" command held down (action_down).
M.ACTION_HOLD_PREFIX = 'action:'

M.HOLD_ACTIONS = {
  horn = { on = 'electrics.horn(true)', off = 'electrics.horn(false)' },
  -- Same as the "highbeam" input action: high beams stay on while held (the
  -- game has no automatic flashing, a flash is a short press).
  highbeam = { on = 'electrics.light_flash_highbeams(true)', off = 'electrics.light_flash_highbeams(false)' },
  starter = { on = 'electrics.toggleIgnitionLevelOnDown()', off = 'electrics.toggleIgnitionLevelOnUp()' },
  -- Mirrors the native "Insert" key (recover_vehicle): short hold = small
  -- reposition, long hold = rewind further back in the position history.
  -- Since 0.40 the game tells the recovery which player let go of the key.
  recover = {
    on = "obj:queueGameEngineLua('extensions.hook(\"trackVehReset\", ' .. obj:getId() .. ')') recovery.startRecovering()",
    off = 'recovery.stopRecovering(PLAYER)',
  },
  -- Same as the "parking brake (hold)" input action: the handbrake only
  -- while held, for drifting.
  handbrake = { on = "input.event('parkingbrake', 1, -1)", off = "input.event('parkingbrake', 0, -1)" },
}

M.PRESS_ACTIONS = {
  hazard = 'electrics.toggle_warn_signal()',
  signal_left = 'electrics.toggle_left_signal()',
  signal_right = 'electrics.toggle_right_signal()',
  lights = 'electrics.toggle_lights()',
  parkingbrake = "input.toggleEvent('parkingbrake')",
  esc_mode = "if controller.getController('driveModes') then controller.getController('driveModes').nextDriveMode() else controller.getControllerSafe('esc').toggleESCMode() end",
  shifter_mode = 'controller.mainController.cycleGearboxModes()',
  cruise_set = "extensions.use('cruiseControl').holdCurrentSpeed()",
  cruise_resume = "extensions.use('cruiseControl').setEnabled(true)",
  cruise_off = "extensions.use('cruiseControl').setEnabled(false)",
  cruise_up = "extensions.use('cruiseControl').changeSpeed(1/3.6)",
  cruise_down = "extensions.use('cruiseControl').changeSpeed(-1/3.6)",
  -- Emergency lights and siren share the game's lightbar state (0 off,
  -- 1 lights, 2 lights + siren): the siren never sounds without the lights.
  flashers = 'electrics.set_lightbar_signal((electrics.values.lightbar or 0) > 0 and 0 or 1)',
  siren = 'electrics.set_lightbar_signal((electrics.values.lightbar or 0) == 2 and 1 or 2)',
  -- DRS of vehicle mods, same electrics as their own keys. CF26 (fr04 F3):
  -- drs_toggle opens / closes the wing. FR17: DRS = 1 selects the manual
  -- mode, where DRS_manual opens / closes it; the wing state is DRS_on.
  drs = 'local e = electrics.values '
    .. 'if e.drs_toggle ~= nil then e.drs_toggle = 1 - e.drs_toggle '
    .. 'elseif e.DRS_manual ~= nil then e.DRS = 1 e.DRS_manual = (e.DRS_on or 0) > 0 and 0 or 1 end',
  -- Push-to-Pass of the CF26: a timed power boost, its key toggles p2p_toggle.
  push_to_pass = 'electrics.values.p2p_toggle = 1 - (electrics.values.p2p_toggle or 0)',
  -- Pit limiter of the fr04 (F4 mod and its CF26 F3), same as its key.
  pit_limiter = 'electrics.values.pitLimiter = 1 - (electrics.values.pitLimiter or 0)',
}

-- What a second-screen phone may still ask: they read, never drive (the
-- camera of their own video included).
M.DISPLAY_COMMANDS = {
  debug = true, skeleton = true, pov = true, look = true, look_center = true, freecam = true, fly = true,
}

-- Largest relative turn of one look command (a quick swipe stays far below).
M.MAX_LOOK = 2000

-- Asks the vehicle VM for its skeleton geometry (sent back through
-- extensions.beamRemotePlus_main.onSkeleton).
M.SKELETON_REQUEST = 'local e = extensions.beamRemotePlus_telemetry if e and e.sendSkeleton then e.sendSkeleton() end'

-- Protocol v1 command names kept as aliases of their v2 equivalent.
M.ALIASES = {
  recover_start = { 'recover', '1' },
  recover_stop = { 'recover', '0' },
}

-- Wraps vehicle code so a vehicle lacking a controller (e.g. no cruise
-- control) logs a warning in the vehicle VM instead of raising.
function M.wrapVehicleCode(code)
  return 'local ok, err = pcall(function() ' .. code .. ' end) '
    .. "if not ok and log then log('W', 'beamRemotePlus', 'command failed: ' .. tostring(err)) end"
end

function M.parseHoldArg(arg)
  if arg == '1' or arg == 'on' or arg == 'down' then return true end
  if arg == '0' or arg == 'off' or arg == 'up' then return false end
  return nil
end

--[[
deps:
  getVehicle(player) -> vehicle object (with :queueLuaCommand) or nil
  switchVehicle(player, direction) -> ok, err
  cycleCamera(player, offset) -> ok, err
  pulseButton(client, button)
  buttons = { shiftUp = n, shiftDown = n }
  requestActions(client) -> ok, err      lists the "More" commands (answered later)
  runVehicleAction(client, name, value) -> ok, err   a vehicle's own action
  setPov(client, quality, options) -> ok, err   optional, starts the point of view video
                                         (a quality of pov.lua, true = default; options as
                                         pov.start takes them) or stops it (false)
  cyclePovCamera(client, offset) -> ok, err, or nil when the phone has no video
  lookPov(client, dx, dy), recenterPov(client), setFreePov(client, on), flyPov(client, value)
                                         -> ok, err, or nil when the phone has no video (pov.lua)
]]
function M.new(deps)
  local self = {}

  local function runOnVehicle(client, code)
    local vehicle = deps.getVehicle(client.player or 0)
    if not vehicle then return false, M.ERR_NO_VEHICLE end
    -- PLAYER: the player of the phone, like in the game's input actions.
    code = code:gsub('PLAYER', tostring(client.player or 0))
    vehicle:queueLuaCommand(M.wrapVehicleCode(code))
    return true
  end

  -- With the point of view video on, the camera buttons of the phone change
  -- the camera of its video, not the PC's.
  local function cycleCamera(client, offset)
    if deps.cyclePovCamera then
      local ok, err = deps.cyclePovCamera(client, offset)
      if ok ~= nil then return ok, err end
    end
    return deps.cycleCamera(client.player or 0, offset)
  end

  local special = {
    next_vehicle = function(client)
      local ok, err = deps.switchVehicle(client.player or 0, 1)
      if ok then client.forceEmit = true end
      return ok, err
    end,
    prev_vehicle = function(client)
      local ok, err = deps.switchVehicle(client.player or 0, -1)
      if ok then client.forceEmit = true end
      return ok, err
    end,
    cam_next = function(client) return cycleCamera(client, 1) end,
    cam_prev = function(client) return cycleCamera(client, -1) end,
    gear_up = function(client) deps.pulseButton(client, deps.buttons.shiftUp) return true end,
    gear_down = function(client) deps.pulseButton(client, deps.buttons.shiftDown) return true end,
    skeleton = function(client) return runOnVehicle(client, M.SKELETON_REQUEST) end,
    actions = function(client) return deps.requestActions(client) end,
    debug = function(client, arg)
      local on = M.parseHoldArg(arg)
      if on == nil then return false, M.ERR_BAD_ARGUMENT end
      client.debug = on
      return true
    end,
  }

  -- Point of view video (pov.lua), only offered when the game can do it.
  if deps.setPov then
    -- arg: 0 = off, 1 = on (default quality), or a quality, then after a
    -- quality, optionally: the picture size ("1600x720", the quality's own
    -- one when empty) and the bitrate (a key of pov.BITRATES).
    special.pov = function(client, arg, extras)
      local on = M.parseHoldArg(arg)
      if on == nil and povModule.QUALITIES[arg] then on = arg end
      if on == nil then return false, M.ERR_BAD_ARGUMENT end
      local options = {}
      if type(on) == 'string' then
        local size, bitrate = extras[1], extras[2]
        options.size = size and povModule.parseSize(on, size)
        if size and not options.size then return false, M.ERR_BAD_ARGUMENT end
        if bitrate and not povModule.BITRATES[bitrate] then return false, M.ERR_BAD_ARGUMENT end
        options.bitrate = bitrate
      end
      return deps.setPov(client, on, options)
    end

    -- Camera of the video: nil from pov.lua means the phone has no video.
    local function onVideo(ok, err)
      if ok == nil then return false, M.ERR_NO_VIDEO end
      return ok, err
    end
    local function number(text, limit)
      local value = tonumber(text)
      if value and value == value and math.abs(value) <= limit then return value end
    end

    -- look|<dx>|<dy>: turns the camera, relative like a mouse (x right, y down).
    special.look = function(client, arg, extras)
      local dx, dy = number(arg, M.MAX_LOOK), number(extras[1], M.MAX_LOOK)
      if not (dx and dy) then return false, M.ERR_BAD_ARGUMENT end
      return onVideo(deps.lookPov(client, dx, dy))
    end
    special.look_center = function(client) return onVideo(deps.recenterPov(client)) end
    special.freecam = function(client, arg)
      local on = M.parseHoldArg(arg)
      if on == nil then return false, M.ERR_BAD_ARGUMENT end
      return onVideo(deps.setFreePov(client, on))
    end
    -- fly|<value>: the free camera forward (> 0) or backward (< 0), -1..1.
    special.fly = function(client, arg)
      local value = number(arg, 1)
      if not value then return false, M.ERR_BAD_ARGUMENT end
      return onVideo(deps.flyPov(client, value))
    end
  end

  -- Commands of the "More" sheet (vehicleActions.lua), value 1 = pressed,
  -- 0 = released.
  local function runAction(client, id, value)
    if type(id) ~= 'string' then return false, M.ERR_BAD_ARGUMENT end
    local generic = id:match('^' .. vehicleActions.GENERIC_PREFIX .. '(.+)$')
    if generic then
      local code = vehicleActions.GENERIC[generic]
      if not code then return false, M.ERR_UNKNOWN end
      if value == 0 then return true end
      return runOnVehicle(client, code)
    end
    local name = id:match('^' .. vehicleActions.VEHICLE_PREFIX .. '(.+)$')
    if not name then return false, M.ERR_BAD_ARGUMENT end
    return deps.runVehicleAction(client, name, value)
  end

  special.action = function(client, id)
    local ok, err = runAction(client, id, 1)
    if ok then runAction(client, id, 0) end
    return ok, err
  end
  special.action_down = function(client, id)
    local ok, err = runAction(client, id, 1)
    if ok then client.holds[M.ACTION_HOLD_PREFIX .. id] = true end
    return ok, err
  end
  special.action_up = function(client, id)
    client.holds[M.ACTION_HOLD_PREFIX .. tostring(id)] = nil
    return runAction(client, id, 0)
  end

  -- Returns ok, error, canonicalName. extras: the fields after arg (see
  -- protocol.parseCommand), for the commands taking more than one.
  function self.execute(client, name, arg, extras)
    local alias = M.ALIASES[name]
    if alias then name, arg = alias[1], alias[2] end

    if special[name] then
      local ok, err = special[name](client, arg, extras or {})
      return ok, err, name
    end

    local press = M.PRESS_ACTIONS[name]
    if press then
      local ok, err = runOnVehicle(client, press)
      return ok, err, name
    end

    local hold = M.HOLD_ACTIONS[name]
    if hold then
      local on = M.parseHoldArg(arg)
      if on == nil then return false, M.ERR_BAD_ARGUMENT, name end
      local ok, err = runOnVehicle(client, on and hold.on or hold.off)
      if ok then client.holds[name] = on or nil end
      return ok, err, name
    end

    return false, M.ERR_UNKNOWN, name
  end

  -- Used on disconnect: releases a still-active hold command.
  function self.release(client, name)
    if name:sub(1, #M.ACTION_HOLD_PREFIX) == M.ACTION_HOLD_PREFIX then
      runAction(client, name:sub(#M.ACTION_HOLD_PREFIX + 1), 0)
      return
    end
    local hold = M.HOLD_ACTIONS[name]
    if hold then runOnVehicle(client, hold.off) end
  end

  function self.names()
    local names = {}
    for k in pairs(special) do names[#names + 1] = k end
    for k in pairs(M.PRESS_ACTIONS) do names[#names + 1] = k end
    for k in pairs(M.HOLD_ACTIONS) do names[#names + 1] = k end
    table.sort(names)
    return names
  end

  return self
end

return M
