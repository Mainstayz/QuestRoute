# QuestieDB 接入验证

2026-11-12，在《魔兽世界：无限》1.60.1.70888 / Interface 16001 / 无限工坊 0.9.13 中验证。

结论：**可以通过公开 Lua API 只读查询，适合在客户端原生数据缺失时补充任务实体、静态刷新点、接交对象和任务链。**本次没有修改 QuestieDB 或现有任务插件的文件，也没有注册修正、修改语言或导入数据库副本。

## 用户明确的数据源优先级

优先使用客户端原生数据。具体采用以下规则：

1. 当前角色任务列表、完成状态、目标数量及实际目标说明，以客户端 C_QuestLog 查询为准。
2. 客户端提供的任务 POI 作为主要任务位置参考，按正确的查询地图坐标系处理。
3. 原生 API 缺少逐目标实体、静态刷新位置、任务链或接交对象关系时，再查询 QuestieDB。
4. 保留来源、版本、位置含义、坐标系和精度。同语义的冲突优先采用原生数据；任务区域 POI 和某个 NPC 的刷新点属于不同语义，可分别保存。
5. 原生 API 解码的 QuestieDB 内容仍是第三方数据，不能标为官方。

## 已安装与运行时状态

| 项目 | 实测值 |
| --- | --- |
| 插件目录 | C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\QuestieDB |
| 版本 | 1.0.15 |
| Flavor | Forever |
| Interface | 16001 |
| 读取模式 | baked |
| API contract | 4，RequireContract(4) 返回 true |
| 当前语言 | zhCN |
| 当前日志任务覆盖 | 22/22 个任务 Exists=true |

第一次检查时 C_AddOns.GetAddOnInfo 返回 reason=MISSING，相关全局均为 nil。用户已完整退出并重新启动游戏；之后已实测 loaded=true，相关公开 API 均存在并可调用。

该版本将约 17 MB 的编码数据放在 QuestieDB_Camelot.toc / QuestieDB_Forever.toc 的元数据中，使用 C_AddOns.GetAddOnMetadata 和 C_EncodingUtil 读取。首次安装需要完整重启，Lua 热加载不能补齐启动时未读入的元数据。

## 正式入口与调用习惯

全局 LibQuestieDB 提供以下模块，另有全局别名：

| 模块 | 别名 | 用途 |
| --- | --- | --- |
| LibQuestieDB.Quest | QuestDB | 任务、目标实体、接交对象、前置与后续 |
| LibQuestieDB.Npc | NpcDB | NPC 名字、等级、刷新点、路径 |
| LibQuestieDB.Item | ItemDB | 物品名称、掉落 NPC、掉落物件、容器与商人 |
| LibQuestieDB.Object | ObjectDB | 游戏物件名称、刷新点、接交任务 |

这些 getter 使用**点调用**，不是冒号调用。

```lua
local db = LibQuestieDB
if not db then
    return { available = false, reason = "QuestieDB not loaded" }
end
local compatible, reason = db.RequireContract(4)
if not compatible then
    return { available = false, reason = reason }
end
if not db.Quest.Exists(questID) then
    return { available = false, reason = "quest not in database" }
end

local objectives = db.Quest.objectives(questID)
local starters = db.Quest.startedBy(questID)
local finishers = db.Quest.finishedBy(questID)
local prerequisite = db.Quest.preQuestSingle(questID)
local nextQuest = db.Quest.nextQuestInChain(questID)
```

也支持：

```lua
local title = db.Quest.Get(questID, "name")
local fields = db.Npc.GetAll(npcID, { "name", "spawns", "waypoints" })
local owner = db.GetProvenance("Npc", npcID, "spawns")
```

GetAll 返回带 n 的位置数组，n 为请求字段数，nil 槽位会保留在计数中；对外提供 JSON 时宜再包装成命名字段。

目前 QuestieDB 没有绑定 WoWBridge 句柄，也没有直接公开 Expose 函数。本次由受控 try 代码调用其公开 API 完成验证。若后续需要稳定的 MCP 查询入口，可由自己的适配层包装，不修改 QuestieDB。

