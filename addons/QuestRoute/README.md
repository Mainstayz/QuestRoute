# QuestRoute 使用与 API

《魔兽世界：无限》当前任务路线与数据插件，在原生 M 地图、小地图绘制导航，并提供任务怪姓名板提示。安装、旧配置迁移和快速上手见根 [README](../../README.md)。

当前 `apiRevision=18`、`schemaVersion=1`，23 个 Lua 文件按 `QuestRoute.toc` 顺序加载。统一标识为 `QuestRouteDB`、`WoWBridgeNS.QuestRoute`、工坊 `addon="QuestRoute"`；命令 `/questroute` 和 `/questrouteapi`，不提供旧名称的运行时别名。装备候选与任务价值分析均不改变地图路线，装备规则见 [GEAR.md](GEAR.md)。

[开发进度](../../开发进度.md)记录最近验证与部署状态，[待办事项](../../待办事项.md)记录尚未完成的实机验收。[技术说明](../../docs/技术说明.md)解释数据、坐标与规划边界，[MODULES.md](MODULES.md)说明源码职责。

## 地图与设置

路线只安排玩家当前地图的有效任务；QuestieDB 补充附近接取、目的地漏接、直接前置和物品启动关系，有限前瞻有明确收益时可先安排接取或前置。未接任务的工作目标只进入预测，实际接取后才加入正式路线。进行中默认过滤副本、精英、专业；原生 **选项 → 插件 → QuestRoute** 提供三个复选框（精英任务、屏幕提示、任务怪姓名板）及“怪物最多高出角色几级”“接取建议最低任务等级”两个滑条。精英开关可单独放开未完成精英任务，屏幕提示和姓名板默认开启。战斗等级范围只查任务怪/材料来源怪的已知等级上限，不按任务标注等级过滤；另有未接任务的最低等级过滤，minPickupLevel为0..60整数、默认15，0关闭，等于阈值或等级未知时保留，已接任务不受此下限影响。maxMonsterLevelOffset为0..5整数、默认2：0只允许不高于角色的怪，1允许高1级。超出设置的来源不安排，普通路线/关联前瞻/换热点共用；同一材料可选择较低等级来源，改设置或升级后立即重评。整项官方完成后的交付不受类型和等级限制，手动跳过和失败仍优先。

- 青色编号和直线为路线，橙色 1 号是下一步；可交任务用金色 `N?`，已完成待确认用 `N~`。NPC 已确认提供或背包物品启动用 `N!`，数据库推算的接取待确认用 `N~!`；未采用的建议对应独立黄色 `!` / `~!`，取物来源也用 `~!`，不计入路线步数。实际对话未提供或客户端确认 NPC 不可交互时保留灰色 `×` 参考，不再安排该接取点。
- 每个可靠未完目标各一步，一个主热点和最多两个紫色 `Nb/Nc` 备选。备选不增加路线步数或里程。
- 普通右键跳过整项任务；Shift + 右键备选切到所点热点，Shift + 右键主点选择该目标其他地点。
- 小地图显示附近线路，视野外的当前 1 号和接取/取物建议在边缘指方向。已提示且仍有效的地点在本次地图会话中保留，走远或路线改变后仍可悬停查询，空路线也显示；接取、跳过、取得对应物品、资格失效或切图后清除，不写入存档。大地图关闭后仍工作，浏览其他地图不改变规划范围。
- 同地点编号作像素避让，以细线指向实际位置，不改导航坐标。

悬停最多四行（含标题），大地图与小地图共用：

```text
1. 野猪人的内战
刺背寻水者：5/6
赶路中 · 静态刷新区域
右键跳过任务 · Shift+右键换地点
```

接取建议、已提示地点、带书提示和核验受阻（×）的方块，同一地点（同实体同坐标，或世界距离 8 码内重叠的 NPC）的同类合并为一个方块，大地图与小地图相同；同一任务在 opportunities 与 carriedItems 同时出现时只画带书提示。合并方块（略大为 24×24）显示数量，1–9 个带符号（如 `3~!`），10–99 只显示数字，更多显示 `99+`；悬停仍为四行：`~! N 个任务`、`首个：任务名`、状态、`合并显示 · 右键不跳过，逐个处理`。合并方块右键不跳过任何任务（避免一次或误触跳过整组），要处理单个任务用 `/questroute skip <questID>`。

