# QuestRoute 使用与 API

《魔兽世界：无限》当前任务路线与数据插件，在原生 M 地图、小地图绘制导航，并提供任务怪姓名板提示。安装、旧配置迁移和快速上手见根 [README](../../README.md)。

当前 `apiRevision=15`、`schemaVersion=1`，16 个 Lua 文件按 `QuestRoute.toc` 顺序加载。统一标识为 `QuestRouteDB`、`WoWBridgeNS.QuestRoute`、工坊 `addon="QuestRoute"`；命令 `/questroute` 和 `/questrouteapi`，不提供旧名称的运行时别名。

[开发进度](../../开发进度.md)记录最近验证与部署状态，[待办事项](../../待办事项.md)记录尚未完成的实机验收。[技术说明](../../docs/技术说明.md)解释数据、坐标与规划边界，[MODULES.md](MODULES.md)说明源码职责。

## 地图与设置

路线只安排当前已接、有效且位于玩家当前地图的任务。进行中默认过滤副本、精英、专业；原生 **选项 → 插件 → QuestRoute** 提供三个复选框：精英任务、屏幕提示、任务怪姓名板。精英开关可单独放开未完成精英任务，屏幕提示和姓名板默认开启。整项官方完成后，上述类型均可顺路交付，手动跳过和失败仍优先。

- 青色编号和直线为路线，橙色 1 号是下一步；可交任务用金色 `N?`，已完成待确认用 `N~`。
- 每个可靠未完目标各一步，一个主热点和最多两个紫色 `Nb/Nc` 备选。备选不增加路线步数或里程。
- 普通右键跳过整项任务；Shift + 右键备选切到所点热点，Shift + 右键主点选择该目标其他地点。
- 小地图显示附近线路，视野外仅当前 1 号在边缘指方向；大地图关闭后仍工作。浏览其他地图不改变规划范围。
- 同地点编号作像素避让，以细线指向实际位置，不改导航坐标。

悬停最多四行（含标题），大地图与小地图共用：

```text
1. 野猪人的内战
刺背寻水者：5/6
赶路中 · 静态刷新区域
右键跳过任务 · Shift+右键换地点
```

备选明确标注，交付与待确认状态分开；保留“静态刷新区域”或“任务参考位置”的精度说明，不展开奖励、同组清单或算法统计。

姓名板功能默认启用，玩家自行开启敌方姓名板（默认 `V`）。黄色“! 击杀 2/6 · 材料 1/5”表示仍有已确认用途，关联当前路线目标时为橙色。覆盖所有有效未跳过任务，击杀够数但材料仍缺时继续提示；未知、身份受限或无可靠用途时隐藏，不将其判成确定无关。

原生设置页的三个复选框默认值：精英关闭，屏幕提示与任务怪姓名板开启，切换后立即重排；跳过记录、移动阈值、总显示、姓名板和精英选项按服务器/角色保存在 `QuestRouteDB.routes`，正常退出或重载时由客户端写盘。工作计时与地点避让仅存本次 UI 内存。

## 命令

路线处理器为 `SlashCmdList.QUESTROUTE`，只读列表处理器为 `SlashCmdList.QUESTROUTEAPI`。

| 命令 | 作用 |
| --- | --- |
| `/questroute` | 状态与命令提示 |
| `/questroute skip 852` | 跳过指定任务及其全部目标 |
| `/questroute unskip 852` | 恢复指定任务 |
| `/questroute unskip all` | 恢复全部手动跳过 |
| `/questroute distance 150` | 移动重排阈值设为 150 码，范围 10..5000，默认 100 |
| `/questroute replan` | 解除本轮保持，按当前位置重新选择 1 号并归组 |
| `/questroute on`、`/questroute off` | 开启、关闭地图和任务标识总显示 |
| `/questroute nextspot [ID]` | 为当前 1 号或指定任务换同一未完目标的地点；ID 为任务 ID |
| `/questroute resetspots [ID/all]` | 清全部或指定任务的临时地点避让，省略等同 all |
| `/questroute nameplates on`、`/questroute nameplates off` | 单独控制任务姓名板提示 |
| `/questroute notice on`、`/questroute notice off` | 开关屏幕上方的一行切换提示（默认开） |
| `/questroute why` | 前三步给出距离与有效权重，再列出未上路线的任务及原因；本图做完时给出下一张地图 |
| `/questrouteapi` | 只读显示当前任务列表 |

