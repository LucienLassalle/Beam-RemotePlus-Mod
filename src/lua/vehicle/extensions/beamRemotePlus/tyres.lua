-- Optional integration with the "Tyre Thermals and Wear" mod (Luuk's
-- tyre-thermals-and-wear). That mod only publishes its data to its own UI
-- app with gui.send('TyreWearThermals', stream); we listen to the same
-- message inside the vehicle VM (read-only, its behaviour is unchanged).
-- Without that mod, nothing is installed and no tyre temperature is sent.

local M = {}

M.EVENT = 'TyreWearThermals'
M.MAX_AGE_S = 2

local latest = nil
local latestAt = 0

local function round1(v)
  v = tonumber(v)
  if v == nil or v ~= v then return nil end
  return math.floor(v * 10 + 0.5) / 10
end

-- stream: { data = { { name, temp = {s1, s2, s3, core}, avg_temp,
-- condition, working_temp, brake_temp }, ... } }
-- Returns { FL = { temp, surface = {...}, core, wear, working, brake } }
function M.normalize(stream)
  if type(stream) ~= 'table' or type(stream.data) ~= 'table' then return nil end
  local tyres, any = {}, false
  for _, w in ipairs(stream.data) do
    if type(w) == 'table' and type(w.name) == 'string' then
      -- Per-ring temperatures (3 surface rings + core) are not sent by
      -- every version of the tyre mod: only included when present.
      local rings = type(w.temp) == 'table' and #w.temp >= 4 and w.temp or nil
      tyres[w.name] = {
        temp = round1(w.avg_temp),
        surface = rings and { round1(rings[1]), round1(rings[2]), round1(rings[3]) } or nil,
        core = rings and round1(rings[4]) or nil,
        condition = round1(w.condition), -- % left, 100 = new
        working = round1(w.working_temp),
        brake = round1(w.brake_temp),
      }
      any = true
    end
  end
  return any and tyres or nil
end

local function receive(data)
  latest = data
  latestAt = os.clock()
end

-- Wraps gui.send once per vehicle VM; the wrapper forwards to a sink that
-- every (re)loaded copy of this module re-registers, so a reload never
-- leaves the data flowing into a stale module. Returns true when the
-- wrapper was installed by this call.
function M.install(gui)
  if type(gui) ~= 'table' or type(gui.send) ~= 'function' then return false end
  gui.__beamRemotePlusTyresSink = receive
  if gui.__beamRemotePlusTyres then return false end
  local original = gui.send
  gui.send = function(name, data, ...)
    if name == M.EVENT and gui.__beamRemotePlusTyresSink then gui.__beamRemotePlusTyresSink(data) end
    return original(name, data, ...)
  end
  gui.__beamRemotePlusTyres = true
  return true
end

function M.read(now)
  if latest == nil or (now or os.clock()) - latestAt > M.MAX_AGE_S then return nil end
  return M.normalize(latest)
end

-- Test helper.
function M._set(stream, at)
  latest, latestAt = stream, at or os.clock()
end

return M
