# 任务 POI 接口探索

实测环境：2026-11-12，《魔兽世界：无限》1.60.1.70888，Interface 16001，无限工坊 0.9.13。角色重新登录世界后完成；本次未修改 YYQQuestAPI 或其他现有游戏插件的文件。

## 结论

可以用原生 API 获取任务级地图兴趣点，支撑任务升级助手的区域归组、位置参考和近似距离排序。需要正确处理坐标投影和跨地图重复，不能据此承诺逐怪物/物品的全部刷新点。

本次样本：

| 项目 | 实测结果 |
| --- | --- |
| 当前任务 | 22 个 |
| 待交任务 | 5 个 |
| 扫描地图 | 56 张：C_Map.GetMapChildrenInfo(947, nil, true) |
| POI 返回记录 | 69 条 |
| 去重后任务 | 20 个 |
| 其中待交任务 | 5 个均有 POI |
| 同一任务在同一张查询地图上的多条记录 | 本次未发现 |
| 返回的 mapID 与查询地图不同 | 49 条 |
| 跨地图转换后的最大世界坐标偏差 | 约 0.00309 个世界坐标单位 |
| 原始坐标超出 0..1 | 本次未发现 |
| isQuestStart=true | 本次未发现 |
| inProgress=false | 本次未发现，包括待交任务 |

未覆盖的任务为 914“尖牙德鲁伊”和 97932“露营基础：钓鱼”。这里只能判断在本次地图树范围中未找到，不能推断游戏所有地图都不存在它们的 POI。这个地图树不包含所有副本地图。

## 主要读取接口

```lua
local queryMapID = 1413
local pois = C_QuestLog.GetQuestsOnMap(queryMapID) or {}
```

手册标记 call=ok，已在游戏实际调用成功。

每项对应手册结构 QuestPOIMapInfo。实测出现的字段：

- questID、mapID、x、y、numObjectives。
- inProgress、isQuestStart、isDaily、isCombatAllyQuest、isMeta、isMapIndicatorQuest。

文档另外列出可选字段 childDepth、questTagType，本次样本没有这些字段。

可以与任务日志按 questID 关联标题、目标进度和完成状态。isQuestStart 表示结构中的接取标记属性，不能把这次样本解读为已掌握所有可接任务的位置；本次 69 条记录均对应当前日志任务。

## 关键发现：查询地图与返回的 mapID 必须分开保存

返回的 x/y 以**调用 GetQuestsOnMap 时传入的 queryMapID**为坐标系，返回的 poi.mapID 则可能仍是 POI 所关联的原地图。

实测同一任务 881“埃其亚基”：

| 查询地图 | 返回 mapID | x | y |
| --- | --- | --- | --- |
| 1414 卡利姆多 | 1413 | 0.54640502 | 0.50315082 |
| 1411 杜隆塔尔 | 1413 | 0.20397188 | 0.38364050 |
| 1413 贫瘠之地 | 1413 | 0.55893916 | 0.17117482 |

分别用查询地图转换到世界坐标，得到同一位置，约为 continentID=1，x=456，y=-3041。

如果把大陆图返回的 x/y 与 poi.mapID=1413 配对转换，得到的世界坐标约为 (-1786.91, -2913.99)，明显不是同一个点。

推荐保存结构：

```lua
local result = {
    questID = poi.questID,
    coordinateMapID = queryMapID, -- x/y 所属坐标系
    reportedMapID = poi.mapID,   -- 原始 API 返回的关联地图
    x = poi.x,
    y = poi.y,
    source = "C_QuestLog.GetQuestsOnMap",
    precision = "quest_poi",
}
```

x/y 乘 100 才是常见的地图坐标显示值；百分比依然必须与 coordinateMapID 配对。

若需要原地图坐标，可在确认地图有效后重新查询 poi.mapID，并按 questID 找到对应项，而不是仅修改坐标上的地图标签。将 queryMapID==poi.mapID 的记录作为本次样本的原图记录，可提取 20 个无重复任务点；这不应作为永远丢弃其他投影记录的通用规则。

## 地图发现、投影和距离

已核对手册并实测：

```lua
local maps = C_Map.GetMapChildrenInfo(947, nil, true) or {}
local info = C_Map.GetMapInfo(uiMapID)
local currentMapID = C_Map.GetBestMapForUnit("player")
local playerPosition = C_Map.GetPlayerMapPosition(currentMapID, "player")

local continentID, worldPosition = C_Map.GetWorldPosFromMapPos(
    queryMapID,
    CreateVector2D(poi.x, poi.y)
)
```

上述 C_Map 函数手册 call=ok。CreateVector2D 在手册搜索中没有条目，已先检查游戏内 type 为 function，再用于实测。

注意：

- 本次艾泽拉斯地图树有 56 个后代，包含两块大陆、地区图和战场图；并非包含全部副本。
- 查询根地图 947“艾泽拉斯”本身返回空，查询 1414“卡利姆多”有 18 条；不能指望仅查最高层地图就拿到全部任务点。
- 当前玩家在 1456“雷霆崖”，该图返回空；其他任务地图仍可查询，不要求玩家亲自到达。
- 周边地区图也可能包含相同任务的投影记录。查询某地图有任务点，不表示该任务物理上位于该区域的行政边界内。
- 转到相同 continentID 的世界坐标后才能估算跨地区直线距离；不同 continentID 的坐标不能直接相减比较。
- 直线距离不是实际可通行距离，仍有山体、洞穴、地图层级和交通等问题。
- GetQuestsOnMap 不要求修改 C_QuestLog 的当前 POI 地图。正常读取时无需调用 SetMapForQuestPOIs。

