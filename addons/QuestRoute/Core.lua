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
ns.apiRevision = 14
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

ns.Util = {
    InvalidArguments = InvalidArguments, IsFinite = IsFinite, IsID = IsID, Accessible = Accessible,
    ParsePage = ParsePage, AddPage = AddPage, ToWorld = ToWorld,
    DistanceSquared = DistanceSquared, RouteStepKey = RouteStepKey,
}
