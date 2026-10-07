-- Vehicle-side telemetry collector (runs in the vehicle Lua VM, where
-- electrics/sensors/wheels live). Loaded on demand by the GE extension with
-- extensions.load('beamRemotePlus_telemetry').
--
-- collect() is pure (inputs passed as arguments) and unit-tested; send()
-- only gathers the game state and forwards the table to the GE side.
--
-- A field the vehicle does not provide is OMITTED rather than sent as 0, so
-- the app can tell "value is 0" from "this car has no such sensor" (shown by
-- the app's debug overlay).

-- Fresh copies of the helper modules when this extension is reloaded.
package.loaded['extensions/beamRemotePlus/damage'] = nil
package.loaded['extensions/beamRemotePlus/tyres'] = nil
local damage = require('extensions/beamRemotePlus/damage')
local tyres = require('extensions/beamRemotePlus/tyres')

local M = {}

local function finite(v)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
  return v
end

-- BeamNG electrics mix booleans and 0/1 numbers for the same concept.
local function flag(v)
  if v == nil then return nil end
  if type(v) == 'boolean' then return v end
  local n = tonumber(v)
  if n == nil then return nil end
  return n ~= 0
end

-- nil when absent, otherwise whether the value is strictly positive (the
-- parking brake is an analog 0..1 value).
local function positive(v)
  if v == nil then return nil end
  return (finite(v) or 0) > 0
end

-- true if any flag is true, false if all known flags are false, nil if none
-- is known.
local function anyFlag(...)
  local result = nil
  for i = 1, select('#', ...) do
    local f = flag((select(i, ...)))
    if f then return true end
    if f == false then result = false end
  end
  return result
end

local function round(v, decimals)
  v = finite(v)
  if v == nil then return nil end
  local m = 10 ^ (decimals or 0)
  return math.floor(v * m + 0.5) / m
end

-- Manual gearboxes report the gear as a number (-1, 0, 1...), automatic
-- ones as the label shown by the car ('P', 'D', 'S5'...).
function M.gearLabel(gear)
  if type(gear) == 'number' then
    if gear < 0 then return 'R' end
    if gear == 0 then return 'N' end
    return tostring(math.floor(gear))
  end
  if gear == nil or gear == '' then return nil end
  return tostring(gear)
end

-- e: electrics.values ; extra: { gx, gy, gz, tirePressures, driveMode, envTemp }
function M.collect(e, extra)
  extra = extra or {}
  local t = {
    speed = round(e.wheelspeed, 2),
    airspeed = round(e.airspeed, 2),
    rpm = round(e.rpm, 0),
    maxRpm = round(e.maxrpm, 0),
    idleRpm = round(e.idlerpm, 0),
    gear = M.gearLabel(e.gear),
    gearIndex = finite(e.gearIndex),
    maxGearIndex = finite(e.maxGearIndex),
    gearboxMode = type(e.gearboxMode) == 'string' and e.gearboxMode or nil,
    fuel = round(e.fuel, 4),
    fuelVolume = round(e.fuelVolume, 2),
    fuelCapacity = round(e.fuelCapacity, 2),
    waterTemp = round(e.watertemp, 1),
    oilTemp = round(e.oiltemp, 1),
    boost = round(e.turboBoost, 2),
    engineRunning = flag(e.engineRunning),
    ignitionLevel = finite(e.ignitionLevel),
    engineLoad = round(e.engineLoad, 3),
    throttle = round(e.throttle, 3),
    brake = round(e.brake, 3),
    clutch = round(e.clutch, 3),
    parkingBrake = positive(e.parkingbrake),
    lowBeam = flag(e.lowbeam),
    highBeam = flag(e.highbeam),
    signalLeft = flag(e.signal_L),
    signalRight = flag(e.signal_R),
    hazard = flag(e.hazard_enabled),
    lowPressure = anyFlag(e.lowpressure, e.oil),
    checkEngine = flag(e.checkengine),
    lowFuel = flag(e.lowfuel),
    hasAbs = flag(e.hasABS),
    absActive = flag(e.absActive),
    hasEsc = e.esc ~= nil or nil,
    escActive = flag(e.escActive),
    hasTcs = anyFlag(e.hasTCS, e.tcs ~= nil or nil),
    tcsActive = flag(e.tcsActive),
    cruiseActive = flag(e.cruiseControlActive),
    cruiseSpeed = round(e.cruiseControlTarget, 2),
    odometer = round(e.odometer, 0),
    trip = round(e.trip, 0),
    gx = round(extra.gx, 3),
    gy = round(extra.gy, 3),
    gz = round(extra.gz, 3),
    envTemp = round(extra.envTemp, 1),
    driveMode = extra.driveMode,
    tirePressures = extra.tirePressures,
    wheelSlip = round(extra.wheelSlip, 2),
    tyres = extra.tyres,
  }
  for k, v in pairs(extra.damage or {}) do t[k] = v end

  -- Shift light: prefer the vehicle's own shiftLights controller, otherwise
  -- the same rule as the game's dynamic redline gauges (95% of max RPM,
  -- never on the top gear).
  if e.shouldShift ~= nil then
    t.shiftLight = flag(e.shouldShift)
  elseif t.rpm and t.maxRpm and t.maxRpm > 0 then
    local topGear = t.gearIndex and t.maxGearIndex and t.gearIndex >= t.maxGearIndex
    t.shiftLight = t.rpm >= t.maxRpm * 0.95 and not topGear
  end

  return t
