local t = require('minitest')
local skeleton = require('extensions/beamRemotePlus/skeleton')

local function p(x, y, z) return { x = x, y = y, z = z or 0 } end

-- BeamNG vehicles face -y with their left towards +x.
local project = skeleton.frame(p(0, 0), p(0, 1), p(1, 0))

local nodes = {
  [0] = { pos = p(0.8, -2, 0.3) }, -- front left
  [1] = { pos = p(-0.8, -2, 0.3) }, -- front right
  [2] = { pos = p(0.8, -2, 1.2) }, -- front left, roof (same point from above)
  [3] = { pos = p(0, 2) }, -- rear
  [4] = { pos = p(0.9, -1.5, 0.3) }, -- tyre node
}

local beams = {
  [0] = { cid = 0, id1 = 0, id2 = 1 },
  [1] = { cid = 1, id1 = 2, id2 = 1 }, -- stacked over beam 0
  [2] = { cid = 2, id1 = 1, id2 = 3 },
  [3] = { cid = 3, id1 = 0, id2 = 4, wheelID = 0 },
  [4] = { cid = 4, id1 = 0, id2 = 99 }, -- missing node
}

t.describe('vehicle skeleton', function()
  t.it('projects on the ground plane: x to the right, y forward', function()
    local x, y = project(p(-0.5, -2, 5))
    t.assertCloseTo(x, 0.5)
    t.assertCloseTo(y, 2)
  end)
  t.it('needs the reference nodes', function()
    t.assertNil(skeleton.frame(p(0, 0), nil, p(1, 0)))
    t.assertNil(skeleton.frame(p(0, 0), p(0, 0), p(1, 0)))
  end)
  t.it('merges beams stacked in the top view and leaves the tyres out', function()
    local s = skeleton.build(nodes, beams, project)
    t.assertEquals(s.count, 2)
    t.assertEquals(#s.segments, 8)
    t.assertEquals(s.segOf[0], s.segOf[1])
    t.assertNil(s.segOf[3])
    t.assertNil(s.segOf[4])
    -- Integer centimetres, ends ordered.
    t.assertEquals(table.concat(s.segments, ' ', 1, 4), '-80 200 80 200')
  end)
  t.it('nothing without beams or projection', function()
    t.assertNil(skeleton.build(nodes, {}, project))
    t.assertNil(skeleton.build(nodes, beams, nil))
  end)
  t.it('the id follows the geometry', function()
    local a = skeleton.build(nodes, beams, project)
    t.assertEquals(skeleton.id(a.segments), skeleton.id(skeleton.build(nodes, beams, project).segments))
    nodes[3].pos = p(0, 2.5)
    local b = skeleton.build(nodes, beams, project)
    nodes[3].pos = p(0, 2)
    t.assertTrue(skeleton.id(a.segments) ~= skeleton.id(b.segments))
    t.assertContains(skeleton.id(a.segments), '2-')
  end)
  t.it('wheel centre, radius and width', function()
    local w = skeleton.wheels({
      { name = 'FL', node1 = 0, node2 = 4, radius = 0.31 },
      { name = 'XX', node1 = 0, node2 = 42 },
    }, nodes, project)
    t.assertCloseTo(w.FL[1], -85, 2)
    t.assertCloseTo(w.FL[2], 175, 2)
    t.assertEquals(w.FL[3], 31)
    t.assertEquals(w.FL[4], 51)
    t.assertNil(w.XX)
    t.assertEquals(skeleton.wheels({ { name = 'RR', node1 = 0, node2 = 4, radius = 0.4, tireWidth = 0.245 } }, nodes, project).RR[4], 25)
  end)
end)

t.describe('vehicle skeleton damage', function()
  t.it('levels follow the game colour scale', function()
    t.assertEquals(skeleton.level(0), 0)
    t.assertEquals(skeleton.level(0.001), 1)
    t.assertEquals(skeleton.level(0.05), 5)
    t.assertEquals(skeleton.level(0.1), 9)
    t.assertEquals(skeleton.level(1), 9)
    t.assertEquals(skeleton.level(0 / 0), 0)
  end)
  t.it('one digit per segment, the worst beam wins', function()
    local s = skeleton.build(nodes, beams, project)
    t.assertEquals(skeleton.damage(s, {}), '')
    local damage = skeleton.damage(s, { [0] = 0.01, [1] = 1, [3] = 1 })
    t.assertEquals(#damage, 2)
    t.assertEquals(damage:sub(s.segOf[0], s.segOf[0]), '9')
    t.assertEquals(damage:sub(s.segOf[2], s.segOf[2]), '0')
  end)
end)
