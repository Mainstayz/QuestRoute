-- 两图共用的投影、编号图元、悬停交互、防重叠和备选热点绘制。
local _, ns = ...
local IsFinite, Accessible, FormatDistance = ns.Util.IsFinite, ns.Util.Accessible, ns.Util.FormatDistance
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
        -- 合并方块代表一组任务：右键不跳过，避免一次或误点跳过整组。
        if self.opportunity and self.group and #self.group.items > 1 then return end
        if self.step then
            local shift = Accessible(IsShiftKeyDown())
            if shift and self.opportunity then return end
            if shift then
                local result = ns.ChangeQuestSpot({ questID = self.step.questID, objectiveKey = self.step.objectiveKey,
                    hotspotID = self.hotspot and self.hotspot.id })
                print("|cff31cee8QuestRoute|r " .. (result.ok and "已更换地点，旧点附近临时避开10分钟。" or result.error.message))
            else ns.SetQuestSkip({ questID = self.step.questID }) end
            ns.route.hoveredPin = nil
            GameTooltip:Hide()
            if ns.WorldMap and ns.WorldMap.Render then ns.WorldMap.Render() end
            if ns.Minimap and ns.Minimap.Render then ns.Minimap.Render() end
        end
    end)
    pin:SetScript("OnEnter", function(self)
        local step = self.step
        if not step then return end
        ns.route.hoveredPin = self
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if self.opportunity then
            local rejection = ns.Discovery.rejectionLabels[step.reason]
            local count = self.group and #self.group.items or 1
            local prefix = rejection and "× "
                or (step.action == "possible_item_drop" or step.action == "pick_up" and step.certainty ~= "confirmed") and "~! " or "! "
            if count > 1 then
                -- 合并方块：第一行数量，第二行首个任务，总共仍不超过四行。
                GameTooltip:SetText(prefix .. count .. " 个任务")
                GameTooltip:AddLine("首个：" .. step.title, 0.7, 1, 0.8)
            else
                GameTooltip:SetText(prefix .. step.title)
                local location = ns.Util.FormatLocation(step.point)
                if location then GameTooltip:AddLine(location, 0.7, 1, 0.8) end
            end
            local status = rejection and (rejection .. " · 接取条件待确认")
                or self.carried and "已持有物品 · 向NPC确认接取/交付"
                or step.action == "possible_item_drop" and (step.questItem and "拾取任务物品 · 静态来源" or "可能掉落启动物品 · 静态来源")
                or step.certainty == "confirmed" and "可接任务 · 当前接取位置"
                or step.point and step.point.source == "client" and "接取待确认 · 曾交互位置" or "接取待确认 · 静态接取位置"
            local reason = not self.carried and ns.Decision.Reason(step)
            GameTooltip:AddLine(status .. (reason and (" · " .. reason) or ""), 1, 0.85, 0.3)
            GameTooltip:AddLine(count > 1 and "合并显示 · 右键不跳过，逐个处理" or "右键跳过任务", 0.6, 0.9, 1)
            GameTooltip:Show()
            return
        end
        GameTooltip:SetText((self.hotspot and (step.index .. self.hotspotLabel .. " 备选热点：") or (step.index .. ". "))
            .. step.title)
        if step.objective then GameTooltip:AddLine(step.objective.text, 0.7, 1, 0.8)
        elseif step.action == "pick_up" then
            local pickupLocation = ns.Util.FormatLocation(self.hotspot or step)
            if pickupLocation then GameTooltip:AddLine(pickupLocation, 0.7, 1, 0.8) end
        end

        -- 状态与位置性质合并一行；静态区域、任务参考位置不表示实时实体坐标。
        local location = step.action == "pick_up" and (step.source == "QuestieDB" and "静态接取位置" or "当前接取位置")
            or step.action == "start_item" and "背包启动物品"
            or step.objective and "静态刷新区域" or "任务参考位置"
        local status
        if not self.hotspot then
            local navigation = step.navigation
            if step.action == "pick_up" then status = step.certainty == "confirmed" and "可接任务" or "接取待确认"
            elseif step.action == "start_item" then status = "使用物品接取"
            elseif step.action == "turn_in" then status = "可交任务"
            elseif step.action == "completion_pending" then status = "已完成，等待确认交付"
            elseif navigation then status = tooltipPhases[navigation.phase] end
            -- 距离并入状态行，不增加行数：1 号显示距玩家，其后显示距上一站。
            local distanceText
            if step.index == 1 then
                local distance = FormatDistance(step.navigation and step.navigation.distance)
                distanceText = distance and ("约" .. distance .. "码")
            else
                local distance = FormatDistance(step.segmentDistance)
                if distance then status, distanceText = status or "后续", "距上一站约" .. distance .. "码" end
            end
            if distanceText then status = status and (status .. " · " .. distanceText) or distanceText end
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
    pin.text:SetText(index .. (delivery and "?" or step.action == "completion_pending" and "~"
        or step.action == "pick_up" and step.certainty ~= "confirmed" and "~!"
        or (step.action == "pick_up" or step.action == "start_item") and "!" or ""))
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
    for index, pin in pairs(view.alternatives) do
        if index > serial then pin:Hide(); pin.step, pin.hotspot = nil, nil end
    end
end

-- 同一地点（同实体同坐标、或世界距离±8码内的重叠NPC）的同类接取建议合并为一个方块。
local function SameSpot(a, b)
    if a.coordinateMapID == b.coordinateMapID and IsFinite(a.x) and IsFinite(a.y)
        and math.abs(a.x - b.x) < 0.0005 and math.abs(a.y - b.y) < 0.0005 then return true end
    local squared = a.world and b.world and ns.Util.DistanceSquared(a.world, b.world)
    return squared ~= nil and squared <= 64
end

-- 把规划快照里的接取建议、已提示地点、带书提示和核验受阻点按地点分组；不创建任何界面元素。
-- 同一任务在 opportunities 与 carriedItems 之间只保留带书提示；每组首项为悬停和点击的代表。
local function GroupOpportunities(plan, mapID, labels)
    local discovery, groups = plan and plan.discovery, {}
    local routed, carriedIDs, seen = {}, {}, {}
    labels = labels or {}
    for _, step in ipairs(plan and plan.steps or {}) do routed[step.questID] = true end
    for _, item in ipairs(discovery and discovery.carriedItems or {}) do carriedIDs[item.questID] = true end
    for _, field in ipairs({ "opportunities", "announcedOpportunities", "carriedItems", "blocked" }) do
        local carried = field == "carriedItems"
        for _, item in ipairs(discovery and discovery[field] or {}) do
            local rejection = labels[item.reason]
            local drop = item.action == "possible_item_drop"
            local point = item.point
            if not routed[item.questID] and (field ~= "blocked" or rejection)
                and (carried or item.action == "pick_up" or drop)
                and not (carriedIDs[item.questID] and not carried and not drop)
                and point and point.coordinateMapID == mapID then
                local key = item.questID .. ":" .. (drop and ("drop:" .. (item.itemID or 0)) or "npc")
                if not seen[key] then
                    seen[key] = true
                    local glyph = rejection and "×"
                        or (drop or item.action == "pick_up" and item.certainty ~= "confirmed") and "~!" or "!"
                    local target
                    for _, group in ipairs(groups) do
                        if group.field == field and group.glyph == glyph and SameSpot(group.point, point) then target = group; break end
                    end
                    if target then target.items[#target.items + 1] = item
                    else
                        groups[#groups + 1] = { field = field, glyph = glyph, carried = carried, rejection = rejection ~= nil,
                            point = point, items = { item } }
                    end
                end
            end
        end
    end
    return groups
end

-- 合并方块在 20×20 内用小号字体显示数量：1-9 带符号，10-99 只显示数字，更多显示 99+。
local function GroupLabel(group)
    local count = #group.items
    if count == 1 then return group.glyph end
    if count <= 9 then return count .. group.glyph end
    return count <= 99 and tostring(count) or "99+"
end

local function RenderOpportunityPins(view, plan, placed, width, height, scale, mapID, origin, radius, cosine, sine)
    view.opportunities = view.opportunities or {}
    local circular, serial = origin ~= nil, 0
    for _, group in ipairs(GroupOpportunities(plan, mapID, ns.Discovery.rejectionLabels)) do
        local point, position = group.point
        if circular then position = MinimapPosition(point.world, origin, radius, cosine, sine)
        else position = ProjectWorld(point.world, mapID) end
        local onEdge = false
        if position and circular then
            local length = math.sqrt(position.x ^ 2 + position.y ^ 2)
            onEdge = length > 0.84
            if onEdge then position = { x = position.x * 0.84 / length, y = position.y * 0.84 / length } end
        end
        if position and (circular or position.x >= 0 and position.x <= 1 and position.y >= 0 and position.y <= 1) then
            serial = serial + 1
            local pin = view.opportunities[serial]
            if not pin then pin = NewRoutePin(view); pin:SetSize(20, 20); view.opportunities[serial] = pin end
            pin.step, pin.group, pin.opportunity, pin.onEdge, pin.carried = group.items[1], group, true, onEdge, group.carried
            local merged = #group.items > 1
            pin:SetSize(merged and 24 or 20, merged and 24 or 20)
            pin.text:SetFontObject(merged and "GameFontNormalSmall" or "GameFontNormal")
            pin.text:ClearAllPoints()
            if merged then
                -- 数量文字用小字体对象、不限字串宽度，避免被截成“…”（客户端字号下限约 14，不再缩小）。
                pin.text:SetPoint("CENTER", pin, "CENTER", 0, 0)
                pin.text:SetWidth(40)
            else pin.text:SetWidth(0); pin.text:SetAllPoints(pin) end
            pin.text:SetTextColor(1, 1, 1)
            pin:SetScale(1 / scale)
            local x, y = position.x * width * scale, position.y * height * scale
            if circular then x, y = position.x * width / 2, position.y * height / 2 end
            local px, py, shifted = SeparatePin(placed, x, y, width * scale, height * scale, circular)
            pin.shifted = shifted
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", view.overlay, circular and "CENTER" or "TOPLEFT", px, circular and py or -py)
            PinLeader(view, #plan.steps + #(view.alternatives or {}) + serial, circular and "CENTER" or "TOPLEFT",
                x / scale, (circular and y or -y) / scale, px / scale, (circular and py or -py) / scale, scale)
            if group.rejection then pin.color:SetColorTexture(0.5, 0.5, 0.5, 0.95)
            else pin.color:SetColorTexture(0.95, 0.75, 0.05, 0.95) end
            pin.text:SetText(GroupLabel(group))
            pin:Show()
        end
    end
    for index, pin in pairs(view.opportunities) do
        if index > serial then pin:Hide(); pin.step, pin.group = nil, nil end
    end
end

ns.MapPins = {
    ProjectWorld = ProjectWorld, Configure = ConfigureRoutePin, New = NewRoutePin, Appearance = SetRoutePinAppearance,
    Separate = SeparatePin, Leader = PinLeader, MinimapPosition = MinimapPosition, RenderAlternatives = RenderAlternativePins,
    RenderOpportunities = RenderOpportunityPins, GroupOpportunities = GroupOpportunities, GroupLabel = GroupLabel,
}
