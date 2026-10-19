-- Point of view video: the view of a phone's car, streamed to that phone
-- (BeamNG.drive 0.40 or newer).
--
-- Each phone asking for it gets its own hidden view of the game (a camera
-- context of the game following the car of its player, the way split-screen
-- views do, never shown on the PC screen). It starts on the driver's seat;
-- the camera buttons of the phone then cycle its cameras, not the PC's.
--
-- The game encodes that view itself with the video encoder of the graphics
-- card (H.264, libbngvs: NVENC, AMF, QuickSync or Vulkan video) straight
-- from the GPU, and sends it as MPEG-TS over UDP to the phone's POV_PORT.
-- Without a usable encoder there is no video: the phone is told why
-- (state 'error'), there is no fallback.
--
-- The phone is kept informed by "pov" messages (see protocol.lua): the
-- state of its video and whether the camera is a seat camera.
--
-- Pure: the game's render views and encoder are behind deps (see main.lua).

local M = {}

M.POV_PORT = 4448
M.CHECK_INTERVAL_MS = 250
-- An output reads as failed until the game has set its encoder up (the
-- next frames): only a failure lasting this long counts.
M.START_GRACE_MS = 1000

-- Asked by the phone (cmd|pov|<quality>, 1 = the default one).
M.QUALITIES = {
  ['720p60'] = { width = 1280, height = 720, fps = 60, bitrate = 8000000 },
  ['1080p30'] = { width = 1920, height = 1080, fps = 30, bitrate = 10000000 },
  ['1080p60'] = { width = 1920, height = 1080, fps = 60, bitrate = 16000000 },
}
M.DEFAULT_QUALITY = '720p60'

-- Video states sent to the phone.
M.STARTING = 'starting'
M.LIVE = 'live'
M.ERROR = 'error'

-- Why there is no video (error of the 'error' state).
M.ERR_ENCODER = 'encoder' -- the graphics card's video encoder did not start

-- Encoder options (FFmpeg names). async_depth=2: the game hands a frame to
-- the encoder and goes on, its packet comes out on the next frame. The
-- library's default (1) makes every game frame wait for its encode: 60 fps
-- fell to 27 with a 720p video (Vulkan video, Radeon RX 6800 XT); with 2 it
-- stays at 60, even at 1080p 60. A keyframe each second limits the damage
-- of a lost packet.
function M.encoderOptions(quality)
  return 'async_depth=2,g=' .. M.QUALITIES[quality].fps
end

function M.url(ip)
  return 'udp://' .. ip .. ':' .. M.POV_PORT .. '?pkt_size=1316'
end

-- The game cycles the cameras of a hidden view without the seat cameras
-- (they belong to the player seated in the car, not to the view's own input
-- player): puts the driver's seat back in the cycle. order: the camera names
-- in the game's order, current / nextName: the camera before and after the
-- game's cycle, seat: the driver's seat camera. Returns the camera to show.
function M.cycleWithSeat(order, current, nextName, seat, offset)
  local index = {}
  for i, name in ipairs(order) do index[name] = i end
  local n, c, x, s = #order, index[current], index[nextName], index[seat]
  if not (c and s) or current == seat then return nextName end
  local function dist(from, to)
    local d = offset > 0 and to - from or from - to
    return d % n
  end
  local toSeat, toNext = dist(c, s), x and dist(c, x) or 0
  if toNext == 0 or toSeat < toNext then return seat end
  return nextName
end

