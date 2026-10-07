local t = require('minitest')
local loggerModule = require('/lua/ge/extensions/beamRemotePlus/logger')

t.describe('logger', function()
  local lines, now = {}, 0
  local logger = loggerModule.new(function(level, tag, msg) lines[#lines + 1] = level .. tag .. msg end, function() return now end)
  t.it('hides debug lines unless enabled', function()
    logger.debug('x')
    t.assertEquals(#lines, 0)
    logger.debugEnabled = true
    logger.debug('x')
    t.assertEquals(lines[1], 'DbeamRemotePlusx')
  end)
  t.it('throttles repeated messages per key', function()
    t.assertTrue(logger.throttled('k', 1000, 'W', 'a'))
    t.assertFalse(logger.throttled('k', 1000, 'W', 'a'))
    now = 1001
    t.assertTrue(logger.throttled('k', 1000, 'W', 'a'))
  end)
  t.it('never propagates a sink error', function()
    loggerModule.new(function() error('sink') end, function() return 0 end).info('x')
  end)
end)
