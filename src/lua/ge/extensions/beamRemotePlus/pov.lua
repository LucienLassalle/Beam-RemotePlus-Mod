-- Point of view video: the view of a phone's car, streamed to that phone
-- (BeamNG.drive 0.40 or newer).
--
-- Each phone asking for it gets its own hidden view of the game (a camera
-- context of the game following the car of its player, the way split-screen
-- views do, never shown on the PC screen). It starts on the driver's seat;
-- the camera buttons of the phone then cycle its cameras, not the PC's. Its
-- frames are captured as JPEG and sent to the phone's POV_PORT, cut in
-- datagrams of PART_BYTES at most:
--   "BRPV" | frame number (uint32, big endian) | part | parts | flags | JPEG part
--
-- Cost: a view renders only in the game frame before its capture, and the
-- capture waits for the graphics card to finish that frame, then encodes the
-- JPEG (measured 15-29 ms from 360p to 720p). So every phone due is
-- captured in the same game frame, and a capture always skips a game frame:
-- when the game slows down, so does the video, instead of the video slowing
-- the game down further.
--
-- Pure: the game's render views are behind deps (see main.lua).

local M = {}

M.POV_PORT = 4448
M.MAGIC = 'BRPV'
M.HEADER_BYTES = 11
M.PART_BYTES = 32000
M.FLAG_INSIDE = 1 -- the camera is inside the car (its own dashboard is in view)

-- Asked by the phone (cmd|pov|<quality>, 1 = the default one). Measured on
-- a 60 fps game: low 45 fps, medium 47 fps, high 41 fps.
M.QUALITIES = {
  low = { width = 640, height = 360, intervalMs = 33 },     -- 30 frames per second
  medium = { width = 960, height = 540, intervalMs = 50 },  -- 20 frames per second
  high = { width = 1280, height = 720, intervalMs = 50 },   -- 20 frames per second
}
M.DEFAULT_QUALITY = 'medium'

function M.header(frame, part, parts, flags)
  local n = frame % 4294967296
  return M.MAGIC .. string.char(
    math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256,
    part or 0, parts or 1, flags or 0)
end

--[[
deps:
  createView(id, player, width, height) -> view, or nil, err
  destroyView(view)
  setActive(view, on)              renders the view in the next game frames, or not
  capture(view) -> JPEG bytes or nil (nothing rendered yet), inside (bool)
  cycleCamera(view, offset) -> ok, err
  send(payload, ip, port)
  clock() -> ms
]]
function M.new(deps)
  local self = {}
  local streams = {} -- [ip] = { player, quality, view, frame, nextAt, armed }
  local order = {}   -- ips, in start order
  local nextId = 0

  local function release(stream)
    if stream.view then pcall(deps.destroyView, stream.view) end
    stream.view = nil
    stream.armed = false
  end

  local function open(stream)
    nextId = nextId + 1
    local q = M.QUALITIES[stream.quality]
    local ok, view, err = pcall(deps.createView, 'beamRemotePlusPov' .. nextId, stream.player, q.width, q.height)
    if ok and view then
      stream.view = view
      pcall(deps.setActive, view, false)
      return true
    end
    return false, ok and err or view
  end

  function self.isStreaming(ip) return streams[ip] ~= nil end

  function self.count()
    return #order
  end

  -- Starts the video of a phone (player = its player, 0-based), or changes
  -- its quality (a key of QUALITIES, the default one when nil).
  function self.start(client, quality)
    quality = quality or M.DEFAULT_QUALITY
    if not M.QUALITIES[quality] then return false, 'bad_argument' end
    if client.player == nil or client.player < 0 then return false, 'no_player' end
    local stream = streams[client.ip]
    if stream and stream.quality == quality then return true end
    if stream then self.stop(client.ip) end
    stream = { player = client.player, quality = quality, frame = 0, nextAt = 0, armed = false }
    local ok, err = open(stream)
    if not ok then return false, err end
    streams[client.ip] = stream
    order[#order + 1] = client.ip
    return true
  end

  function self.stop(ip)
    local stream = streams[ip]
    if not stream then return false end
    release(stream)
    streams[ip] = nil
    for i = #order, 1, -1 do
      if order[i] == ip then table.remove(order, i) end
    end
    return true
  end

  function self.stopAll()
    for _, ip in ipairs({ unpack(order) }) do self.stop(ip) end
  end

  -- Next / previous camera of the video of a phone: ok, err, or nil when
  -- the phone has no video.
  function self.cycleCamera(ip, offset)
    local stream = streams[ip]
    if not (stream and stream.view) then return nil end
    return deps.cycleCamera(stream.view, offset)
  end

  local function captureAndSend(ip, stream)
    local ok, jpeg, inside = pcall(deps.capture, stream.view)
    if not ok or type(jpeg) ~= 'string' or jpeg == '' then return false end
    stream.frame = stream.frame + 1
    local parts = math.ceil(#jpeg / M.PART_BYTES)
    if parts > 255 then return false end
    local flags = inside and M.FLAG_INSIDE or 0
    for part = 0, parts - 1 do
      local from = part * M.PART_BYTES + 1
      deps.send(M.header(stream.frame, part, parts, flags) .. jpeg:sub(from, from + M.PART_BYTES - 1), ip, M.POV_PORT)
    end
    return true
  end

  -- Called once per game frame. clients: the registry (clients.lua) —
  -- phones gone or without a player any more lose their video, a phone
  -- given another player gets the view of its new car. Returns the number
  -- of frames sent.
  function self.tick(clients)
    for _, ip in ipairs({ unpack(order) }) do
      local client = clients.get(ip)
      if not client or client.player == nil or client.player < 0 then
        self.stop(ip)
      elseif client.player ~= streams[ip].player then
        local stream = streams[ip]
        release(stream)
        stream.player = client.player
        if not open(stream) then self.stop(ip) end
      end
    end
    -- Views armed in the previous game frame have rendered: capture them.
    local sent, captured = 0, false
    for _, ip in ipairs({ unpack(order) }) do
      local stream = streams[ip]
      if stream and stream.armed then
        captured = true
        stream.armed = false
        pcall(deps.setActive, stream.view, false)
        if captureAndSend(ip, stream) then sent = sent + 1 end
      end
    end
    if captured or #order == 0 then return sent end
    -- Arms the views due, and with them those due within half their interval.
    local now = deps.clock()
    local due = false
    for _, ip in ipairs(order) do
      if now >= streams[ip].nextAt then due = true end
    end
    if not due then return 0 end
    for _, ip in ipairs(order) do
      local stream = streams[ip]
      local interval = M.QUALITIES[stream.quality].intervalMs
      if now >= stream.nextAt - interval / 2 then
        -- Steady pace, without catching up after a stall.
        if now - stream.nextAt > interval then stream.nextAt = now end
        stream.nextAt = stream.nextAt + interval
        stream.armed = true
        pcall(deps.setActive, stream.view, true)
      end
    end
    return 0
  end

  return self
end

return M
