-- Which of the game's generic vehicle commands (4WD, nitrous, two-step...)
-- the vehicle is fitted for, for the phone's "More" sheet. Pure: the game
-- objects are passed as arguments. The ids match
-- lua/ge/extensions/beamRemotePlus/vehicleActions.lua.

local M = {}

local function hasController(getControllersByType, controllerType)
  local list = getControllersByType and getControllersByType(controllerType)
  return type(list) == 'table' and next(list) ~= nil
end

-- A differential the game's "toggle differential mode" action switches.
local function hasToggleableDiff(devices)
  for _, d in pairs(devices or {}) do
    if type(d) == 'table' and d.type == 'differential' and d.defaultToggle
      and type(d.availableModes) == 'table' and #d.availableModes > 1 then
      return true
    end
  end
  return false
end

local function hasDevice(devices, deviceType)
  for _, d in pairs(devices or {}) do
    if type(d) == 'table' and d.type == deviceType then return true end
  end
  return false
end

-- getControllersByType: the vehicle's controller.getControllersByType;
-- devices: powertrain.getDevices(). Returns the ids, in display order.
-- Fog lights and the trailer coupler are always offered, like the game's
-- radial menu does.
function M.collect(getControllersByType, devices)
  local fourWd = hasController(getControllersByType, '4wd')
  local list = { 'fog_lights' }
  if fourWd then list[#list + 1] = 'four_wd' end
  if fourWd and hasDevice(devices, 'rangeBox') then list[#list + 1] = 'range' end
  if fourWd or hasToggleableDiff(devices) then list[#list + 1] = 'diff_lock' end
  if hasController(getControllersByType, 'twoStepLaunch') then list[#list + 1] = 'two_step' end
  if hasController(getControllersByType, 'braking/transbrake') then list[#list + 1] = 'transbrake' end
  if hasController(getControllersByType, 'lineLock') then list[#list + 1] = 'line_lock' end
  if hasController(getControllersByType, 'nitrousOxideInjection') then list[#list + 1] = 'nitrous' end
  if hasController(getControllersByType, 'lightbar') then list[#list + 1] = 'lightbar_mode' end
  list[#list + 1] = 'couplers'
  return list
end

return M