换地点后旧点 150 码内避开 600 秒；无备选或状态失效时保留原路线、计时与任务跳过。清地点避让不会恢复手动跳过的任务。

`why` 的前三行形如 `1. 滚岩峡谷 — 距离 415 码（有效权重 1.25）`：有效权重是难度/奖励与剩余数量修正后的合成权重，同组加成生效时额外标出 `含同组加成`，剩余数量修正不为 1 时标出 `剩余×N`。它只重排已有字段，不参与规划。

## 调用方式与共用约定

无限工坊通过 `mcp__wuxian__call` 传数据：

```json
{"addon":"QuestRoute","name":"get_quests","args":{}}
```

工具答案的 `result` 是函数返回值。其他插件在依赖中声明 `QuestRoute`，待加载后可直接调用 Lua：

```lua
local api = WoWBridgeNS and WoWBridgeNS.QuestRoute
if api and api.GetQuests then
    local result = api.GetQuests({ limit = 100 })
    if result.ok then
        for _, quest in ipairs(result.quests) do
            print(quest.questID, quest.title, quest.status)
        end
    end
end
```

共用约定：

- `offset` 从 0 开始，非负整数；`limit` 为 1..100。`get_quests` 默认 100，其他分页接口默认 50。
- 分页结果用 `total/count/hasMore/nextOffset`；最后一页省略 `nextOffset`。分页期间日志可能变化，需要一致列表时优先一次读完。
- ID 为正整数；地图参数必须为当前客户端有效地图。可选或不可访问的字段省略，不填虚构值。
- 无效参数返回 `{ "ok": false, "error": { "code": "invalid_arguments", "message": "..." } }`。
- 原生任务状态与进度优先，第三方关系和静态位置分别标注来源、版本与精度。直线距离不表示道路可通行。

## 任务数据接口

### get_quests / GetQuests

参数：`{offset?,limit?,includeObjectives?}`，`includeObjectives` 默认 true。

返回当前角色已接任务，包含折叠分类、可枚举隐藏任务及完成待交任务，不含已交历史或尚未接取任务。主要字段：

- 顶层：`ok/schemaVersion/scope="active_quest_log"`、`character`、`total/reportedTotal/logComplete` 与分页。
- 任务：`questID/title/category/logIndex/level/suggestedGroup/frequency/classification`、隐藏/任务/剧情标志、`isComplete/isFailed/readyForTurnIn/status`，可选原生 `tag={id,name,isElite?,tradeskillLineID?}`。
- 目标：`objectivesLoaded` 与 `objectives[]`，含 `index/text/type/objectiveType/finished/numFulfilled/numRequired`。

`logComplete` 比较枚举数与客户端报告数，和分页是否结束无关。`status` 为 `in_progress/ready_for_turn_in/complete/failed`；`complete` 表示官方已完成但尚未标为可交。`finished` 决定子目标完成，不靠计数推断；目标表已加载也不保证实体名称都已就绪。`includeObjectives=false` 时省略目标表和加载标志。

### get_player_context / GetPlayerContext

参数 `{}`。返回 `character`（可访问的姓名、服务器、阵营、等级）、`experience`（current/maximum/rested，可选 fraction）与 `location`。

位置含 `available/coordinateMapID/mapName/x/y` 和可选 `world={continentID,x,y}`；不可用时给 reason。不读取生命或能量。

### get_quest_pois / GetQuestPOIs

