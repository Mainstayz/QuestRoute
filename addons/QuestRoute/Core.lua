-- 插件命名空间、开发桥接和无业务状态的共用工具。
local addonName, ns = ...
WoWBridgeNS = WoWBridgeNS or {}
local previousNS = WoWBridgeNS[addonName]
ns.settingsUI = ns.settingsUI or (previousNS and previousNS.settingsUI)
WoWBridgeNS[addonName] = ns

ns.WB = WoWBridge and WoWBridge.Bind and WoWBridge.Bind(addonName) or {
    Emit = function() end,
    Expose = function() end,
    Request = function(_, _, _, callback)
        callback(nil, "unavailable")
    end,
}
ns.apiRevision = 17
-- 状态只保存在这里；各模块动态读取 ns.route，使换热点的草稿可跨模块生效。
ns.route = ns.route or { views = {}, sequence = 0 }

local function InvalidArguments(message)
    return { ok = false, error = { code = "invalid_arguments", message = message } }
end

local function IsFinite(value)
    return canaccessvalue(value) and type(value) == "number"
        and value == value and value > -math.huge and value < math.huge
end

local function IsID(value)
    return IsFinite(value) and value > 0 and value % 1 == 0
end

local function Accessible(value)
    if canaccessvalue(value) then return value end
end

local function ParsePage(args)
    local offset = args.offset
    local limit = args.limit
    if offset == nil then offset = 0 end
    if limit == nil then limit = 50 end
    if not IsFinite(offset) or offset < 0 or offset % 1 ~= 0 then
        return nil, "offset must be a non-negative integer"
    end
    if not IsID(limit) or limit > 100 then
        return nil, "limit must be an integer from 1 to 100"
    end
    return { offset = offset, limit = limit }
end

local function AddPage(result, all, page, field)
    local out = {}
    for i = page.offset + 1, math.min(#all, page.offset + page.limit) do
        out[#out + 1] = all[i]
    end
    result.total = #all
    result.offset = page.offset
    result.limit = page.limit
    result.count = #out
    result.hasMore = page.offset + #out < #all
    if result.hasMore then result.nextOffset = page.offset + #out end
    result[field] = out
    return result
end

local function ToWorld(mapID, x, y)
    if not IsID(mapID) or not IsFinite(x) or not IsFinite(y) then return nil end
    local ok, continentID, position = pcall(C_Map.GetWorldPosFromMapPos, mapID, CreateVector2D(x, y))
    if ok and position and IsFinite(continentID) and IsFinite(position.x) and IsFinite(position.y) then
        return { continentID = continentID, x = position.x, y = position.y }
    end
end

local function DistanceSquared(a, b)
    if not a or not b or a.continentID ~= b.continentID then return nil end
    return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2
end

local function RouteStepKey(questID, objectiveKey)
    return questID .. ":" .. (objectiveKey or "quest")
end

-- 提示里的距离只取粗略整数：100 码内按 5 码，之外按 10 码；不可读时返回 nil。
local function FormatDistance(distance)
    if not IsFinite(distance) or distance < 0 then return nil end
    local step = distance < 100 and 5 or 10
    return string.format("%d", math.floor(distance / step + 0.5) * step)
end

local function FormatLocation(point)
    if not point or not IsID(point.coordinateMapID) or not IsFinite(point.x) or not IsFinite(point.y)
        or point.x < 0 or point.x > 1 or point.y < 0 or point.y > 1 then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, point.coordinateMapID)
    local name = ok and info and Accessible(info.name)
    local kind = point.entityKind == "object" and "物件" or point.entityKind == "npc" and "NPC"
    local entityName = Accessible(point.entityName)
    local entity = kind and (" · " .. kind .. (type(entityName) == "string" and ("：" .. entityName) or "")) or ""
    return (type(name) == "string" and name or ("地图" .. point.coordinateMapID))
        .. string.format(" %.1f, %.1f", point.x * 100, point.y * 100) .. entity
end

-- 一行轻提示同时留在玩家聊天框，消失后仍可回看。
local function Notify(text)
    print(text)
    local frame = UIErrorsFrame
    if frame and type(frame.AddMessage) == "function" then
        pcall(frame.AddMessage, frame, text, 0.19, 0.81, 0.91, 1, 4)
    end
end

ns.Util = {
    InvalidArguments = InvalidArguments, IsFinite = IsFinite, IsID = IsID, Accessible = Accessible,
    ParsePage = ParsePage, AddPage = AddPage, ToWorld = ToWorld,
    DistanceSquared = DistanceSquared, RouteStepKey = RouteStepKey, FormatDistance = FormatDistance,
    Notify = Notify, FormatLocation = FormatLocation,
}
