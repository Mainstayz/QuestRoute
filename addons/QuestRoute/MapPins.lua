-- 两图共用的投影、编号图元、悬停交互、防重叠和备选热点绘制。
local _, ns = ...
local IsFinite, Accessible = ns.Util.IsFinite, ns.Util.Accessible
local tooltipPhases = { travel = "赶路中", working = "在此完成目标", unavailable = "等待位置更新" }

local function ProjectWorld(world, mapID)
    if not world then return nil end
    local ok, actualMap, point = pcall(C_Map.GetMapPosFromWorldPos,
        world.continentID, CreateVector2D(world.x, world.y), mapID)
    if ok and actualMap == mapID and point and IsFinite(point.x) and IsFinite(point.y) then
        return { x = point.x, y = point.y }
    end
end

local function ConfigureRoutePin(pin)
    pin:SetScript("OnClick", function(self)
        if self.step then
            local shift = Accessible(IsShiftKeyDown())
            if shift then
                local result = ns.ChangeQuestSpot({ questID = self.step.questID, objectiveKey = self.step.objectiveKey,
                    hotspotID = self.hotspot and self.hotspot.id })
                print("|cff31cee8QuestRoute|r " .. (result.ok and "已更换地点，旧点附近临时避开10分钟。" or result.error.message))
            else ns.SetQuestSkip({ questID = self.step.questID }) end
            ns.route.hoveredPin = nil
            GameTooltip:Hide()
        end
    end)
    pin:SetScript("OnEnter", function(self)
        local step = self.step
        if not step then return end
        ns.route.hoveredPin = self
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText((self.hotspot and (step.index .. self.hotspotLabel .. " 备选热点：") or (step.index .. ". "))
            .. step.title)
        if step.objective then GameTooltip:AddLine(step.objective.text, 0.7, 1, 0.8) end

        -- 状态与位置性质合并一行；静态区域、任务参考位置不表示实时实体坐标。
        local location = step.objective and "静态刷新区域" or "任务参考位置"
        local status
        if not self.hotspot then
            local navigation = step.navigation
            if step.action == "turn_in" then status = "可交任务"
            elseif step.action == "completion_pending" then status = "已完成，等待确认交付"
            elseif navigation then status = tooltipPhases[navigation.phase] end
        end
        GameTooltip:AddLine(status and (status .. " · " .. location) or location, 1, 0.85, 0.3)
        local actions = "右键跳过任务"
        if step.objectiveKey then
            actions = actions .. (self.hotspot and " · Shift+右键切换至此" or " · Shift+右键换地点")
        end
        GameTooltip:AddLine(actions, 0.6, 0.9, 1)
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function(self)
        if ns.route.hoveredPin == self then ns.route.hoveredPin = nil end
        GameTooltip:Hide()
    end)
end

local function NewRoutePin(view)
    local pin = CreateFrame("Button", nil, view.overlay)
    pin:SetSize(24, 24)
    pin:RegisterForClicks("RightButtonUp")
    pin.background = pin:CreateTexture(nil, "BACKGROUND")
    pin.background:SetAllPoints(pin)
    pin.background:SetColorTexture(0.08, 0.12, 0.15, 0.95)
    pin.color = pin:CreateTexture(nil, "ARTWORK")
    pin.color:SetPoint("TOPLEFT", pin, "TOPLEFT", 2, -2)
    pin.color:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", -2, 2)
    pin.text = pin:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pin.text:SetAllPoints(pin)
    pin.text:SetTextColor(1, 1, 1)
    ConfigureRoutePin(pin)
    return pin
end

local function SetRoutePinAppearance(pin, step, index)
    local delivery = step.action == "turn_in"
    if index == 1 then pin.color:SetColorTexture(0.95, 0.55, 0.05, 0.95)
    elseif delivery then pin.color:SetColorTexture(0.85, 0.65, 0.05, 0.95)
    else pin.color:SetColorTexture(0.05, 0.6, 0.75, 0.95) end
    pin.text:SetText(index .. (delivery and "?" or step.action == "completion_pending" and "~" or ""))
end

