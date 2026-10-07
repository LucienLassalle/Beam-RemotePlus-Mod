-- Non-blocking UDP transport built on BeamNG's LuaSocket (global `socket`).

local protocol = require('/lua/ge/extensions/beamRemotePlus/protocol')

local M = {}

-- socketLib: LuaSocket module (injected for tests).
function M.new(socketLib)
  local self = {}
  local udp = nil

  function self.open(port)
    if udp then return true end
    local ok, sock = pcall(socketLib.udp)
    if not ok or not sock then return false, 'socket.udp() failed: ' .. tostring(sock) end
    local bound, err = sock:setsockname('*', port)
    if not bound then
      pcall(sock.close, sock)
      return false, err or 'port already in use'
    end
    sock:settimeout(0)
    udp = sock
    return true
  end

  function self.close()
    if udp then pcall(udp.close, udp) end
    udp = nil
  end

  function self.receive()
    if not udp then return nil end
    return udp:receivefrom(protocol.MAX_DATAGRAM_SIZE)
  end

  function self.send(payload, ip, port)
    if udp then udp:sendto(payload, ip, port) end
  end

  function self.isOpen() return udp ~= nil end

  return self
end

return M