自己的插件接入时可将 QuestieDB 加入 OptionalDeps，并做缺失、契约版本和字段形状检查。修改 .toc 后需要用户完整重启以保证正常加载顺序；不能把数据库存在视作升级助手启动的必要条件。

## 任务到实体的关系

objectives 是六组位置结构：

1. creature：NPC/生物关联。
2. object：游戏物件关联。
3. item：物品关联。
4. reputation：声望关联。
5. kill-credit：击杀归属关联。
6. spell：法术关联。

前三组中的条目首项是实体 ID。组别和排列不是已验证的客户端 objectiveIndex，不能直接与官方目标序号一一配对；creature 关联也不能一律解释为需要击杀该 NPC。

startedBy 的组别为 NPC、游戏物件、物品；finishedBy 为 NPC、游戏物件。交付点不能只遍历 NPC。

物品目标可依次查：

```lua
local npcIDs = db.Item.npcDrops(itemID)
local objectIDs = db.Item.objectDrops(itemID)
local containerIDs = db.Item.itemDrops(itemID)
local vendors = db.Item.vendors(itemID)

local npcLocations = db.Npc.spawns(npcID)
local objectLocations = db.Object.spawns(objectID)
```

需处理 nil、空表、多个来源及循环容器关系；不要因为某条链无坐标就把整个任务丢掉。

## 已实测的样本

### 任务 881：埃其亚基

公开 getter 得到：

- 目标物品 5100“埃其亚基的皮”。
- 物品的 npcDrops 返回 NPC 3475“埃其亚基”。
- NPC spawns 返回 AreaID 17，位置 55.86，17.19。
- AreaID 17 映射为 UIMapID 1413“贫瘠之地”。
- 客户端原生任务 POI 为同地图约 55.89，17.12，与静态点接近。
- 任务交付对象为 NPC 3338“瑟格拉·黑棘”，静态点约 52.23，31.01；它与做任务的目标位置分别保存。
- preQuestSingle 返回 {903}，nextQuestInChain 返回 905。该结果仅说明数据库关系，不代表后续任务当前一定可接。

### 任务 92706：通缉：布鲁兹

- 任务、中文标题和物品目标均存在。
- startedBy 中有游戏物件 3972“通缉”。
- Object.spawns 返回 AreaID 17，位置 62.59，37.47。

这是任务接取物件的位置，不能当作目标怪“布鲁兹”的刷新点。

### 任务 914：尖牙德鲁伊

之前扫描原生地图树未获得任务 POI，但数据库有任务、目标物品和掉落 NPC 关系：

| 物品 | 掉落 NPC | 数据库位置情况 |
| --- | --- | --- |
| 9738 考布莱恩宝石 | 3669 考布莱恩 | AreaID 718，点 (-1,-1) |
| 9739 安娜科德拉宝石 | 3671 安娜科德拉 | NPC 存在，未返回 spawns/waypoints，zoneID=0 |
| 9740 皮萨斯宝石 | 3670 皮萨斯 | AreaID 718，点 (-1,-1) |
| 9741 瑟芬迪斯宝石 | 3673 瑟芬迪斯 | AreaID 718，点 (-1,-1) |

AreaID 718 是哀嚎洞穴。(-1,-1) 仅表示位于副本，不能画成地图坐标。映射表兼容别名给出 UIMapID 279，但本机 C_Map.GetMapInfo(279) 无有效地图，不能据此生成副本内精确导航。

**该样本证明任务条目完整不等于位置完整。**可以说明“掉落首领在哀嚎洞穴”，但不能宣称已经拿到首领房间坐标。

### 任务 97932：露营基础：钓鱼

- 数据库存在该无限任务和中文标题。
- creature 组关联 NPC 5938“尤萨恩·静水”，该 NPC 也是任务交付对象；刷新点为 AreaID 215，约 44.16，63.80。
- 客户端实际目标是“将钓鱼技能提升至20”，objectiveType=14，type=object。
- 数据库关联不能解释为击杀训练师，也不能把 requiredSkill 的可接要求当作客户端的完成要求。行为说明以官方目标为准。

### 待交任务

以下静态交付 NPC 点与此前原生任务 POI 接近：

