local t = require('minitest')
local radar = require('/lua/ge/extensions/beamRemotePlus/radar')

local me = { id = 1, x = 100, y = 100, fx = 0, fy = 1, length = 4.5, width = 1.9 } -- facing +y

t.describe('radar', function()
  t.it('converts to the vehicle frame (x right, y ahead)', function()
    local x, y = radar.toLocal(3, 10, 0, 1)
    t.assertCloseTo(x, 3)
    t.assertCloseTo(y, 10)
    x, y = radar.toLocal(0, 10, 1, 0) -- facing +x, target at +y is on the left
    t.assertCloseTo(x, -10)
    t.assertCloseTo(y, 0)
  end)
  t.it('relative heading', function()
    t.assertCloseTo(radar.relativeHeading(0, 1, 0, 1), 0)
    t.assertCloseTo(radar.relativeHeading(0, 1, 1, 0), 90)
    t.assertCloseTo(math.abs(radar.relativeHeading(0, 1, 0, -1)), 180)
  end)
  t.it('keeps the nearest cars in range, closest first, without myself', function()
    local targets = radar.compute(me, {
      me,
      { id = 2, x = 100, y = 130, fx = 0, fy = -1 },
      { id = 3, x = 105, y = 100, fx = 0, fy = 1, length = 12, width = 2.5 },
      { id = 4, x = 400, y = 400, fx = 0, fy = 1 },
    })
    t.assertEquals(#targets, 2)
    t.assertEquals(targets[1].x, 5)
    t.assertEquals(targets[1].length, 12)
    t.assertEquals(targets[2].y, 30)
    t.assertEquals(math.abs(targets[2].heading), 180)
    t.assertNil(targets[1].d)
  end)
  t.it('caps the number of targets', function()
    local others = {}
    for i = 1, 30 do others[i] = { id = i + 10, x = 100 + i, y = 100, fx = 0, fy = 1 } end
    t.assertEquals(#radar.compute(me, others, 50, 5), 5)
  end)
end)
