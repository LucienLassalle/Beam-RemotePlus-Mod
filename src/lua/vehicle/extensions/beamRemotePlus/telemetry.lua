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
package.loaded['extensions/beamRemotePlus/drivetrain'] = nil
local damage = require('extensions/beamRemotePlus/damage')
local tyres = require('extensions/beamRemotePlus/tyres')
local drivetrain = require('extensions/beamRemotePlus/drivetrain')

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

local PSI_TO_KPA = 6.894757

-- Pressure each tyre was inflated to in the vehicle configuration (kPa,
-- above the atmosphere), so the phone compares the current pressure to
-- what this car runs instead of a fixed threshold (race cars run low).
-- triangles: v.data.triangles (pressured ones carry pressureGroup and
-- pressurePSI); wheelGroups: { FL = 'pressureGroupName', ... }
function M.nominalPressures(triangles, wheelGroups)
  local psiByGroup = {}
  for _, tri in pairs(triangles or {}) do
    local psi = type(tri) == 'table' and tri.pressureGroup ~= nil and finite(tri.pressurePSI)
    if psi and psi > 0 and psiByGroup[tri.pressureGroup] == nil then psiByGroup[tri.pressureGroup] = psi end
  end
  local result, any = {}, false
  for wheel, group in pairs(wheelGroups or {}) do
    local psi = psiByGroup[group]
    if psi then
      result[wheel] = round(psi * PSI_TO_KPA, 1)
      any = true
    end
  end
  return any and result or nil
end

-- Brake disc surface temperature (°C) per wheel, from the game's brake
-- thermals (electrics.values.wheelThermals).
function M.brakeTemps(wheelThermals)
  if type(wheelThermals) ~= 'table' then return nil end
  local result, any = {}, false
  for name, w in pairs(wheelThermals) do
    local temp = type(w) == 'table' and round(w.brakeSurfaceTemperature, 0)
    if type(name) == 'string' and temp then
      result[name] = temp
      any = true
    end
  end
  return any and result or nil
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
    -- Air brakes of trucks and buses (pneumatics lowAirPressureWarning).
    lowAirPressure = flag(e.lowAirPressure),
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
    tirePressuresNominal = extra.tirePressuresNominal,
    wheelSlip = round(extra.wheelSlip, 2),
    wheelSpin = extra.wheelSpin,
    wheelLock = extra.wheelLock,
    tyres = extra.tyres,
    brakeTemps = M.brakeTemps(e.wheelThermals),
    clutchTemp = extra.clutchTemp,
    clutchState = extra.clutchState,
    brokenParts = extra.brokenParts,
    gearboxWear = extra.gearboxWear,
    drivetrain = extra.drivetrain,
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

local function fuelTankNames()
  local names = {}
  local storages = energyStorage and energyStorage.getStorages and energyStorage.getStorages() or {}
  for name, storage in pairs(storages) do
    if type(storage) == 'table' and storage.type == 'fuelTank' then names[#names + 1] = storage.name or name end
  end
  return names
end

local function readDamage()
  if not (damageTracker and damageTracker.getDamage) then return nil end
  return damage.collect(damageTracker.getDamage, wheelNames(), fuelTankNames())
end

local function powertrainDevices()
  return powertrain and powertrain.getDevices and powertrain.getDevices() or {}
end

local function nodePos(cid)
  local node = v and v.data and v.data.nodes and cid ~= nil and v.data.nodes[cid]
  return node and node.pos or nil
end

-- What does not change while driving (computed once per vehicle VM: a new
-- configuration respawns the vehicle and reloads this extension).
local static = nil
local function readStatic()
  if static then return static end
  local s = {}
  local groups = {}
  for _, wd in pairs(wheels and wheels.wheels or {}) do
    if wd.name and wd.pressureGroup then groups[wd.name] = wd.pressureGroup end
  end
  s.nominal = M.nominalPressures(v and v.data and v.data.triangles, groups)

  local devices = powertrainDevices()
  local engineNode
  for _, d in pairs(devices) do
    if type(d) == 'table' and d.engineNodeID then engineNode = d.engineNodeID break end
  end
  local ref = v and v.data and v.data.refNodes and v.data.refNodes[0]
  local positions = {}
  for _, node in pairs(v and v.data and v.data.nodes or {}) do
    if node.pos then positions[#positions + 1] = node.pos end
  end
  local layout = {
    shafts = drivetrain.shafts(devices),
    engineAt = ref and drivetrain.engineAt(nodePos(engineNode), nodePos(ref.ref), nodePos(ref.back), positions),
  }
  s.drivetrain = next(layout) and layout or nil
  static = s
  return static
end

local function wheelSurfaceSpeeds()
  local speeds = {}
  for _, wd in pairs(wheels and wheels.wheels or {}) do
    if not wd.isBroken and wd.angularVelocity and wd.radius then
      speeds[#speeds + 1] = wd.angularVelocity * wd.radius
    end
  end
  return speeds
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
    local fixed = readStatic()
    local devices = powertrainDevices()
    local clutchTemp, clutchState = drivetrain.clutch(devices)
    local spin, lock = drivetrain.spinLock(wheelSurfaceSpeeds(), electrics.values.airspeed)
    local extra = {
      tirePressuresNominal = fixed.nominal,
      drivetrain = fixed.drivetrain,
      clutchTemp = clutchTemp,
      clutchState = clutchState,
      brokenParts = drivetrain.broken(devices),
      gearboxWear = drivetrain.synchroWear(devices),
      wheelSpin = spin,
      wheelLock = lock,
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
