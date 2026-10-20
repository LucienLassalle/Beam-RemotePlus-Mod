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

-- Asked by the phone (cmd|pov|<quality>[|<width>x<height>[|<bitrate>]], 1 =
-- the default one). width x height: the picture when the phone gives no
-- size, and the most pixels it may ask for. bitrate: the "normal" one.
M.QUALITIES = {
  ['720p60'] = { width = 1280, height = 720, fps = 60, bitrate = 8000000 },
  ['1080p30'] = { width = 1920, height = 1080, fps = 30, bitrate = 10000000 },
  ['1080p60'] = { width = 1920, height = 1080, fps = 60, bitrate = 16000000 },
}
M.DEFAULT_QUALITY = '720p60'

-- Bitrates the phone may ask for, times the quality's own (more bits,
-- finer picture, as long as the Wi-Fi carries them without losses), never
-- above MAX_BITRATE (50 Mbit/s: the most of H.264 level 4.2, the level of
-- 1080p 60 that every phone decodes).
M.BITRATES = { normal = 1, high = 1.5, max = 2 }
M.DEFAULT_BITRATE = 'normal'
M.MAX_BITRATE = 50000000

-- Bits per second of a quality at a bitrate (a key of BITRATES).
function M.bitrate(quality, level)
  local bps = M.QUALITIES[quality].bitrate * M.BITRATES[level or M.DEFAULT_BITRATE]
  return math.floor(math.min(bps, M.MAX_BITRATE))
end

-- Picture size asked by the phone (the shape of its screen): both sides a
-- multiple of SIZE_STEP (whole blocks of the H.264 encoders), within
-- MIN_SIDE..MAX_SIDE (largest picture of the hardware encoders).
M.SIZE_STEP = 8
M.MIN_SIDE = 160
M.MAX_SIDE = 4096

-- "1600x720" -> { width = 1600, height = 720 }, or nil when it is not a
-- valid size for that quality (more pixels than it allows).
function M.parseSize(quality, text)
  local q = M.QUALITIES[quality]
  local width, height = tostring(text):match('^(%d+)x(%d+)$')
  width, height = tonumber(width), tonumber(height)
  if not (q and width and height) then return nil end
  local function validSide(side)
    return side % M.SIZE_STEP == 0 and side >= M.MIN_SIDE and side <= M.MAX_SIDE
  end
  if not (validSide(width) and validSide(height)) or width * height > q.width * q.height then return nil end
  return { width = width, height = height }
end

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
  startOutput(view, url, quality, bitrate) -> output, or nil, err   encodes the view to url (bits/s)
  stopOutput(output)
  outputStatus(output) -> 1 starting, 0 live, < 0 failed
  update(view) -> inside           keeps the camera of the view; true for a seat camera
  cycleCamera(view, offset) -> ok, err
  notify(ip, info)                 info = { state, error, inside, quality }
  clock() -> ms
]]
function M.new(deps)
  local self = {}
  local streams = {} -- [ip] = { player, quality, width, height, bitrate, view, output, state, error, inside }
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

  -- View + encoder for the stream's player, size, quality and bitrate: ok,
  -- err, detail.
  local function open(ip, stream)
    nextId = nextId + 1
    local ok, view, err = pcall(deps.createView, 'beamRemotePlusPov' .. nextId, stream.player, stream.width, stream.height)
    if not (ok and view) then return false, ok and err or view end
    stream.view = view
    local output
    ok, output, err = pcall(deps.startOutput, view, M.url(ip), stream.quality, stream.bitrate)
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
  -- its quality (a key of QUALITIES, the default one when nil). options
  -- (optional): size = { width, height } from parseSize (the quality's own
  -- when nil), bitrate = a key of BITRATES (the default one when nil).
  -- Returns ok, err, detail; the phone is told of an encoder failure.
  function self.start(client, quality, options)
    quality = quality or M.DEFAULT_QUALITY
    options = options or {}
    local q = M.QUALITIES[quality]
    if not q or (options.bitrate and not M.BITRATES[options.bitrate]) then return false, 'bad_argument' end
    local size = options.size or q
    local bitrate = M.bitrate(quality, options.bitrate)
    if client.player == nil or client.player < 0 then return false, 'no_player' end
    local stream = streams[client.ip]
    if stream and stream.quality == quality and stream.width == size.width and stream.height == size.height
        and stream.bitrate == bitrate then
      tell(client.ip, stream)
      return true
    end
    if stream then self.stop(client.ip) end
    stream = { player = client.player, quality = quality, width = size.width, height = size.height, bitrate = bitrate }
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
