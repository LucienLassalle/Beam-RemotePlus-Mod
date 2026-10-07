-- Thin wrapper around BeamNG's log() adding a debug level that can be
-- switched at runtime and a throttle for messages that could fire every
-- frame (an error repeated 60 times per second floods the console).

local M = {}

M.TAG = 'beamRemotePlus'

-- sink(level, tag, message): BeamNG's global log(); clock(): milliseconds.
function M.new(sink, clock)
  local self = { debugEnabled = false }
  local lastThrottled = {}

  local function emit(level, message)
    pcall(sink, level, M.TAG, tostring(message))
  end

  function self.info(message) emit('I', message) end
  function self.warn(message) emit('W', message) end
  function self.error(message) emit('E', message) end

  function self.debug(message)
    if self.debugEnabled then emit('D', message) end
  end

  -- Logs at most once per intervalMs for a given key.
  function self.throttled(key, intervalMs, level, message)
    local now = clock()
    if lastThrottled[key] and now - lastThrottled[key] < intervalMs then return false end
    lastThrottled[key] = now
    emit(level, message)
    return true
  end

  return self
end

return M
