-- Point of view video: the view from the driver's seat of a phone's car,
-- streamed to that phone (BeamNG.drive 0.40 or newer).
--
-- Each phone asking for it gets its own hidden view of the game (a camera
-- context of the game following the car of its player, the way split-screen
-- views do, never shown on the PC screen). Its frames are captured as JPEG
-- and sent as single datagrams to the phone's POV_PORT:
--   "BRPV" | frame number (uint32, big endian) | JPEG
--
-- Cost: the first capture of a game frame waits for the graphics card to
-- finish its work (measured 8-16 ms), the next ones only pay their JPEG
-- encoding (2-5 ms). So every phone is captured in the same game frame, and
-- never two game frames in a row: when the game slows down, so does the
-- video, instead of the video slowing the game down further.
--
-- Pure: the game's render views are behind deps (see main.lua).

local M = {}

M.POV_PORT = 4448
M.MAGIC = 'BRPV'
M.FRAME_INTERVAL_MS = 33 -- 30 frames per second at most
M.FRAME_GAP = 2 -- game frames between two captures, at least
-- A frame must fit one UDP datagram: past this size the next smaller
-- resolution is used.
M.MAX_FRAME_BYTES = 60000
M.RESOLUTIONS = { { 640, 360 }, { 512, 288 }, { 426, 240 } }

function M.header(frame)
  local n = frame % 4294967296
  return M.MAGIC .. string.char(
    math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

--[[
deps:
  createView(id, player, width, height) -> view, or nil, err
  destroyView(view)
  capture(view) -> JPEG bytes or nil (nothing rendered yet)
  send(payload, ip, port)
  clock() -> ms
]]
function M.new(deps)
  local self = {}
  local streams = {} -- [ip] = { player, view, resolution, frame }
  local order = {}   -- ips, in start order
  local nextId = 0
  local gameFrame = 0
  local lastCapture = -M.FRAME_GAP
  local nextAt = 0

  local function release(stream)
    if stream.view then pcall(deps.destroyView, stream.view) end
    stream.view = nil
  end

  local function open(stream)
    nextId = nextId + 1
    local size = M.RESOLUTIONS[stream.resolution]
    local ok, view, err = pcall(deps.createView, 'beamRemotePlusPov' .. nextId, stream.player, size[1], size[2])
    if ok and view then
      stream.view = view
      return true
    end
    return false, ok and err or view
  end

  function self.isStreaming(ip) return streams[ip] ~= nil end

  function self.count()
    return #order
  end

  -- Starts the video of a phone (player = its player, 0-based).
  function self.start(client)
    if client.player == nil or client.player < 0 then return false, 'no_player' end
    if streams[client.ip] then return true end
    local stream = { player = client.player, resolution = 1, frame = 0 }
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

  local function captureAndSend(ip, stream)
    local ok, jpeg = pcall(deps.capture, stream.view)
    if not ok or type(jpeg) ~= 'string' or jpeg == '' then return false end
    if #jpeg > M.MAX_FRAME_BYTES then
      if stream.resolution < #M.RESOLUTIONS then
        release(stream)
        stream.resolution = stream.resolution + 1
        if not open(stream) then self.stop(ip) end
      end
      return false
    end
    stream.frame = stream.frame + 1
    deps.send(M.header(stream.frame) .. jpeg, ip, M.POV_PORT)
    return true
  end

  -- Called once per game frame. clients: the registry (clients.lua) —
  -- phones gone or without a player any more lose their video, a phone
  -- given another player gets the view of its new car. Returns the number
  -- of frames sent.
  function self.tick(clients)
    gameFrame = gameFrame + 1
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
    if #order == 0 or gameFrame - lastCapture < M.FRAME_GAP then return 0 end
    local now = deps.clock()
    if now < nextAt then return 0 end
    lastCapture = gameFrame
    -- Steady pace, without catching up after a stall.
    if now - nextAt > M.FRAME_INTERVAL_MS then nextAt = now end
    nextAt = nextAt + M.FRAME_INTERVAL_MS
    local sent = 0
    for _, ip in ipairs({ unpack(order) }) do
      local stream = streams[ip]
      if stream and captureAndSend(ip, stream) then sent = sent + 1 end
    end
    return sent
  end

  return self
end

return M