参数 `{mapID?,questID?,offset?,limit?}`。指定地图只查该图，省略时扫描艾泽拉斯 947 的后代地图，`mapScope` 描述范围，不保证副本全覆盖。只返回当前日志任务，不在日志时结果为空且 reason 为 `quest_not_in_log`。

过滤、投影去重与稳定排序后分页；`total` 为去重后数量，`rawCount` 为合并前数量，`unusableCount` 为无可用原始坐标数。POI 含：

`questID/coordinateMapID/reportedMapID/x/y/units="normalized"/source/precision="quest_poi"/projectionCount/queryMapIDs/worldAvailable`，可选 `world` 或 `worldUnavailableReason`。

**x/y 属于 coordinateMapID，reportedMapID 是关联地图。** 同大陆世界坐标才可比较；`inProgress` 和 `numObjectives` 不代表完成状态。位置会随状态变化，不能永久缓存。

### get_quest_details / GetQuestDetails

参数 `{questID,allowDatabase?,includePOIs?,offset?,limit?}`。两开关默认 true；分页只作用于数据库 references。

返回 `policy="client_first"`，数据分为：

- `official`：source 为 client，available/inLog，当前日志任务，以及可选 pois/poiCoverage/poiRawCount。不在日志时明确不可用，不虚构当前进度。
- `database`：QuestieDB 来源、版本与契约、元数据、chain、references 分页及特殊目标关系；缺失/关闭/不兼容/读错时给 available=false 和 reason，保留原生部分。

references 的 role 为 `quest_start/quest_turn_in/objective_reference`，kind 为 npc/object/item。`databaseGroup/databaseIndex` 是数据库位置，`objectiveIndexMapping="not_inferred"`，不等于官方目标序号；生物关联不一定是击杀。chain 不保证后续当前可接，0 值 ID 不用于继续查询。此接口不递归展开全部实体位置。

### get_database_entity / GetDatabaseEntity

参数 `{kind,id,offset?,limit?}`，kind 为 npc/object/item。

- item 返回直接掉落、容器或商人 `relations`，按单条关系分页，不递归容器。
- npc/object 返回扁平 `locations`，不可导航记录也参与分页。`total` 为全部位置数，`usableLocationTotal` 为有可用地图坐标的数量；`locationAvailability` 为 available/missing/unusable。
- 位置保留 AreaID、spawnIndex、originalX/originalY（0..100）、可选 phase，统一提供 0..1 x/y、coordinateMapID、地图名与可选 world。
- 副本 `(-1,-1)` 标为 `instance_only`，缺映射、无效坐标和客户端不支持地图分别给原因；合法 `(0,0)` 保留。available 不保证实体在场或当前相位可见。

数据库缺失返回 `ok=true,available=false,reason="not_loaded"`，实体不存在为 `entity_not_found`，读取异常为 `ok=false,error.code="database_error"`。

### get_quest_targets / GetQuestTargets

参数 `{questID,mapID?,allowDatabase?,offset?,limit?}`，allowDatabase 默认 true；false 仅关闭本次查询补充，不改路线偏好、跳过或计划。

返回 `policy="client_progress_database_static_locations"`、`mode="objective_locations"` 或 `native_poi`、reason、progressSource/locationSource/databaseVersion、完整官方 `objectives`、objectivesLoaded/mappingComplete、remainingCount 与 targets 分页。

只有同任务、同类型、客户端完整文字格式与数据库全名构成唯一双射时，官方快照才附加 key/kind/id/name/mapping；mapping 为 `task_scoped_exact_localized_text`。不按数组序号或模糊名称匹配。特殊关系、歧义、缺数据、无直接来源或位置不可用时回退，官方进度仍完整返回。

细目标点含 objectiveKey/objective、entityKind/entityID/relation、source/precision、地图坐标与 world。回退时 targets 为原生 POI。`mappingComplete` 只表示身份映射完整，应以 mode 判断细导航是否启用。静态点不表示实体实时位置；物品只追一层直接 NPC/物件掉落。

