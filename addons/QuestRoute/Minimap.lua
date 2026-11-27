-- 小地图旋转投影、圆形裁剪与下一目标边缘方向标记。
local _, ns = ...
local IsFinite = ns.Util.IsFinite
local Pins = ns.MapPins
local MinimapPosition, NewRoutePin, SetRoutePinAppearance = Pins.MinimapPosition, Pins.New, Pins.Appearance
local SeparatePin, PinLeader, RenderAlternativePins = Pins.Separate, Pins.Leader, Pins.RenderAlternatives

local function ClipMinimapSegment(ax, ay, bx, by, radius)
    local dx, dy = bx - ax, by - ay
    local a = dx * dx + dy * dy
    if a == 0 then return nil end
    local b, c = ax * dx + ay * dy, ax * ax + ay * ay - radius * radius
    local discriminant = b * b - a * c
    if discriminant < 0 then return nil end
    local root = math.sqrt(discriminant)
    local low, high = math.max(0, (-b - root) / a), math.min(1, (-b + root) / a)
    if low >= high then return nil end
    return ax + low * dx, ay + low * dy, ax + high * dx, ay + high * dy
end

local function StepsWorldMatch(view, steps)
    local worlds = view.renderedStepWorlds
    if not worlds or view.renderedStepsCount ~= #steps then return false end
    for i, step in ipairs(steps) do
        if worlds[i] ~= step.world then return false end
    end
    return true
end

local function RenderMinimapRoute()
    if not Minimap then return end
    local view = ns.route.minimapView
    local plan, player = ns.route.plan, ns.route.playerLocation
    if not plan or not plan.enabled or not Minimap:IsVisible() or not player or not player.world
        or player.coordinateMapID ~= plan.mapID then
        if view then view.overlay:Hide(); view.renderedSequence = nil end
        return
    end
    local radius = C_Minimap.GetViewRadius()
    local width, height = Minimap:GetWidth(), Minimap:GetHeight()
    local rotating, ignored = C_CVar.GetCVarBool("rotateMinimap"), C_Minimap.IsRotateMinimapIgnored()
    local cosine, sine = 1, 0
    if canaccessvalue(rotating) and rotating and canaccessvalue(ignored) and not ignored then
        local facing = GetPlayerFacing()
        if not IsFinite(facing) then if view then view.overlay:Hide(); view.renderedSequence = nil end; return end
        cosine, sine = math.cos(facing), math.sin(facing)
    end
    if not IsFinite(radius) or radius <= 0 or not IsFinite(width) or not IsFinite(height) or width <= 0 or height <= 0 then
        if view then view.overlay:Hide(); view.renderedSequence = nil end
        return
    end
    local world = player.world
    local opportunitiesRef = plan.discovery and plan.discovery.opportunities
    local overlayShown = view and (not view.overlay.IsShown or view.overlay:IsShown())
    if view and overlayShown
        and view.renderedSequence == plan.sequence and view.renderedMapID == plan.mapID
        and view.renderedDiscovery == plan.discovery
        and view.renderedOpportunities == opportunitiesRef
        and StepsWorldMatch(view, plan.steps)
        and view.renderedX == world.x and view.renderedY == world.y and view.renderedContinent == world.continentID
        and view.renderedRadius == radius and view.renderedWidth == width and view.renderedHeight == height
        and view.renderedCosine == cosine and view.renderedSine == sine then
        return
    end
    if not view then
        local overlay = CreateFrame("Frame", nil, Minimap)
        overlay:SetAllPoints(Minimap)
        overlay:EnableMouse(false)
        view = { overlay = overlay, pins = {}, lines = {} }
        ns.route.minimapView = view
    end
    view.overlay:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    view.overlay:Show()
    for _, leader in pairs(view.leaders or {}) do leader:Hide() end
    local placed, shownPins, shownLines = {}, {}, {}
    local previous = { x = 0, y = 0 }
    for index, step in ipairs(plan.steps) do
        local position = MinimapPosition(step.world, player.world, radius, cosine, sine)
        if position then
            local length = math.sqrt(position.x * position.x + position.y * position.y)
            local onEdge = length > 0.84
            if not onEdge or index == 1 then
                local x, y = position.x, position.y
                if onEdge then x, y = x * 0.84 / length, y * 0.84 / length end
                local pin = view.pins[index]
                if not pin then pin = NewRoutePin(view); pin:SetSize(20, 20); view.pins[index] = pin end
                pin.step, pin.onEdge = step, onEdge
                pin:ClearAllPoints()
                local px, py, shifted = SeparatePin(placed, x * width / 2, y * height / 2, width, height, true)
                pin.shifted = shifted
                pin:SetPoint("CENTER", view.overlay, "CENTER", px, py)
                PinLeader(view, index, "CENTER", x * width / 2, y * height / 2, px, py, 1)
                SetRoutePinAppearance(pin, step, index)
                pin:Show()
                shownPins[index] = true
            end
        end
        -- 裁剪实际端点，不连接边缘方向标记，以免画出不真实的后续路线。
        if previous and position then
            local ax, ay, bx, by = ClipMinimapSegment(previous.x, previous.y, position.x, position.y, 0.9)
            if ax then
                -- 第一段在玩家箭头旁留空，保留中心角色标记可见性。
                if index == 1 then
                    local length = math.sqrt(bx * bx + by * by)
                    if length > 0.07 then ax, ay = bx * 0.07 / length, by * 0.07 / length else ax = nil end
                end
                if ax then
                    local line = view.lines[index]
                    if not line then line = view.overlay:CreateLine(nil, "ARTWORK"); view.lines[index] = line end
                    line:SetColorTexture(index == 1 and 1 or 0.1, index == 1 and 0.65 or 0.85, index == 1 and 0.1 or 1, 0.9)
                    line:SetThickness(2.5)
                    line:SetStartPoint("CENTER", view.overlay, ax * width / 2, ay * height / 2)
                    line:SetEndPoint("CENTER", view.overlay, bx * width / 2, by * height / 2)
                    line:Show()
                    shownLines[index] = true
                end
            end
        end
        previous = position
    end
    for index, pin in pairs(view.pins) do if not shownPins[index] then pin:Hide(); pin.step = nil end end
    for index, line in pairs(view.lines) do if not shownLines[index] then line:Hide() end end
    RenderAlternativePins(view, plan, placed, width, height, 1, plan.mapID, player.world, radius, cosine, sine)
    Pins.RenderOpportunities(view, plan, placed, width, height, 1, plan.mapID, player.world, radius, cosine, sine)
    view.renderedSequence, view.renderedMapID, view.renderedDiscovery = plan.sequence, plan.mapID, plan.discovery
    view.renderedOpportunities = opportunitiesRef
    local worlds = view.renderedStepWorlds or {}
    view.renderedStepWorlds = worlds
    view.renderedStepsCount = #plan.steps
    for i, step in ipairs(plan.steps) do worlds[i] = step.world end
    for i = #plan.steps + 1, #worlds do worlds[i] = nil end
    view.renderedX, view.renderedY, view.renderedContinent = world.x, world.y, world.continentID
    view.renderedRadius, view.renderedWidth, view.renderedHeight = radius, width, height
    view.renderedCosine, view.renderedSine = cosine, sine
end

ns.Minimap = { Render = RenderMinimapRoute }
