--[[
render/backend.lua -- the Ashita v4 half of the marker renderer.

render/markers.lua drives "prims" through a small API (create / texture / pos / size /
color / visible ...), change-detecting every call. On Windower those calls were native
primitives. Here they only update a table, and flush() -- called once per
d3d_present -- turns the visible entries into ImGui draw-list AddImage calls.

Confirmed against Ashita's own crosshair addon: `require 'd3d8'`, `require 'imgui'`,
`d3d8.get_device():GetViewport()` returning (hresult, viewport), and draw lists taking
{x, y} tables plus a 0xAABBGGRR colour.

NOT confirmed (no Ashita install to run against; see PORTING.md):
  * the D3DXCreateTextureFromFileA route for loading PNGs, taken from how other v4
    addons are written;
  * that draw-list :AddImage accepts the same texture handle imgui.Image does.
If texture loading fails, backend.last_error says why and `/qm probe` prints it.
]]

local backend = {}

local ok_ffi, ffi = pcall(require, 'ffi')
local ok_imgui, imgui = pcall(require, 'imgui')
local ok_d3d, d3d8 = pcall(require, 'd3d8')

backend.last_error = nil
local prims, texts = {}, {}
local texcache = {}          -- path -> {id = <handle>, keep = <cdata>} | false

-- ---------------------------------------------------------------------------
-- Textures
-- ---------------------------------------------------------------------------

local cdef_done = false
local function ensure_cdef()
    if cdef_done or not ok_ffi then return end
    cdef_done = true
    -- Ashita's d3d8 module already declares D3DXCreateTextureFromFileA with typed pointers
    -- (IDirect3DDevice8*, IDirect3DTexture8**). Only declare it if it is genuinely missing,
    -- and never with different types than d3d8's own.
    local have = pcall(function() return ffi.C.D3DXCreateTextureFromFileA end)
    if not have then
        pcall(ffi.cdef, [[
            typedef struct IDirect3DDevice8 IDirect3DDevice8;
            typedef struct IDirect3DTexture8 IDirect3DTexture8;
            int32_t __stdcall D3DXCreateTextureFromFileA(IDirect3DDevice8* pDevice, const char* pSrcFile, IDirect3DTexture8** ppTexture);
        ]])
    end
end

local function load_texture(path)
    local hit = texcache[path]
    if hit ~= nil then return hit end
    texcache[path] = false          -- never retry a failure every frame

    if not (ok_ffi and ok_d3d) then
        backend.last_error = 'ffi or d3d8 module unavailable'
        return false
    end
    ensure_cdef()

    local ok, res = pcall(function()
        local dev = d3d8.get_device()
        local out = ffi.new('IDirect3DTexture8*[1]')
        local hr = ffi.C.D3DXCreateTextureFromFileA(dev, path, out)
        if hr ~= 0 or out[0] == nil then
            error(('D3DXCreateTextureFromFileA(%s) -> 0x%08X'):format(path, hr % 4294967296))
        end
        local tex = ffi.cast('IDirect3DTexture8*', out[0])
        if d3d8.gc_safe_release then tex = d3d8.gc_safe_release(tex) end
        return {keep = tex, id = tonumber(ffi.cast('uint32_t', tex))}
    end)

    if ok and res then
        texcache[path] = res
        return res
    end
    backend.last_error = tostring(res)
    return false
end

-- ---------------------------------------------------------------------------
-- Prim API (what render/markers.lua calls)
-- ---------------------------------------------------------------------------

local function P(n)
    local p = prims[n]
    if not p then p = {visible = false, x = 0, y = 0, w = 0, h = 0, a = 255, r = 255, g = 255, b = 255}; prims[n] = p end
    return p
end
local function T(n)
    local t = texts[n]
    if not t then t = {visible = false, x = 0, y = 0, s = ''}; texts[n] = t end
    return t
end

function backend.api(addon_path)
    local assets = (addon_path or './') .. 'assets/'
    return {
        create   = function(n) P(n) end,
        delete   = function(n) prims[n] = nil end,
        texture  = function(n, path) P(n).tex = path end,
        pos      = function(n, x, y) local p = P(n); p.x, p.y = x, y end,
        size     = function(n, w, h) local p = P(n); p.w, p.h = w, h end,
        color    = function(n, a, r, g, b) local p = P(n); p.a, p.r, p.g, p.b = a, r, g, b end,
        visible  = function(n, v) P(n).visible = v and true or false end,
        fit      = function() end,
        path     = function() return assets end,

        tcreate  = function(n) T(n) end,
        tdelete  = function(n) texts[n] = nil end,
        ttext    = function(n, s) T(n).s = s end,
        tpos     = function(n, x, y) local t = T(n); t.x, t.y = x, y end,
        tvisible = function(n, v) T(n).visible = v and true or false end,
        tsetup   = function() end,
    }