## 规划与操作接口

### get_plan / GetPlan

参数 `{}`，返回当前路线快照：

| 字段 | 含义 |
| --- | --- |
| policy / scope | `stable_grouped_leveling_straight_line` / `current_player_map_active_quests` |
| sequence / origin / mapID / mapName | 规划序号、原点和玩家地区 |
| totalStraightDistance / reason / plannedAt | 路线直线总长、重建原因与本 UI 内的规划时间 |
| count / questCount | 目标/交付步骤数、去重任务数 |
| objectiveStepCount / nativeStepCount | 细目标与原生步骤数；stepUnit 为 `unfinished_objective_or_quest` |
| turnInCount / completionPendingCount | 可交与完成待确认步骤数 |
| steps / excluded | 有序步骤与被排除任务及原因 |
| groups / groupRadius | 固定中心分组，半径 200 码 |
| stability / navigation | 当前目标保持结果与导航状态 |
| levelPriority / levelingPriority | 难度/经验策略、参照与缓存重试摘要 |
| objectiveResolution / pendingObjectiveCount / objectiveRetrySeconds | 细目标采用/回退与暂缺重试 |
| pendingLocationCount / locationRetrySeconds | 原生位置暂缺重试 |
| hotspotRules / spotRules / avoidedSpots | 热点、临时避让规则与记录 |
| enabled / moveThreshold / includeEliteQuests / switchNotice / nameplates | 当前选项和姓名板解析摘要 |
| nextMapHint | 仅当前地图无步骤、有外图任务、玩家世界坐标可用且无等待恢复的位置/目标数据时存在：`questID/title/mapID/mapName`，只是提示，不跨图规划 |

steps 保留 index/questID/title/level/status/action、stepKey/displayTitle/questStepCount、targetMapID、地图/world 坐标、source/precision、segmentDistance、priorityWeight/weightedDistance（含自由选点时的有界任务群加成）、workFactor/remainingWork（剩余数量对权重的 0.9~1.1 修正，缺数据为 1）、priority、groupIndex/groupSize/groupQuestCount、objectiveRevision/objectivesAvailable 和 navigation。action 为 quest_area/turn_in/completion_pending，表示步骤类型；navigation.phase 表示当前执行状态。细目标另带 objectiveKey/objective、entityKind/entityID/relation、locationVersion、targetMode/targetReason；显示标题与计数不改变任务原始标题。

excluded 每项含 questID/title/reason/source；reason 为 `outside_current_map` 时另有 otherMapID/otherMapName/otherDistance（离玩家最近的外图位置）。

groups 的 count 为步骤数、questCount 为任务数，questIDs 去重。stability 含 retained/reason、previousQuestID/questID、previousObjectiveKey/objectiveKey 和可选 lastProgressAt。奖励样本与读取按任务计一次。levelPriority 保留 referenceLevel，perLevelBonus=0、maxWeight=1.25、method 为 client_difficulty_and_reward；levelingPriority 提供难度权重、经验参照、阈值及 pendingRewardCount/rewardRetrySeconds。每步 priority 描述来源、可用性与因子，未知经验不按零处理。

steps[].hotspots 第一项为 selected=true 的主点，其余最多两个备选，含 id/selected/pointCount/radius/sparseFallback/x/y/world/coordinateMapID/targetMapID/source/precision=static_hotspot。hotspotRules 为 radius150/separation300/maxDisplayed3/deduplicateRadius3，algorithm 为 fixed_radius_density_real_spawn，alternativesJoinRoute=false。pointCount 不是实时怪数。

navigation.phase 为 travel/working/turn_in/completion_pending/idle/unavailable，后续步骤为 queued。当前状态含 phase/label/reason、questID/questStatus/objectiveKey/objective、mapID/targetWorld、distance/atReference、observedAt/since；工作时还可有 workStartedAt/lastProgressAt/idleFor/stale/protected/objectivesAvailable/objectiveRevision。不可读字段省略。