| 任务 ID | 交付对象 | 数据库区域与位置 |
| --- | --- | --- |
| 3921 | 9316 维妮·布特巴克 | AreaID 17；49.05，11.17 |
| 3301 | 8385 茉拉·符文图腾 | AreaID 130；42.91，41.99 |
| 1060 | 3995 巫医金吉尔 | AreaID 406；74.54，97.94 |
| 1483 | 4201 菲兹克斯 | AreaID 406；58.99，62.60 |

任务 264“至死方休”的 finishedBy 则是游戏物件 24776“尤瑞夫的墓碑”，验证了交付对象不一定是 NPC。

这些是接口和数据之间的交叉检查，尚未逐个到现场验证。

## 坐标与地图适配

- spawns 的键是 AreaID，不是 UIMapID。
- spawns[areaID] = {{x,y,phase?}, ...}；坐标为 0..100 百分比。传给要求 0..1 的地图函数前除以100。
- waypoints[areaID] 比 spawns 多一层路径数组，路径点没有 phase。
- (-1,-1) 是副本位置哨兵；未知位置不能转换为 (0,0)，而 (0,0) 本身可能是有效点。
- 地图表来自 LibQuestieDB.Support.Get("ZoneDB").private，包含 areaIdToUiMapId、areaIdToUiMapIdOverride 及反向映射。
- **这些映射字段在当前版本是数据字符串，不是映射表。**直接用 areaIdToUiMapId[17] 不会得到结果。

本次用受限数字匹配读取映射，没有执行数据字符串：

```lua
local zone = db.Support.Get("ZoneDB").private
local areaToMap = {}
for _, text in ipairs({zone.areaIdToUiMapId, zone.areaIdToUiMapIdOverride}) do
    for line in text:gmatch("[^\r\n]+") do
        local area, map = line:match("^%s*%[(%d+)%]%s*=%s*(%d+)")
        if area then areaToMap[tonumber(area)] = tonumber(map) end
    end
end
```

已实测：17→1413，215→1412。必须再用 C_Map.GetMapInfo 验证目标地图可用。

正向映射包括子区域到祖先图的多对一对应，只决定显示地图，不自动重投影坐标。不能只用反向表的主 AreaID 筛选所有刷新点，否则会漏掉子区域组。

LibQuestieDB.EraToForever / EraToForeverByUiMapId 是显式转换助手。它们不自动判断源坐标，已经是 Forever 的数据不能重复转换。其历史转换参数及地图表审阅版本早于当前 build；不能据此保证所有新增地区均已同步。

## 读取与性能建议

- 按当前任务 ID 做小范围查询，不在每次刷新时遍历 GetAllIds 或触发 IdsByName 的全量名称索引。
- 优先使用合成 getter，应用当前修正与语言；GetRaw 在 baked 模式下也已经包含烘焙的静态修正，并非原始官方数据。
- 数据库返回表按契约是每次独立副本；调用方仍无需写回任何内部结构或调用 SetCorrection。
- 地图映射可由适配层解析并缓存，版本或数据库实例变化后重建。
- 将关系缺失、坐标缺失、副本哨兵、未知地图分别表达，避免统一变成“任务不存在”。

## 当前验收范围

已验证插件正常加载、契约兼容、中文数据可用、22个日志任务覆盖、物品到NPC关系、NPC刷新点、物件刷新点、任务链读取、地图映射及缺失坐标处理。有效查询 try.ok=true，最后检查 ERR/BLOCKED 为空。

以上是最初接入能力验证时的范围；后续已在YYQQuestAPI中新增get_quest_details/get_database_entity，r9进一步加入get_quest_targets及有条件逐目标导航，详见逐目标导航调研与实现.md。普通数据库references仍不声明官方目标序号对应，新接口用同任务/同类型/客户端完整格式与实体全名的精确唯一关联，公开mapping依据，未知回原生POI。

当前r9已验证878三种怪95个静态点、822真实已完肝脏不再生成点且剩余两种材料58点、868物品→物件来源等。第3槽图标不是数量；特殊组、歧义、缺直接来源和未知phase都保守回退。未改QuestieDB文件或注册数据库修正。
