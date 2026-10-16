--[[
render/camera.lua -- where the view and projection matrices come from on Ashita.

Windower exposed an undocumented `windower.get_camera()`. Ashita wraps the game's
Direct3D device, so the equivalent is to read the transforms the game last set:
`d3d8.get_device():GetTransform(state)` (documented in Ashita's d3d8dev namespace as
returning an HRESULT and a D3DMATRIX).

The one thing that cannot be known offline is WHEN in the frame those transforms hold
the 3D scene's camera rather than something the UI pass set afterwards. So capture()
may be called from several hooks (d3d_beginscene and d3d_present); it only accepts a
pair whose projection is a PERSPECTIVE matrix, and keeps the last such pair. An
orthographic projection (a UI pass) has P[4][4] = 1 and P[3][4] = 0, a perspective one
has P[3][4] = +-1 and P[4][4] = 0.

Matrices are read into nested 1-indexed tables, m[row][col], row-vector convention
(v' = v * M) -- the layout render/project.lua already expects.
]]

local camera = {}

local ok_d3d, d3d8 = pcall(require, 'd3d8')

local D3DTS_VIEW, D3DTS_PROJECTION = 2, 3

camera.stats = {captured = 0, rejected_ortho = 0, errors = 0, last_error = nil, accessor = nil}

local view, proj, stamp = nil, nil, nil

-- A D3DMATRIX may surface as a struct with _11.._44 fields, as m[r][c], or as .m[r][c].
-- Probe once, remember which worked.
local accessors = {
    function(m, r, c) return m['_' .. r .. c] end,
    function(m, r, c) return m.m[r - 1][c - 1] end,
    function(m, r, c) return m[r - 1][c - 1] end,
    function(m, r, c) return m[r][c] end,
}
local chosen

local function read(m)
    if m == nil then return nil end
    local order = {}
    if chosen then order[1] = chosen end
    for i, f in ipairs(accessors) do if f ~= chosen then order[#order + 1] = f end end
    for i, f in ipairs(order) do
        local ok, v = pcall(f, m, 1, 1)
        if ok and type(v) == 'number' then
            chosen = f
            camera.stats.accessor = i
            local out = {}
            for r = 1, 4 do
                out[r] = {}
                for c = 1, 4 do out[r][c] = f(m, r, c) end
            end
            return out
        end
    end
    return nil
end

local function perspective(p)
    local w = p[3][4]
    return (math.abs(w) > 0.5) and math.abs(p[4][4]) < 0.5
end

function camera.capture()
    if not ok_d3d then return false end
    local ok, err = pcall(function()
        local dev = d3d8.get_device()
        local r1, v = dev:GetTransform(D3DTS_VIEW)
        local r2, p = dev:GetTransform(D3DTS_PROJECTION)
        if r1 ~= 0 or r2 ~= 0 then error(('GetTransform hr=%s/%s'):format(tostring(r1), tostring(r2))) end
        local vm, pm = read(v), read(p)
        if not vm or not pm then error('could not read D3DMATRIX (unknown field layout)') end
        if perspective(pm) then
            view, proj, stamp = vm, pm, os.clock()
            camera.stats.captured = camera.stats.captured + 1
        else
            camera.stats.rejected_ortho = camera.stats.rejected_ortho + 1
        end
    end)
    if not ok then
        camera.stats.errors = camera.stats.errors + 1
        camera.stats.last_error = tostring(err)
    end
    return ok
end

-- Shape render/project.lua consumes (a stand-in for windower.get_camera()).
function camera.get()
    if not view or not proj then return nil end
    return {valid = (os.clock() - stamp) < 0.5, matrix = view, projection_matrix = proj}
end

function camera.matrices() return view, proj end

return camera