end

function backend.destroy()
    prims, texts = {}, {}
end

-- ---------------------------------------------------------------------------
-- Per-frame flush
-- ---------------------------------------------------------------------------

local function abgr(a, r, g, b)
    -- Plain arithmetic: stays a positive number, unlike bit.bor's signed result.
    local function c(v) v = math.floor(v + 0.5); return v < 0 and 0 or (v > 255 and 255 or v) end
    return c(a) * 16777216 + c(b) * 65536 + c(g) * 256 + c(r)
end

local UV0, UV1 = {0, 0}, {1, 1}

backend.dl_source = 'none'
backend.draw_errors = 0
backend.draw_calls = {image = 0, text = 0}

local function note_err(what, e)
    backend.draw_errors = backend.draw_errors + 1
    backend.last_error = what .. ': ' .. tostring(e)
end

-- Overlay window flags: no title/resize/move/scroll/collapse/background/settings/inputs/focus.
local OVERLAY_FLAGS = 1 + 2 + 4 + 8 + 16 + 32 + 128 + 256 + 512 + 4096 + 8192 + 65536 + 131072

local function draw_all(dl)
    for _, p in pairs(prims) do
        if p.visible and p.tex and p.w > 0 and p.h > 0 then
            local tex = load_texture(p.tex)
            if tex then
                local ok, e = pcall(dl.AddImage, dl, tex.id,
                    {p.x, p.y}, {p.x + p.w, p.y + p.h}, UV0, UV1,
                    abgr(p.a, p.r, p.g, p.b))
                if ok then backend.draw_calls.image = backend.draw_calls.image + 1
                else note_err('AddImage', e) end
            end
        end
    end
    for _, t in pairs(texts) do
        if t.visible and t.s ~= '' then
            local ok, e = pcall(dl.AddRectFilled, dl, {t.x - 2, t.y - 1}, {t.x + #t.s * 7 + 2, t.y + 14}, 0xA0000000)
            if not ok then note_err('AddRectFilled', e) end
            ok, e = pcall(dl.AddText, dl, {t.x, t.y}, 0xFFFFFFFF, t.s)
            if ok then backend.draw_calls.text = backend.draw_calls.text + 1
            else note_err('AddText', e) end
        end
    end
end

function backend.flush()
    if not (ok_imgui and imgui) then backend.dl_source = 'no imgui module' return end

    -- 1) full-screen background draw list (newer Ashita imgui builds)
    if imgui.GetBackgroundDrawList then
        local ok, dl = pcall(imgui.GetBackgroundDrawList)
        if ok and dl then
            backend.dl_source = 'background'
            return draw_all(dl)
        end
    end

    -- 2) a transparent, click-through, full-screen window and its own draw list
    --    (works on every Ashita v4 build that has imgui.Begin)
    if imgui.Begin and imgui.GetWindowDrawList then
        local w, h = backend.viewport()
        w, h = w or 1920, h or 1080
        local okp = pcall(function()
            if imgui.SetNextWindowPos then imgui.SetNextWindowPos({0, 0}) end
            if imgui.SetNextWindowSize then imgui.SetNextWindowSize({w, h}) end
        end)
        local began, shown = pcall(imgui.Begin, 'questmarks_overlay', true, OVERLAY_FLAGS)
        if began then
            local ok, dl = pcall(imgui.GetWindowDrawList)
            if ok and dl then
                backend.dl_source = 'overlay window'
                draw_all(dl)
            else
                note_err('GetWindowDrawList', dl)
            end
            pcall(imgui.End)
            return
        else
            note_err('imgui.Begin', shown)
        end
    end

    -- 3) last resort: foreground list
    if imgui.GetForegroundDrawList then
        local ok, dl = pcall(imgui.GetForegroundDrawList)
        if ok and dl then
            backend.dl_source = 'foreground'
            return draw_all(dl)
        end
    end
    backend.dl_source = 'none available'
end

-- Screen size in the same pixel space the draw list uses.
function backend.viewport()
    if not ok_d3d then return nil end
    local ok, res, vp = pcall(function() return d3d8.get_device():GetViewport() end)
    if ok and res == 0 and vp then return vp.Width, vp.Height end
    return nil
end

return backend