--[[
deps:
  createView(id, player, width, height) -> view, or nil, err
  destroyView(view)
  startOutput(view, url, quality) -> output, or nil, err   encodes the view to url
  stopOutput(output)
  outputStatus(output) -> 1 starting, 0 live, < 0 failed
  update(view) -> inside           keeps the camera of the view; true for a seat camera
  cycleCamera(view, offset) -> ok, err
  notify(ip, info)                 info = { state, error, inside, quality }
  clock() -> ms
]]
function M.new(deps)
  local self = {}
  local streams = {} -- [ip] = { player, quality, view, output, state, error, inside }
  local order = {}   -- ips, in start order
  local nextId = 0
  local nextCheck = 0

  local function tell(ip, stream)
    deps.notify(ip, { state = stream.state, error = stream.error, inside = stream.inside, quality = stream.quality })
  end

  local function release(stream)
    if stream.output then pcall(deps.stopOutput, stream.output) end
    if stream.view then pcall(deps.destroyView, stream.view) end
    stream.output, stream.view = nil, nil
  end

  -- View + encoder for the stream's player and quality: ok, err, detail.
  local function open(ip, stream)
    nextId = nextId + 1
    local q = M.QUALITIES[stream.quality]
    local ok, view, err = pcall(deps.createView, 'beamRemotePlusPov' .. nextId, stream.player, q.width, q.height)
    if not (ok and view) then return false, ok and err or view end
    stream.view = view
    local output
    ok, output, err = pcall(deps.startOutput, view, M.url(ip), stream.quality)
    if not (ok and output) then
      release(stream)
      return false, M.ERR_ENCODER, ok and err or output
    end
    stream.output = output
    stream.startedAt = deps.clock()
    stream.state, stream.error = M.STARTING, nil
    return true
  end

  local function remove(ip)
    for i = #order, 1, -1 do
      if order[i] == ip then table.remove(order, i) end
    end
    streams[ip] = nil
  end

  -- No video for this phone, and why.
  local function fail(ip, stream, err)
    release(stream)
    stream.state, stream.error = M.ERROR, err
    tell(ip, stream)
    remove(ip)
  end

  function self.isStreaming(ip) return streams[ip] ~= nil end

  function self.count()
    return #order
  end

  -- Starts the video of a phone (player = its player, 0-based), or changes
  -- its quality (a key of QUALITIES, the default one when nil).
  -- Returns ok, err, detail; the phone is told of an encoder failure.
  function self.start(client, quality)
    quality = quality or M.DEFAULT_QUALITY
    if not M.QUALITIES[quality] then return false, 'bad_argument' end
    if client.player == nil or client.player < 0 then return false, 'no_player' end
    local stream = streams[client.ip]
    if stream and stream.quality == quality then
      tell(client.ip, stream)
      return true
    end
    if stream then self.stop(client.ip) end
    stream = { player = client.player, quality = quality }
    local ok, err, detail = open(client.ip, stream)
    if not ok then
      if err == M.ERR_ENCODER then fail(client.ip, stream, err) end
      return false, err, detail
    end
    streams[client.ip] = stream
    order[#order + 1] = client.ip
    tell(client.ip, stream)
    return true
  end

  function self.stop(ip)
    local stream = streams[ip]
    if not stream then return false end
    release(stream)
    remove(ip)
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

  local function check(ip, stream)
    local ok, status = pcall(deps.outputStatus, stream.output)
    if not ok or type(status) ~= 'number' or status < 0 then
      if deps.clock() - stream.startedAt < M.START_GRACE_MS then return end
      return fail(ip, stream, M.ERR_ENCODER)
    end
    local okInside, inside = pcall(deps.update, stream.view)
    inside = okInside and inside == true
    local state = status == 0 and M.LIVE or stream.state
    if state ~= stream.state or inside ~= stream.inside then
      stream.state, stream.inside = state, inside
      tell(ip, stream)
    end
  end

  -- Called every game frame (checks 4 times a second). clients: the
  -- registry (clients.lua) — phones gone or without a player any more lose
  -- their video, a phone given another player gets the view of its new car.
  -- Returns the phones whose video failed, as { [ip] = err }.
  function self.tick(clients)
    local now = deps.clock()
    if now < nextCheck then return {} end
    nextCheck = now + M.CHECK_INTERVAL_MS
    local failed = {}
    for _, ip in ipairs({ unpack(order) }) do
      local stream = streams[ip]
      local client = clients.get(ip)
      if not client or client.player == nil or client.player < 0 then
        self.stop(ip)
      else
        if client.player ~= stream.player then
          release(stream)
          stream.player = client.player
          local ok, err = open(ip, stream)
          if not ok then fail(ip, stream, err) end
        end
        if streams[ip] then check(ip, stream) end
        if not streams[ip] then failed[ip] = stream.error end
      end
    end
    return failed
  end

  return self
end

return M