-- 多个未完目标可能共用同一刷新点，只错开编号，路线坐标和选点保持原值。
local function SeparatePin(placed, x, y, width, height, circular)
    local function Free(px, py)
        for _, point in ipairs(placed) do
            if math.abs(px - point.x) < 23 and math.abs(py - point.y) < 23 then return false end
        end
        return true
    end
    local px, py = x, y
    if not Free(x, y) then
        local found
        for ring = 1, 3 do
            for dx = -ring, ring do
                for dy = -ring, ring do
                    if math.abs(dx) == ring or math.abs(dy) == ring then
                        local cx, cy = x + dx * 24, y + dy * 24
                        local inside = circular and ((cx / (width / 2)) ^ 2 + (cy / (height / 2)) ^ 2 <= 0.9 ^ 2)
                            or not circular and cx >= 0 and cx <= width and cy >= 0 and cy <= height
                        if inside and Free(cx, cy) then px, py, found = cx, cy, true; break end
                    end
                end
                if found then break end
            end
            if found then break end
        end
    end
    placed[#placed + 1] = { x = px, y = py }
    return px, py, px ~= x or py ~= y
end

local function PinLeader(view, index, anchor, x, y, px, py, scale)
    view.leaders = view.leaders or {}
    local line = view.leaders[index]
    if math.abs(x - px) > 0.001 or math.abs(y - py) > 0.001 then
        if not line then line = view.overlay:CreateLine(nil, "ARTWORK"); view.leaders[index] = line end
        line:SetColorTexture(0.7, 0.9, 1, 0.85)
        line:SetThickness(1 / scale)
        line:SetStartPoint(anchor, view.overlay, x, y)
        line:SetEndPoint(anchor, view.overlay, px, py)
        line:Show()
    elseif line then line:Hide() end
end

-- 小地图以玩家为中心，世界x向北、y向西；视野半径由调用方读取客户端API。
local function MinimapPosition(world, origin, radius, cosine, sine)
    if not world or world.continentID ~= origin.continentID then return nil end
    local east, north = (origin.y - world.y) / radius, (world.x - origin.x) / radius
    return { x = east * cosine + north * sine, y = north * cosine - east * sine }
end

local function RenderAlternativePins(view, plan, placed, width, height, scale, mapID, origin, radius, cosine, sine)
    view.alternatives = view.alternatives or {}
    for _, pin in pairs(view.alternatives) do pin:Hide(); pin.step, pin.hotspot = nil, nil end
    local circular, serial = origin ~= nil, 0
    for _, step in ipairs(plan.steps) do
        for slot = 2, #(step.hotspots or {}) do
            local hotspot = step.hotspots[slot]
            local position
            if circular then position = MinimapPosition(hotspot.world, origin, radius, cosine, sine)
            else
                local key = step.stepKey .. ":" .. hotspot.id
                position = view.alternativePositions[key]
                if position == nil then
                    position = ProjectWorld(hotspot.world, mapID) or false
                    view.alternativePositions[key] = position
                end
            end
            local visible = position and (circular and position.x ^ 2 + position.y ^ 2 <= 0.84 ^ 2
                or not circular and position.x >= 0 and position.x <= 1 and position.y >= 0 and position.y <= 1)
            if visible then
                serial = serial + 1
                local pin = view.alternatives[serial]
                if not pin then pin = NewRoutePin(view); pin:SetSize(20, 20); view.alternatives[serial] = pin end
                pin.step, pin.hotspot, pin.hotspotLabel, pin.onEdge = step, hotspot, slot == 2 and "b" or "c", false
                pin:SetScale(1 / scale)
                local x, y = position.x * width * scale, position.y * height * scale
                if circular then x, y = position.x * width / 2, position.y * height / 2 end
                local px, py, shifted = SeparatePin(placed, x, y, width * scale, height * scale, circular)
                pin.shifted = shifted
                pin:ClearAllPoints()
                pin:SetPoint("CENTER", view.overlay, circular and "CENTER" or "TOPLEFT", px, circular and py or -py)
                PinLeader(view, #plan.steps + serial, circular and "CENTER" or "TOPLEFT",
                    x / scale, (circular and y or -y) / scale, px / scale, (circular and py or -py) / scale, scale)
                pin.color:SetColorTexture(0.28, 0.27, 0.6, 0.85)
                pin.text:SetText(step.index .. pin.hotspotLabel)
                pin:Show()
            end
        end
    end
end

ns.MapPins = {
    ProjectWorld = ProjectWorld, Configure = ConfigureRoutePin, New = NewRoutePin, Appearance = SetRoutePinAppearance,
    Separate = SeparatePin, Leader = PinLeader, MinimapPosition = MinimapPosition, RenderAlternatives = RenderAlternativePins,
}