navigationRules 为进入120/退出180码、进度300码/90秒、无进度超时180秒。状态每0.5秒更新；超时释放强保护，自动切换仍需改善30%且减少50加权码。turn_in 只证实日志可交，deliveryLocationConfirmed=false，locationPrecision=quest_poi。完整规则见[技术说明](../../docs/技术说明.md)。

### 路线操作

| 工坊 name / Lua 函数 | 参数与结果 |
| --- | --- |
| `replan` / `Replan` | `{}`；主动重排，绕过当前保持和旧组延续 |
| `set_quest_skip` / `SetQuestSkip` | `{questID,skipped?}`；默认 true，false 恢复，不放弃任务 |
| `reset_quest_skips` / `ResetQuestSkips` | `{}`；清当前角色全部任务跳过 |
| `set_route_options` / `SetRouteOptions` | `{moveThreshold?,enabled?,nameplatesEnabled?,includeEliteQuests?,switchNotice?}`；后四项必须 boolean，精英默认 false、姓名板和切换提示默认 true，立即重排并按角色保存 |
| `change_quest_spot` / `ChangeQuestSpot` | `{questID?,objectiveKey?,hotspotID?}`；省略取1号，key需questID，hotspotID需同时带questID/key，来自当前 hotspots[].id |
| `clear_spot_avoidances` / `ClearSpotAvoidances` | `{questID?}`；省略清全部，返回重排计划，不改任务跳过 |
| `get_unit_tasks` / `GetUnitTasks` | `{unit?}`；默认 target，仅接受 target/mouseover/nameplateN，只读当前单位任务用途 |

change_quest_spot 成功返回 questID/objectiveKey/selected/expiresAt/avoidedRadius/duration；无备选、交付/原生点、失效 key、过期热点、目标或地图变化时返回错误，保留原路线和计时。省略 hotspotID 选择该目标其他最近区域。

get_unit_tasks 返回 state/needed、可读 npcID、tasks、neededCount/knownGoalCount/unresolvedQuestCount，可选 label/currentTarget 和来源/时间。state 为 needed/no_remaining_known_goals/no_known_match/unknown/not_eligible；无已知匹配不证明绝对无关。tasks 保留官方计数、finished、relation=kill/direct_item_drop、mapping、progressSource/relationSource。任务数据待合并时为 unknown，reason=quest_data_updating；身份受限不延用旧 ID。

## 事件、维护与验证

WoWBridge 事件由工坊 `events` 读取，addon 为 QuestRoute：

- `api.ready`：API 已就绪，含 schemaVersion/apiRevision。
- `route.updated`：路线重建，含 sequence/mapID/count/questCount/reason。
- `route.navigation_changed`：当前目标、阶段或保护语义变化，含 questID/objectiveKey、phase/reason/protected/stale/distance/mapID；不逐帧发送位置。
- `route.spot_changed`：成功手动换点的任务、目标、地图与到期信息。

修改 Lua 后热加载整个插件，模块会捕获其他模块的函数引用，不能仅加载单文件。新增目录、文件或 `.toc` 变更须完整重启。原生设置回调只注册一次，热加载只更新分发函数，避免追加监听；新增设置项时按项判断是否已注册（不能只看 category），并在 `ui.registered` 上防止重复注册分类。详细开发约定见 [AGENTS.md](AGENTS.md)。

仓库根目录执行 `python tests/verify_quest_data.py`，使用 `lupa.lua51` 隔离验证，不连接游戏。`--addon` 接受插件目录、`.toc` 或旧入口 `.lua` 路径，有同目录清单时均加载完整插件。最近代码验证与实机边界统一见[开发进度](../../开发进度.md)，避免把历史样本或离线模拟当成当前部署验收。