备选明确标注，交付与待确认状态分开；保留“静态刷新区域”或“任务参考位置”的精度说明，不展开奖励、同组清单或算法统计。接取步骤补接取 NPC 名称和坐标；未交互时只称“接取待确认”。实际对话记录绑定 NPC 身份及当时的位置，不能当成玩家走到别处后的可接清单；完整列表没有提供任务时，标记说明“NPC当前未提供 · 接取条件待确认”；当前选中/悬停/手柄交互目标为存活、在距离内的已知接取 NPC，但客户端明确不可交互时，说明“NPC当前不可交互 · 接取条件待确认”，`why` 也可查看。未知、太远或死亡不能推断此限制；同一 NPC 恢复可交互后自动释放旧限制。升级、接交/移除任务、背包、声望、技能/法术、进入世界或切换地区后重新核验，不写入手动跳过或存档。

姓名板功能默认启用，玩家自行开启敌方姓名板（默认 `V`）。黄色“! 击杀 2/6 · 材料 1/5”表示仍有已确认用途，关联当前路线目标时为橙色。覆盖所有有效未跳过任务，击杀够数但材料仍缺时继续提示；未知、身份受限或无可靠用途时隐藏，不将其判成确定无关。

原生设置页的默认值：精英关闭，屏幕提示与任务怪姓名板开启，怪物等级滑条为2，接取建议最低任务等级为15；修改后立即重排。跳过记录、移动阈值、总显示、姓名板、精英、怪物等级与接取等级选项按服务器/角色保存在 `QuestRouteDB.routes`，正常退出或重载时由客户端写盘。工作计时与地点避让仅存本次 UI 内存。

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
| `/questroute notice on`、`/questroute notice off` | 同时开关屏幕与聊天框提示（默认开）；每条 Toast 在聊天框保留同一份文字供回看 |
| `/questroute monsterlevel 0..5` | 设置怪物最多高出角色几级（默认2），0为同级及以下；只查怪物等级，立即重排 |
| `/questroute minlevel 0..60` | 接取建议最低任务等级（默认15），0关闭；只影响未接任务，立即重排 |
| `/questroute why` | 前三步距离与权重、排除原因、附近/目的地相关任务与启动物品机会；索引构建进度和本图做完后的下一图提示 |
| `/questroute audit [all\|ID]` | 只读分析当前任务日志价值（任务链后续/终点奖励、装备提升、独立远图纯经验过滤与清理建议）；省略列建议/可考虑项，`all` 列全部，传任务 ID 显示完整链条与依据 |
| `/questroute perf` | 只读显示路线重建统计（总次数、成功/路线未变/失败/退避拦截次数、最近与最大耗时、触发原因前几名）；不重建、不进入 `get_plan` |
| `/questrouteapi` | 只读显示当前任务列表 |

换地点后旧点 150 码内避开 600 秒，期间保留仍有效的手动热点，普通背包/任务更新不会用关联推荐覆盖；目标完成、跳过、切图、到期或主动 `replan` 后解除保持。无备选或状态失效时保留原路线、计时与任务跳过。清地点避让不会恢复手动跳过的任务。

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
- 路线重建失败（位置或任务数据读取抛错）时保留上一次成功计划，`get_plan`/`replan` 正常返回旧路线；从未成功过时返回 `ok=false`、`error.code="plan_unavailable"`，5 秒后自动重试，不虚构空计划。失败后到重试前，自动触发（复查计时器、移动/换图/升级、游戏事件）不再重建，玩家的手动操作仍立即重建。
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
| policy / scope | `stable_grouped_precedence_lookahead` / `current_player_map_active_and_available_quests` |
| sequence / origin / mapID / mapName | 规划序号、原点和玩家地区 |
| totalStraightDistance / reason / plannedAt | 路线直线总长、重建原因与本 UI 内的规划时间 |
| count / questCount | 目标/交付/接取步骤数、全部步骤的去重任务数 |
| activeQuestCount / pickupCount | 日志内有效任务数、接取/物品启动步骤数 |
| objectiveStepCount / nativeStepCount | 细目标与原生步骤数；含接取时 stepUnit 为 `unfinished_objective_quest_or_pickup`，否则为 `unfinished_objective_or_quest` |
| discovery / decision | 关联机会与索引状态、有限前瞻预测和是否采用；预测不表示实际已接或已完成 |
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

