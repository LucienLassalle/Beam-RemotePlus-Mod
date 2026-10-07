-- Proximity radar: vehicles around the one a phone follows, in that
-- vehicle's frame (x = metres to the right, y = metres ahead, heading in
-- degrees relative to ours, 0 = same direction). Pure math + an injected
-- vehicle lister, so it is unit-tested without the game.

local M = {}

M.RANGE_M = 50
M.MAX_TARGETS = 12
M.MIN_LENGTH_M = 2 -- smaller objects are props, not vehicles

-- Rotates the world offset (dx, dy) into the frame whose forward unit
-- vector is (fx, fy). Right = forward rotated -90°.
function M.toLocal(dx, dy, fx, fy)
  return dx * fy - dy * fx, dx * fx + dy * fy
end

-- Relative heading in degrees (-180..180) between two forward vectors.
function M.relativeHeading(fx, fy, ox, oy)
  local a = math.deg(math.atan2(ox, oy) - math.atan2(fx, fy))
  a = (a + 180) % 360 - 180
  return a
end

local function round1(v) return math.floor(v * 10 + 0.5) / 10 end

-- me / others: { id, x, y, fx, fy, length, width } (world space, z ignored).
-- Returns the nearest targets in range, closest first.
function M.compute(me, others, range, maxTargets)
  range = range or M.RANGE_M
  local targets = {}
  for _, o in ipairs(others) do
    if o.id ~= me.id then
      local x, y = M.toLocal(o.x - me.x, o.y - me.y, me.fx, me.fy)
      local distance = math.sqrt(x * x + y * y)
      if distance <= range then
        targets[#targets + 1] = {
          x = round1(x), y = round1(y), d = distance,
          heading = math.floor(M.relativeHeading(me.fx, me.fy, o.fx, o.fy) + 0.5),
          length = round1(o.length or 4.5), width = round1(o.width or 1.9),
        }
      end
    end
  end
  table.sort(targets, function(a, b) return a.d < b.d end)
  for i = #targets, (maxTargets or M.MAX_TARGETS) + 1, -1 do targets[i] = nil end
  for _, t in ipairs(targets) do t.d = nil end
  return setmetatable(targets, { __jsonArray = true }) -- "[]" when empty
end

-- Game adapter: describes a BeamNG vehicle object (nil on failure).
function M.describe(veh)
  local ok, d = pcall(function()
    local pos = veh:getPosition()
    local dir = veh:getDirectionVector()
    local norm = math.sqrt(dir.x * dir.x + dir.y * dir.y)
    if norm < 1e-6 then return nil end
    local length, width = 4.5, 1.9
    local bb = veh.getSpawnWorldOOBB and veh:getSpawnWorldOOBB()
    if bb then
      local h = bb:getHalfExtents()
      length = 2 * math.max(h.x, h.y)
      width = 2 * math.min(h.x, h.y)
    end
    return { id = veh:getID(), x = pos.x, y = pos.y, fx = dir.x / norm, fy = dir.y / norm, length = length, width = width }
  end)
  if not ok or not d or d.length < M.MIN_LENGTH_M then return nil end
  return d
end

return M
