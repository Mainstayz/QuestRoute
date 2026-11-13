-- 原生大地图/战场地图的路线图层与矩形线段裁剪。
local _, ns = ...
local IsFinite, IsID = ns.Util.IsFinite, ns.Util.IsID
local Pins = ns.MapPins
local ProjectWorld, NewRoutePin, SetRoutePinAppearance = Pins.ProjectWorld, Pins.New, Pins.Appearance
local SeparatePin, PinLeader, RenderAlternativePins = Pins.Separate, Pins.Leader, Pins.RenderAlternatives

-- 纯几何裁剪，不把地图外的线段连成一条虚假的地图内路线。
local function ClipSegment(ax, ay, bx, by)
    local dx, dy, low, high = bx - ax, by - ay, 0, 1
    local p, q = { -dx, dx, -dy, dy }, { ax, 1 - ax, ay, 1 - ay }
    for i = 1, 4 do
        if p[i] == 0 then
            if q[i] < 0 then return nil end
        else
            local value = q[i] / p[i]
            if p[i] < 0 then low = math.max(low, value) else high = math.min(high, value) end
            if low > high then return nil end
        end
    end
    return ax + low * dx, ay + low * dy, ax + high * dx, ay + high * dy
end

local function NewMapView(map, canvas)
    local overlay = CreateFrame("Frame", nil, canvas)
    overlay:SetAllPoints(canvas)
    overlay:SetFrameLevel(canvas:GetFrameLevel() + 3000)
    overlay:EnableMouse(false)
    local view = { map = map, canvas = canvas, overlay = overlay, pins = {}, lines = {} }
    ns.route.views[#ns.route.views + 1] = view
    return view
end

local function RenderMap(view, plan, player)
    if not view.map:IsShown() or not plan.enabled then view.overlay:Hide(); return end
    local mapID = view.map.GetMapID and view.map:GetMapID()
    local width, height = view.canvas:GetWidth(), view.canvas:GetHeight()
    if not IsID(mapID) or mapID ~= plan.mapID or not IsFinite(width) or not IsFinite(height) or width <= 0 or height <= 0 then
        view.overlay:Hide(); return
    end
    if view.sequence ~= plan.sequence or view.mapID ~= mapID then
        view.positions, view.alternativePositions = {}, {}
        for index, step in ipairs(plan.steps) do view.positions[index] = ProjectWorld(step.world, mapID) end
        view.sequence, view.mapID = plan.sequence, mapID
    end
    view.overlay:SetFrameLevel(view.canvas:GetFrameLevel() + 3000)
    view.overlay:Show()
    local scale = view.canvas:GetScale()
    if not IsFinite(scale) or scale <= 0 then scale = 1 end
    local previous = player and ProjectWorld(player.world, mapID)
    local placed = {}
    for _, leader in pairs(view.leaders or {}) do leader:Hide() end
    for index, step in ipairs(plan.steps) do
        local position = view.positions[index]
        local pin = view.pins[index]
        if position and position.x >= 0 and position.x <= 1 and position.y >= 0 and position.y <= 1 then
            if not pin then pin = NewRoutePin(view); view.pins[index] = pin end
            pin.step = step
            pin:SetScale(1 / scale)
            pin:ClearAllPoints()
            -- 偏移量按逆缩放后的编号解释；单独细线连接未改变的真实地图点。
            local x, y = position.x * width * scale, position.y * height * scale
            local px, py, shifted = SeparatePin(placed, x, y, width * scale, height * scale)
            pin.shifted = shifted
            pin:SetPoint("CENTER", view.overlay, "TOPLEFT", px, -py)
            PinLeader(view, index, "TOPLEFT", x / scale, -y / scale, px / scale, -py / scale, scale)
            SetRoutePinAppearance(pin, step, index)
            pin:Show()
        elseif pin then pin:Hide() end
        local line = view.lines[index]
        local ax, ay, bx, by
        if previous and position then ax, ay, bx, by = ClipSegment(previous.x, previous.y, position.x, position.y) end
        if ax then
            if not line then
                line = view.overlay:CreateLine(nil, "ARTWORK")
                line:SetColorTexture(0.1, 0.85, 1, 0.8)
                view.lines[index] = line
            end
            line:SetThickness(2 / scale)
            line:SetStartPoint("TOPLEFT", view.overlay, ax * width, -ay * height)
            line:SetEndPoint("TOPLEFT", view.overlay, bx * width, -by * height)
            line:Show()
        elseif line then line:Hide() end
        previous = position
    end
    for i, pin in pairs(view.pins) do if i > #plan.steps then pin:Hide() end end
    for i, line in pairs(view.lines) do if i > #plan.steps then line:Hide() end end
    RenderAlternativePins(view, plan, placed, width, height, scale, mapID)
    Pins.RenderOpportunities(view, plan, placed, width, height, scale, mapID)
end

local function RenderRouteMaps()
    local plan = ns.route.plan
    if not plan then return end
    for _, map in pairs({ WorldMapFrame = WorldMapFrame, BattlefieldMapFrame = BattlefieldMapFrame }) do
        if map and map.GetCanvas and map.GetMapID then
            local canvas = map:GetCanvas()
            if canvas then
                local found
                for _, view in ipairs(ns.route.views) do if view.map == map and view.canvas == canvas then found = view; break end end
                if not found then found = NewMapView(map, canvas) end
                RenderMap(found, plan, ns.route.playerLocation)
            end
        end
    end
end

ns.WorldMap = { Render = RenderRouteMaps }
