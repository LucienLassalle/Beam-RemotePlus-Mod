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

local M = {}

M.ERR_UNKNOWN = 'unknown_command'
M.ERR_NO_VEHICLE = 'no_vehicle'
M.ERR_BAD_ARGUMENT = 'bad_argument'
M.ERR_UNAVAILABLE = 'unavailable'

M.HOLD_ACTIONS = {
  horn = { on = 'electrics.horn(true)', off = 'electrics.horn(false)' },
  -- Same as the "highbeam" input action: high beams stay on while held (the
  -- game has no automatic flashing, a flash is a short press).
  highbeam = { on = 'electrics.light_flash_highbeams(true)', off = 'electrics.light_flash_highbeams(false)' },
  starter = { on = 'electrics.toggleIgnitionLevelOnDown()', off = 'electrics.toggleIgnitionLevelOnUp()' },
  -- Mirrors the native "Insert" key: short hold = small reposition, long
  -- hold = rewind further back in the position history.
  recover = { on = 'recovery.startRecovering()', off = 'recovery.stopRecovering()' },
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
}

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
]]
function M.new(deps)
  local self = {}

  local function runOnVehicle(client, code)
    local vehicle = deps.getVehicle(client.player or 0)
    if not vehicle then return false, M.ERR_NO_VEHICLE end
    vehicle:queueLuaCommand(M.wrapVehicleCode(code))
    return true
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
    cam_next = function(client) return deps.cycleCamera(client.player or 0, 1) end,
    cam_prev = function(client) return deps.cycleCamera(client.player or 0, -1) end,
    gear_up = function(client) deps.pulseButton(client, deps.buttons.shiftUp) return true end,
    gear_down = function(client) deps.pulseButton(client, deps.buttons.shiftDown) return true end,
    debug = function(client, arg)
      local on = M.parseHoldArg(arg)
      if on == nil then return false, M.ERR_BAD_ARGUMENT end
      client.debug = on
      return true
    end,
  }

  -- Returns ok, error, canonicalName.
  function self.execute(client, name, arg)
    local alias = M.ALIASES[name]
    if alias then name, arg = alias[1], alias[2] end

    if special[name] then
      local ok, err = special[name](client, arg)
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