end

-- Tire pressures in kPa keyed by wheel name (FL, FR, RL, RR...), same
-- computation as the game's tireData gauge module.
local function readTirePressures()
  if not (wheels and wheels.wheels and v and v.data and v.data.pressureGroups) then return nil end
  local pressures, any = {}, false
  for _, wd in pairs(wheels.wheels) do
    local group = wd.pressureGroup and v.data.pressureGroups[wd.pressureGroup]
    if group and wd.name then
      pressures[wd.name] = round(math.max(obj:getGroupPressure(group) - obj:getEnvPressure(), 0) * 0.001, 1)
      any = true
    end
  end
  return any and pressures or nil
end

local function wheelNames()
  local names = {}
  for _, wd in pairs(wheels and wheels.wheels or {}) do
    if wd.name then names[#names + 1] = wd.name end
  end
  return names
end

-- Largest slip velocity among the wheels (m/s): drives the phone's
-- haptic feedback (wheelspin, locked wheels, drifting).
local function maxWheelSlip()
  local maxSlip
  for _, wd in pairs(wheels and wheels.wheels or {}) do
    local slip = tonumber(wd.lastSlip)
    if slip and slip == slip then maxSlip = math.max(maxSlip or 0, math.abs(slip)) end
  end
  return maxSlip
end

local function readDamage()
  if not (damageTracker and damageTracker.getDamage) then return nil end
  return damage.collect(damageTracker.getDamage, wheelNames())
end

local function readDriveMode()
  local driveModes = controller and controller.getController and controller.getController('driveModes')
  if not driveModes then return nil end
  local key = driveModes.getCurrentDriveModeKey and driveModes.getCurrentDriveModeKey()
  local data = key and driveModes.getDriveModeData and driveModes.getDriveModeData(key)
  if not data then return nil end
  return { key = tostring(key), name = data.name and tostring(data.name) or tostring(key) }
end

function M.onExtensionLoaded()
  if gui then tyres.install(gui) end
end

function M.send()
  if gui then tyres.install(gui) end
  local ok, err = pcall(function()
    if not (electrics and electrics.values) then return end
    local extra = {
      gx = sensors and sensors.gx2,
      gy = sensors and sensors.gy2,
      gz = sensors and sensors.gz2,
      envTemp = obj.getEnvTemperature and (obj:getEnvTemperature() - 273.15) or nil,
      tirePressures = readTirePressures(),
      wheelSlip = maxWheelSlip(),
      damage = readDamage(),
      tyres = tyres.read(),
      driveMode = readDriveMode(),
    }
    local t = M.collect(electrics.values, extra)
    obj:queueGameEngineLua(string.format(
      'if extensions.beamRemotePlus_main then extensions.beamRemotePlus_main.onTelemetry(%d, %s) end',
      obj:getID(), serialize(t)))
  end)
  if not ok and log then
    log('W', 'beamRemotePlus', 'telemetry collection failed: ' .. tostring(err))
  end
end

return M