steps 保留 index/questID/title/level/status/action、stepKey/displayTitle/questStepCount、targetMapID、地图/world 坐标、source/precision、segmentDistance、priorityWeight/weightedDistance（含自由选点时的有界任务群加成）、workFactor/remainingWork（剩余数量对权重的 0.9~1.1 修正，缺数据为 1）、priority、groupIndex/groupSize/groupQuestCount、objectiveRevision/objectivesAvailable 和 navigation。action 为 quest_area/turn_in/completion_pending/pick_up/start_item，表示步骤类型；接取另有 certainty（estimated/confirmed）、可选 itemID 和 opportunityReason；navigation.phase 表示当前执行状态。细目标另带 objectiveKey/objective、entityKind/entityID/relation、locationVersion、targetMode/targetReason；显示标题与计数不改变任务原始标题。

excluded 每项含 questID/title/reason/source；`target_above_level` 表示所需目标怪超出已配置的等级范围，并非手动跳过；`why` 提示升级或调整设置后再做，不再使用任务等级门槛。reason 为 `outside_current_map` 时另有 otherMapID/otherMapName/otherDistance（离玩家最近的外图位置）。

groups 的 count 为步骤数、questCount 为任务数，questIDs 去重。stability 含 retained/reason、previousQuestID/questID、previousObjectiveKey/objectiveKey 和可选 lastProgressAt。奖励样本与读取按任务计一次。levelPriority 保留 referenceLevel，perLevelBonus=0、maxWeight=1.25、method 为 client_difficulty_and_reward；levelingPriority 提供难度权重、经验参照、阈值及 pendingRewardCount/rewardRetrySeconds。顶层 maxMonsterLevelOffset 为当前怪物等级设置，levelingPriority.maxLevelOffset 保留同值兼容字段。每步 priority 描述来源、可用性与因子，未知经验不按零处理。NPC 来源等级在坐标展开之前检查，已排除危险来源时不回退到无法识别来源的原生 POI；完成交付、接取 NPC 与原始 `get_quest_targets` 查询保留原语义。

steps[].hotspots 第一项为 selected=true 的主点，其余最多两个备选，含 id/selected/pointCount/radius/sparseFallback/x/y/world/coordinateMapID/targetMapID/source/precision=static_hotspot。hotspotRules 为 radius150/separation300/maxDisplayed3/deduplicateRadius3，algorithm 为 fixed_radius_density_real_spawn，alternativesJoinRoute=false。pointCount 不是实时怪数。

navigation.phase 为 travel/working/turn_in/completion_pending/pick_up/start_item/idle/unavailable，后续步骤为 queued。当前状态含 phase/label/reason、questID/questStatus/objectiveKey/objective、mapID/targetWorld、distance/atReference、observedAt/since；工作时还可有 workStartedAt/lastProgressAt/idleFor/stale/protected/objectivesAvailable/objectiveRevision。不可读字段省略。

navigationRules 为进入120/退出180码、进度300码/90秒、无进度超时180秒。状态每0.5秒更新；超时释放强保护，自动切换仍需改善30%且减少50加权码。turn_in 只证实日志可交，deliveryLocationConfirmed=false，locationPrecision=quest_poi。完整规则见[技术说明](../../docs/技术说明.md)。

### 任务关联与前瞻

关联知识全部来自 QuestieDB，按其数据有效设计；客户端只读校验角色等级、种族/职业、任务历史、当前进度、背包与实际交互可接列表。未接的重复、战场/PvP、节日/安其拉筹备活动、捐献类、纯ASCII英文标题和低于minPickupLevel的任务不进入接取建议、两图标记或前瞻，旧提示同步清除；已接任务仍正常导航和交付。对应 `discovery.blocked[].reason` 为repeatable、battleground、holiday、donation、unlocalized、quest_below_minimum。重复性采用原生 `IsRepeatableQuest=true` 或 QuestieDB `specialFlags` 的 REPEATABLE 位，补齐本客户端原生 false 的漏报；战场结合原生PvP类型41与数据库战场分类/AreaID，节日按数据库明确分类，捐献按中文标题“捐献/贡献”前缀。英文只过滤纯ASCII标题，中文夹英文缩写保留；标题或等级未知不当成英文/低级。捐献毛料原生等级为60且非重复，因此单独按捐献类排除。对话确认可接时绑定具体 NPC 和交互时的位置（source=client、precision=interaction_position）；其他接取点仍标注静态位置。完整对话列表未提供任务或近距离存活接取 NPC 明确不可交互时，该 NPC 接取点停止参与可执行候选，discovery.blocked 给出 unknown 和 npc_not_offering/npc_not_interactable 及 point/action；地图保留灰色 × 和原因。未知/不完整列表及单项详情不用于否定其他任务。`preQuestGroup` 按 AND、`preQuestSingle` 按 OR，完成目标仍需交付才满足前置。缺字段/不可读条件保留未知；未覆盖的 `triggerEnd` 探索/事件条件不能据普通目标预测完整交付，跳过/失败等被过滤的已接任务也不参与预测。

