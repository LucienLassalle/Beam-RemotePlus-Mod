-- Top view of the vehicle's real node-and-beam structure, the same data as
-- the game's "Detailed vehicle damage" UI app (beamstate.requestSkeleton /
-- beamstate.deformedBeams): the phone draws the exact shape of any vehicle
-- and colours the beams a crash deformed.
--
-- Pure (no BeamNG globals): telemetry.lua passes v.data, wheels.wheels and
-- beamstate.deformedBeams in. Coordinates are integer centimetres, x to the
-- right and y forward of the vehicle's reference node.

local M = {}

-- Beam ends closer than this (cm) once seen from above are merged: a car
-- has thousands of beams, most of them stacked in the top view.
M.GRID_CM = 2

local function sub(a, b) return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function dot(a, b) return a.x * b.x + a.y * b.y + a.z * b.z end

local function normalize(a)
  local len = math.sqrt(dot(a, a))
  if len < 1e-6 then return nil end
  return { x = a.x / len, y = a.y / len, z = a.z / len }
end

local function cm(v) return math.floor(v * 100 / M.GRID_CM + 0.5) * M.GRID_CM end

-- Ground-plane projection built from the reference nodes (v.data.refNodes:
-- ref, back, left). Returns f(pos) -> x (m, right), y (m, forward), or nil.
function M.frame(refPos, backPos, leftPos)
  if not (refPos and backPos and leftPos) then return nil end
  local fwd = normalize(sub(refPos, backPos))
  if not fwd then return nil end
  local left = sub(leftPos, refPos)
  local along = dot(left, fwd)
  left = normalize({ x = left.x - fwd.x * along, y = left.y - fwd.y * along, z = left.z - fwd.z * along })
  if not left then return nil end
  return function(p)
    local d = sub(p, refPos)
    return -dot(d, left), dot(d, fwd)
  end
end

-- nodes: v.data.nodes (cid -> { pos }); beams: v.data.beams ({ cid, id1,
-- id2, wheelID? }). Tyre and hub beams are left out: the phone draws the
-- wheels itself, with their pressure and brake state.
-- Returns { segments = { x1, y1, x2, y2, ... }, count, segOf = { [beam cid]
-- = segment index (1-based) } }, or nil.
function M.build(nodes, beams, project)
  if not (project and nodes) then return nil end
  local segments, segOf, byKey, count = {}, {}, {}, 0
  local points = {}
  local function point(cid)
    local p = points[cid]
    if p == nil then
      local node = cid ~= nil and nodes[cid]
      p = false
      if node and node.pos then
        local x, y = project(node.pos)
        p = { cm(x), cm(y) }
      end
      points[cid] = p
    end
    return p or nil
  end
  for _, beam in pairs(beams or {}) do
    if type(beam) == 'table' and beam.cid ~= nil and beam.wheelID == nil then
      local a, b = point(beam.id1), point(beam.id2)
      if a and b then
        -- A-B and B-A are the same segment.
        if a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) then a, b = b, a end
        local key = a[1] .. ',' .. a[2] .. ',' .. b[1] .. ',' .. b[2]
        local index = byKey[key]
        if not index then
          count = count + 1
          index = count
          byKey[key] = index
          local base = (count - 1) * 4
          segments[base + 1], segments[base + 2], segments[base + 3], segments[base + 4] = a[1], a[2], b[1], b[2]
        end
        segOf[beam.cid] = index
      end
    end
  end
  if count == 0 then return nil end
  return { segments = segments, count = count, segOf = segOf }
end

-- Short identifier of the geometry: the phone asks for it again when it
-- changes (other vehicle, other configuration).
function M.id(segments)
  local h = 0
  for i = 1, #segments do h = (h * 31 + segments[i]) % 2147483647 end
  return string.format('%d-%x', #segments / 4, h)
end

-- wheelList: wheels.wheels ({ name, node1, node2, radius, tireWidth? }).
-- Returns { FL = { x, y, radius, width } } in cm, or nil.
function M.wheels(wheelList, nodes, project)
  if not (project and nodes) then return nil end
  local result, any = {}, false
  for _, wd in pairs(wheelList or {}) do
    local n1 = type(wd) == 'table' and wd.node1 ~= nil and nodes[wd.node1]
    local n2 = type(wd) == 'table' and wd.node2 ~= nil and nodes[wd.node2]
    if n1 and n2 and wd.name and n1.pos and n2.pos then
      local x1, y1 = project(n1.pos)
      local x2, y2 = project(n2.pos)
      local width = tonumber(wd.tireWidth) or math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
      result[wd.name] = {
        cm((x1 + x2) / 2), cm((y1 + y2) / 2),
        math.floor((tonumber(wd.radius) or 0.3) * 100 + 0.5),
        math.floor(math.max(width, 0.1) * 100 + 0.5),
      }
      any = true
    end
  end
  return any and result or nil
end

-- Same colour scale as the game's app (hue = min(1, ratio * 10)) in 9
-- steps: 0 = intact, 1 = barely bent .. 9 = badly bent or broken.
function M.level(ratio)
  ratio = tonumber(ratio) or 0
  if ratio ~= ratio or ratio <= 0 then return 0 end
  return math.max(1, math.min(9, math.ceil(math.min(1, ratio * 10) * 9)))
end

-- deformed: beamstate.deformedBeams (beam cid -> ratio, 1 = broken).
-- Returns one digit per segment (the worst of its beams), or '' when the
-- whole vehicle is intact.
function M.damage(skeleton, deformed)
  local levels, any = {}, false
  for cid, ratio in pairs(deformed or {}) do
    local index = skeleton.segOf[cid]
    if index then
      local level = M.level(ratio)
      if level > (levels[index] or 0) then
        levels[index] = level
        any = true
      end
    end
  end
  if not any then return '' end
  local digits = {}
  for i = 1, skeleton.count do digits[i] = string.char(48 + (levels[i] or 0)) end
  return table.concat(digits)
end

return M