## 当前任务的原图 POI 样本

下表坐标来自 queryMapID==poi.mapID 的记录，显示为 0..100。它们是 API 当前任务点，不是经过逐个到现场验证的实体刷新坐标。

| 任务 ID | 任务 | 地图 | X | Y |
| --- | --- | --- | --- | --- |
| 1491 | 智慧饮料 | 1413 贫瘠之地 | 47.70 | 32.85 |
| 962 | 毒蛇花 | 1413 贫瘠之地 | 47.52 | 33.44 |
| 959 | 港口的麻烦 | 1413 贫瘠之地 | 46.34 | 34.58 |
| 3921 | 维妮·布特巴克 | 1413 贫瘠之地 | 49.06 | 11.17 |
| 881 | 埃其亚基 | 1413 贫瘠之地 | 55.89 | 17.12 |
| 896 | 矿工的宝贝 | 1413 贫瘠之地 | 60.51 | 3.86 |
| 852 | 赫兹鲁尔·血印 | 1413 贫瘠之地 | 46.14 | 36.92 |
| 899 | 复仇的怒火 | 1413 贫瘠之地 | 43.95 | 51.31 |
| 95774 | 她的名字叫奥格拉 | 1413 贫瘠之地 | 49.44 | 51.65 |
| 92706 | 通缉：布鲁兹 | 1413 贫瘠之地 | 65.89 | 40.03 |
| 878 | 野猪人的内战 | 1413 贫瘠之地 | 41.87 | 46.41 |
| 868 | 蝎卵 | 1413 贫瘠之地 | 45.23 | 70.93 |
| 97250 | 错怪无辜，罪有应得 | 1413 贫瘠之地 | 49.07 | 76.96 |
| 822 | 老陈的空酒桶 | 1413 贫瘠之地 | 41.89 | 22.24 |
| 893 | 野猪人的武器 | 1413 贫瘠之地 | 41.60 | 80.10 |
| 6543 | 战歌报告 | 1440 灰谷 | 71.08 | 67.46 |
| 1060 | 写给金吉尔的信 | 1442 石爪山脉 | 74.54 | 97.92 |
| 1483 | 菲兹克斯 | 1442 石爪山脉 | 58.99 | 62.61 |
| 3301 | 茉拉·符文图腾 | 1421 银松森林 | 42.90 | 41.99 |
| 264 | 至死方休 | 1421 银松森林 | 44.19 | 42.67 |

## 完成状态与点的含义

所有 5 个待交任务都有点，但 inProgress 仍然是 true。因此不能用 inProgress 推断目标尚未完成，也不能用 numObjectives==0 来判断任务完成。

使用以下任务读取 API 判断状态：

- C_QuestLog.IsComplete(questID)。
- C_QuestLog.IsFailed(questID)。
- C_QuestLog.ReadyForTurnIn(questID)。

当前结果没有给每个点提供明确的目标 NPC ID、物品 ID、objectiveIndex 或“这是交付点”的类型枚举。待交任务的 POI 可以保留用于显示，但尚未验证每个点都是精确的交付 NPC 位置，产品中要标注位置来源和精度。

## 逐目标兴趣点与区域轮廓的探索

手册提供 QuestPOI:UpdateMouseOverTooltip(x,y)、GetNumTooltips()、GetTooltipIndex(index)，还有 Blob 的绘制方法。

探索过程及边界：

- 直接 CreateFrame("QuestPOI") 在本构建失败，错误被 pcall 捕获。
- 只读检查现有地图的子框体，确认实际对象类型是 QuestPOIFrame。
- 可以创建自己的匿名 QuestPOIFrame；未打开或修改暴雪地图面板。
- 使用自己的无填充、无边框测试框体试过 DrawAll、单独 DrawBlob(878,true)、归一化采样、像素采样和跨帧等待，命中查询均未返回具体目标索引。
- 测试时曾短暂切换内部 POI 数据上下文，结束后已恢复原值 1456；所有测试框体均隐藏并停止绘制。

这说明本次尚未验证一条可用的逐目标提取路径，不能由此宣称这些 widget 方法在所有状态都不可用。尤其不能通过网格采样结果冒充完整的区域多边形或精确刷新数据库。

## 其他导航接口

在本次角色重新登录后重新测试：

- C_QuestLog.GetNextWaypoint：当前 22 个任务均无结果。
- C_QuestLog.GetNextWaypointText：当前 22 个任务均无结果。
- C_QuestLog.GetNextWaypointForMap：之前对任务所在地图的样本也没有结果。
- C_TaskQuest.GetQuestLocation：对当前普通任务与贫瘠之地地图的调用无坐标。

这些函数手册标记 call=ok，但不能据存在与否推断有可用数据；普通任务定位优先使用已经实测有效的 GetQuestsOnMap。

## 对升级助手的实现建议

下一步可以封装 get_quest_pois({mapID=...})，同时返回 coordinateMapID、reportedMapID、任务状态、来源和精度。它属于后续开发，本次尚未实现。

规划时按 questID 和实际物理位置去重；本次同一任务只有一个物理点，但以后若出现多个真实位置，不能仅按 questID 全部合并。

在单大陆内可用世界坐标估算距离和按区域分组。任务无 POI 时仍保留在任务列表，并提示位置缺失。

逐目标怪物/物品的刷新点、区域轮廓和完整交付点数据仍需任务数据库或进一步验证。

## 验证状态

所有有效读取与最终采样的 try.ok=true；最后检查 ERR/BLOCKED 日志为空，截图未见操作拦截弹窗。匿名探索框体没有保留可见界面，也没有创建新的常驻轮询。