索引按当前地图分批构建，每批最多 64 任务，坐标、来源展开与索引写入内每 128 次操作或约 3 ms 让出，零本图地点的来源也计入预算。地图信息或世界坐标暂缺时，每 5 秒仅重试受影响记录，保留成功点并对新增索引去重；`discovery.pendingLocationCount` 给出待恢复数量，恢复前不提示本图已完成。机会包括 400 码内接取点、现有第一目的地 200 码内或同目标关系、直线途中额外绕路不超过 150 码的接取点、实际背包启动物品及附近可能掉落/拾取启动物品的来源。静态来源不表示实体在场或必掉。

任务需要带物品才由 NPC 给出（`record.questItems`，如幽暗城图书馆“40 本书”系列：先拾取书再交给图书管理员接取）时，背包没有该物品就不提议到该 NPC 接取，也不进 `blocked`、不画灰色×，路线与前瞻不会为它前往 NPC；背包有书时只提示带书（`carriedItems`），NPC 当面已提供则以 NPC 为准。背包读取不完整（接口缺失、出错或物品 ID 为机密值）时按未知处理，同样不提议也不判为没有。`get_plan` 的 `discovery.itemGate` 给出 `required`（确认背包没有）和 `unknown`（无法确认）的任务数，仅供调试；书籍所在物件的拾取建议（possible_item_drop）不受影响。

`discovery.opportunities[]` 提供 questID/title/action/point、certainty、reasons、relatedQuestIDs、distance/extraDistance 及可选 itemID；action 为 pick_up/start_item/possible_item_drop。`questItem=true` 的来源表示拾取任务所需物品，不是使用后接任务；point.entityName 给人物/物件名称（有数据时）。`discovery.carriedItems[]` 提供已持有但任务尚未接取的 questID/title/itemID/itemName/point/reasons，point 为 NPC 接交参考位置，可在外图；只提示，不跨图排正式步骤或认定任务可交。`discovery.announcedOpportunities[]` 给已提示、当前已离开候选范围且资格仍有效的地图参考点，字段沿用机会格式，reasons 为 previous_notice；不重入决策、不重复提示，重新进入候选范围时使用最新机会而不重复画点。blocked 列出条件未满足或未知的相关候选，实际 npc_not_offering/npc_not_interactable 核验优先保留在摘要中。两类即时摘要各限 25 项（已采用机会额外保留），opportunityTotal/blockedTotal 给完整数量，summaryLimit 给上限；搜索内部仍用完整候选。`decision.predicted[]` 是局部预测行动，不写回任务日志；正式步骤只采用当前可执行的下一动作。搜索深度 6、束宽 4，最多 18 项任务、6 个首动作与每层 4 个动作，复用本轮距离计算；没有可接或可解锁的收益时不展开。保留强制从原 1 号开始的独立基线。评分用任务目标/交付收益与直线行程、粗略工作成本，不是经验/小时预测，也不保证全局最优。

同区域不自动算共同完成；可靠同目标共享一次工作成本，不同目标但同 NPC 掉落来源只计部分协同，不据此认定材料已齐。当前工作保护和手动热点优先；目标暂缺回退到原生 POI 时沿用工作计时，不重启保护期。仍有效的已选接取点也作为独立稳定基线，微小移动不来回切换。屏幕一行提示与原有屏幕提示开关共用，本图完成的单次提示优先于新关联提示，遇到提示间隔则在间隔结束后自动补发；提示和 `why` 都给出顺路/同目标等理由、地图坐标及 NPC/物件类型；只有实际采用且 NPC 已确认提供的接取才说“建议先接”，静态预测称“建议先确认接取”。物件同时是非启动任务物品的唯一直接来源时，提示“顺路取物”；拾取后清除来源点，显示“已取得”及需向 NPC 确认接取/交付的位置，正式任务状态仍以客户端为准。`why` 保留这些信息供提示消失后查询，无新增面板或操作绑定。

### 路线操作

