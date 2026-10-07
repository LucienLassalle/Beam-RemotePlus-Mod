-- Test doubles for the BeamNG APIs injected into the mod modules.
local M = {}

function M.clock(start)
  local self = { now = start or 100000 }
  function self.fn() return self.now end
  function self.advance(ms) self.now = self.now + ms end
  return self
end

-- core_input_virtualInput
function M.input()
  local self = { created = {}, deleted = {}, emitted = {}, nextId = 0, failCreate = false }
  function self.createDevice(name, product, axes, buttons, povs)
    if self.failCreate then return -1 end
    local id = self.nextId
    self.nextId = id + 1
    self.created[#self.created + 1] = { id = id, name = name, product = product, axes = axes, buttons = buttons }
    return id
  end
  function self.deleteDevice(id) self.deleted[#self.deleted + 1] = id end
  function self.emit(id, kind, index, action, value)
    self.emitted[#self.emitted + 1] = { id = id, kind = kind, index = index, value = value }
  end
  return self
end

function M.vehicle(id, model)
  local self = { id = id, model = model or 'scintilla', commands = {} }
  function self:getID() return self.id end
  function self:getJBeamFilename() return self.model end
  function self:queueLuaCommand(code) self.commands[#self.commands + 1] = code end
  return self
end

function M.transport()
  local self = { inbox = {}, sent = {}, opened = false, failOpen = false }
  function self.open() if self.failOpen then return false, 'busy' end self.opened = true return true end
  function self.close() self.opened = false end
  function self.receive()
    local packet = table.remove(self.inbox, 1)
    if not packet then return nil end
    return packet[1], packet[2]
  end
  function self.send(payload, ip, port) self.sent[#self.sent + 1] = { payload = payload, ip = ip, port = port } end
  function self.push(data, ip) self.inbox[#self.inbox + 1] = { data, ip } end
  function self.lastTo(ip)
    for i = #self.sent, 1, -1 do if self.sent[i].ip == ip then return self.sent[i].payload end end
  end
  return self
end

function M.logger()
  local self = { lines = {} }
  return require('/lua/ge/extensions/beamRemotePlus/logger').new(function(level, _, message)
    self.lines[#self.lines + 1] = level .. ' ' .. message
  end, function() return 0 end), self
end

function M.memoryFiles(initial)
  local self = { files = initial or {} }
  function self.readJson(path) return self.files[path] end
  function self.writeJson(path, value) self.files[path] = value return true end
  return self
end

return M
