local ADDON = './'
package.path = ADDON .. '?.lua;' .. package.path

local out = {}
local rawprint = print
_G.print = function(...) local t = {} for i=1,select('#',...) do t[#t+1]=tostring((select(i,...))) end out[#out+1]=table.concat(t,' ') end
_G.addon = {path = ADDON}
local fake_t = 0
os.clock = function() return fake_t end

package.preload['bit'] = function() return {
  band=function(a,b) return a & b end, bor=function(a,b) return a | b end,
  lshift=function(a,n) return a << n end, rshift=function(a,n) return a >> n end } end

-- settings lib
package.preload['settings'] = function()
  local function copy(t) if type(t)~='table' then return t end local r={} for k,v in pairs(t) do r[k]=copy(v) end return r end
  return { load=function(d) return copy(d) end, register=function() end, save=function() end }
end

-- ffi stub: D3DX returns success and a fake handle
package.loaded['ffi']=nil
package.preload['ffi'] = function()
  local ffi = {C = {}}
  function ffi.cdef() end
  function ffi.new() return {} end
  function ffi.cast(_, v) return type(v)=='number' and v or 4242 end
  function ffi.C.D3DXCreateTextureFromFileA(dev, path, outp) outp[0] = 1; return 0 end
  return ffi
end

-- d3d8 + imgui stubs
local adds, texts = 0, 0
local function mat(rows) local m={} for r=1,4 do for c=1,4 do m['_'..r..c]=rows[r][c] end end return m end
local cam = {-0, -3, 10}
package.preload['d3d8'] = function() return {
  get_device = function() return {
    GetViewport = function() return 0, {Width=1920, Height=1080} end,
    GetTransform = function(_, st)
      if st == 2 then return 0, mat{{1,0,0,0},{0,1,0,0},{0,0,1,0},{-10,0,-40,1}} end
      return 0, mat{{1.5,0,0,0},{0,2.6,0,0},{0,0,-1.001,-1},{0,0,-0.1,0}}
    end } end,
  gc_safe_release = function(x) return x end } end
local dl = setmetatable({}, {__index=function(_,k) return function(self,...) if k=='AddImage' then adds=adds+1 elseif k=='AddText' then texts=texts+1 end end end})
package.preload['imgui'] = function() return {GetBackgroundDrawList=function() return dl end} end

-- ashita mocks
local H = {}
ashita = {events={register=function(ev,name,fn) H[ev]=fn return true end}}
local ZONE, ME, NPC = nil, 1, 50
local npcname
local ent = {}
local function E(i) return ent[i] end
local mm = {
  GetParty=function() return {
    GetMemberTargetIndex=function() return ME end, GetMemberName=function() return 'Tester' end,
    GetMemberZone=function() return ZONE end, GetMemberIsActive=function(_,i) return i==0 and 1 or 0 end,
    GetMemberServerId=function() return 1000 end } end,
  GetPlayer=function() return {GetMainJob=function() return 1 end, GetMainJobLevel=function() return 75 end,
    HasKeyItem=function() return false end} end,
  GetEntity=function() return {
    GetName=function(_,i) return E(i) and E(i).name or '' end,
    GetLocalPositionX=function(_,i) return E(i) and E(i).p[1] or 0 end,
    GetLocalPositionY=function(_,i) return E(i) and E(i).p[2] or 0 end,
    GetLocalPositionZ=function(_,i) return E(i) and E(i).p[3] or 0 end,
    GetRenderFlags0=function(_,i) return E(i) and 0x200 or 0 end,
    GetServerId=function(_,i) return E(i) and E(i).sid or 0 end,
    GetRace=function() return 1 end, GetStatus=function() return 0 end, GetHPPercent=function() return 100 end } end,
  GetTarget=function() return {GetIsSubTargetActive=function() return 0 end, GetTargetIndex=function() return NPC end} end,
  GetInventory=function() return {GetContainerCountMax=function(_,c) return c==0 and 80 or 0 end,
    GetContainerItem=function() return {Id=0,Count=0,Flags=0} end} end,
}
AshitaCore = {GetMemoryManager=function() return mm end,
  GetResourceManager=function() return {GetString=function(_,_,id) return 'Zone'..id end} end,
  GetChatManager=function() return {QueueCommand=function() end} end}

local ok, e = pcall(dofile, ADDON .. 'questmarks.lua')
assert(ok, 'LOAD FAILED: ' .. tostring(e))
rawprint('-- loaded --')

local quests = require('core/quests')
ent[ME]  = {name='Tester', p={10,0,20}, sid=1000}
ent[NPC] = {name=npcname,  p={12,0,22}, sid=2000}

local function pkt(len) local t={} for i=1,len do t[i]='\0' end return t end
local function mk(id, len, setf) local t=pkt(len) t[1]=string.char(id%256); t[2]=string.char(math.floor(id/256)); setf(t) return table.concat(t) end
local function put32(t,o,v) for i=0,3 do t[o+i+1]=string.char((v>>(8*i))&255) end end
local function sendall()
-- 0x056 'current sandoria quests' (type 0x50), all zero flags
H.packet_in{id=0x56, data=mk(0x56,0x28,function(t) put32(t,0x24,0x50) end)}
-- 0x056 type 0xFFFF with Nation=1
H.packet_in{id=0x56, data=mk(0x56,0x28,function(t) put32(t,0x24,0xFFFF) put32(t,0x04,1) end)}
for t0=0,0x140 do if t0~=0x80 and t0~=0xC0 and t0~=0xD0 and t0~=0xD8 then H.packet_in{id=0x56, data=mk(0x56,0x28,function(t) put32(t,0x24,t0) end)} end end
for _,t0 in ipairs{0x80,0xC0,0xD0,0xD8} do H.packet_in{id=0x56, data=mk(0x56,0x28,function(t) put32(t,0x24,t0) end)} end
-- key item packet
H.packet_in{id=0x55, data=mk(0x55,0x88,function(t) put32(t,0x84,0) t[5]='\5' end)}
end
sendall()
rawprint('state loaded:', require('core/state').is_loaded(), 'nation', tostring(require('core/state').nation()))
rawprint('ki 0,2 available:', tostring(require('core/keyitems').available(0)), tostring(require('core/keyitems').available(2)))

local state=require('core/state'); local prereq=require('core/prereq')
local n=0
quests.each_entry(function(npc,e) if n<4 then n=n+1
  local st,src=state.status_of(e.cat,e.area,e.id)
  rawprint('entry',e.cat,e.area,e.id,e.zone,'status',st,src,'supp',prereq.suppressed_reason(e,e.step), 'ms', prereq.marker_state(e,e.step)) end end)
local zone, npcname
quests.each_entry(function(key,e,npc)
  if zone or e.cat~='quest' or type(e.zone)~='number' or e.mob then return end
  local st=prereq.marker_state(e,e.step)
  cnt=(cnt or 0)+1 sts=sts or {} sts[tostring(st)]=(sts[tostring(st)] or 0)+1
  if st then
    local m=quests.marker_for(npc,e.zone)
    if m then zone,npcname=e.zone,npc rawprint('chosen',e.zone,npc,m,e.step) end
  end
end)
for k,v in pairs(sts) do rawprint('st',k,v) end
assert(zone,'no marker candidate')
ZONE = zone ent[NPC].name=npcname
for i = 1, 3 do fake_t = fake_t + 0.6; H.d3d_present() end
sendall()
for i = 1, 12 do fake_t = fake_t + 0.6; H.d3d_present() end
rawprint('frames drawn: AddImage calls', adds)

for _, c in ipairs({'npcs','why '..npcname,'debug on','probe','selftest','selftest off','axes 1 3 2','settings','data','state','why '..npcname,'todo','new','kills','fame','diag','show','visible','lag 0','on'}) do
  H.command{command='/qm '..c, blocked=false}
  fake_t = fake_t + 0.6; H.d3d_present()
end
rawprint('final AddImage',adds,'AddText',texts)
local bk=require('render/backend'); rawprint('last_error',bk.last_error); local i=1 while true do local n,v=debug.getupvalue(bk.flush,i) if not n then break end if n=='prims' then for k,p in pairs(v) do rawprint('prim',k,p.visible,p.tex,p.w,p.h,p.x,p.y) end end i=i+1 end
H.unload()
local bad = 0
for _, l in ipairs(out) do if l:find('failed') or l:find('Error') or l:find('error') or l:find('attempt to') then bad = bad + 1; rawprint('!!', l) end end
rawprint('output lines', #out, 'suspect', bad)
local f = io.open('smoke_out.txt','w') f:write(table.concat(out,'\n')) f:close()