| 工坊 name / Lua 函数 | 参数与结果 |
| --- | --- |
| `replan` / `Replan` | `{}`；主动重排，绕过当前保持和旧组延续 |
| `set_quest_skip` / `SetQuestSkip` | `{questID,skipped?}`；默认 true，false 恢复，不放弃任务 |
| `reset_quest_skips` / `ResetQuestSkips` | `{}`；清当前角色全部任务跳过 |
| `set_route_options` / `SetRouteOptions` | `{moveThreshold?,maxMonsterLevelOffset?,minPickupLevel?,enabled?,nameplatesEnabled?,includeEliteQuests?,switchNotice?}`；maxMonsterLevelOffset为0..5整数、默认2，只限制怪物等级差；minPickupLevel为0..60整数、默认15，0关闭，仅过滤未接任务的标注等级下限；后四项boolean。立即重排并按角色保存 |
| `change_quest_spot` / `ChangeQuestSpot` | `{questID?,objectiveKey?,hotspotID?}`；省略取1号，key需questID，hotspotID需同时带questID/key，来自当前 hotspots[].id |
| `clear_spot_avoidances` / `ClearSpotAvoidances` | `{questID?}`；省略清全部，返回重排计划，不改任务跳过 |
| `get_unit_tasks` / `GetUnitTasks` | `{unit?}`；默认 target，仅接受 target/mouseover/nameplateN，只读当前单位任务用途 |
| `get_gear_candidates` / `GetGearCandidates` | `{level,class,spec,faction,gear?,weights?,questLevelWindow?,limit?,race?}`；战士防护候选、与现装差异和来源。字段、评分与覆盖见 [GEAR.md](GEAR.md) |
| `analyze_quests` / `AnalyzeQuests` | `{questID?,verdict?,includeChain?,includeGear?,requestLoad?,gear?,offset?,limit?}`；只读分析角色现有任务日志价值，追踪任务链后续/终点奖励并结合现装对比，输出 `recommend_drop/hold_or_drop/uncertain/keep/keep_priority` 建议与理由；副本/精英中性打标，绝不自动放弃任务。打开原生任务日志（`QuestMapFrame`）时在右侧附着只读价值侧边栏 |

change_quest_spot 成功返回 questID/objectiveKey/selected/expiresAt/avoidedRadius/duration；无备选、交付/原生点、失效 key、过期热点、目标或地图变化时返回错误，保留原路线和计时。省略 hotspotID 选择该目标其他最近区域。

get_unit_tasks 返回 state/needed、可读 npcID、tasks、neededCount/knownGoalCount/unresolvedQuestCount，可选 label/currentTarget 和来源/时间。state 为 needed/no_remaining_known_goals/no_known_match/unknown/not_eligible；无已知匹配不证明绝对无关。tasks 保留官方计数、finished、relation=kill/direct_item_drop、mapping、progressSource/relationSource。任务数据待合并时为 unknown，reason=quest_data_updating；身份受限不延用旧 ID。

## 事件、维护与验证

WoWBridge 事件由工坊 `events` 读取，addon 为 QuestRoute：

- `api.ready`：API 已就绪，含 schemaVersion/apiRevision。
- `route.updated`：路线内容变化（步骤、排除原因、待加载计数、奖励权重或关联清单），含 sequence/mapID/count/questCount/pickupCount/reason。内容没变时不发送，因此背包、技能和未改变步骤的走动不会点亮帧码。等缓存的复查若路线没变，还会把下一次推迟到 30 秒。
- `route.navigation_changed`：当前目标、阶段或保护语义变化，含 questID/objectiveKey、phase/reason/protected/stale/distance/mapID；不逐帧发送位置。
- `route.spot_changed`：成功手动换点的任务、目标、地图与到期信息。
- `route.association`：一行关联建议已显示，含 questID/action/applied。

修改 Lua 后热加载整个插件，模块会捕获其他模块的函数引用，不能仅加载单文件。新增目录、文件或 `.toc` 变更须完整重启。原生设置回调只注册一次，热加载只更新分发函数，避免追加监听；新增设置项时按项判断是否已注册（不能只看 category），并在 `ui.registered` 上防止重复注册分类。详细开发约定见 [AGENTS.md](AGENTS.md)。

仓库根目录执行 `python tests/verify_quest_data.py` 和 `python tests/verify_associations.py`，使用 `lupa.lua51` 隔离验证，不连接游戏。`--addon` 接受插件目录、`.toc` 或旧入口 `.lua` 路径，有同目录清单时均加载完整插件。最近代码验证与实机边界统一见[开发进度](../../开发进度.md)，避免把历史样本或离线模拟当成当前部署验收。
