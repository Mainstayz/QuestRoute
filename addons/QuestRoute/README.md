# QuestRoute

《魔兽世界：无限》地图规划与任务数据 API 插件：在原生大地图、小地图规划当前任务路线，并提供只读任务日志、玩家上下文、原生 POI 和可选 QuestieDB 补充查询。任务日志包括折叠分类下的任务、日志中可枚举的隐藏任务，以及完成后尚未交付的任务，不包含已交付的历史任务和尚未接取的任务。

统一标识：目录 `addons/QuestRoute/`，文件 `QuestRoute.lua` / `QuestRoute.toc`，Title `QuestRoute`，SavedVariables `QuestRouteDB`，Lua 命名空间 `WoWBridgeNS.QuestRoute`，工坊 `call` 的 `addon="QuestRoute"`。路线命令为 `/questroute`（`SlashCmdList.QUESTROUTE`），只读任务列表命令为 `/questrouteapi`。不提供旧名称的运行时别名。安装、停用旧目录及手动配置迁移见根 [README](../../README.md)。

当前代码修订仍为 **apiRevision=13**，schemaVersion=1。已完成仓库重命名，新路径下626项Lua5.1隔离检查全部通过，插件离线检查无错误或警告。游戏安装尚未同步，新名称启动及实机调用待验证；下述交付步骤和地图截图来自重命名前的现场记录。

已完成待交任务纳入当前地图路线，副本/精英/专业类型不再挡住交付；未完成时仍按既有类型过滤。交付编号带?，悬停注明交任务；已完成但客户端尚未确认可交时带~并提示等待确认。保留每未完目标一个主热点+最多两个地图备选、直线/升级权重/稳定和手动跳过。上轮626项隔离检查通过，4个原生交付步骤已在线核对，M地图?编号/悬停及b备选显示已截图确认；真正交付后的移除和备选点击手感仍待现场验收。原有 `get_quests` 保持默认100的分页和字段契约，提供可选原生 `tag={id,name,isElite?,tradeskillLineID?}`。

原生数据决定当前任务状态、进度及目标行为；QuestieDB补充数据独立放置并标记来源。无需安装QuestieDB即可使用原生接口。

## 通过无限工坊调用

使用无限工坊的 `mcp__wuxian__call`：

```json
{
  "addon": "QuestRoute",
  "name": "get_quests",
  "args": {}
}
```

默认返回最多 100 个任务及其目标进度。读取更多任务时，使用结果的 `nextOffset` 继续，直到 `hasMore` 为 false。

分页或只取基本信息：

```json
{
  "addon": "QuestRoute",
  "name": "get_quests",
  "args": {
    "offset": 0,
    "limit": 10,
    "includeObjectives": false
  }
}
```

参数：

| 字段 | 默认值 | 含义 |
| --- | --- | --- |
| `offset` | `0` | 从 0 开始的任务偏移，非负整数 |
| `limit` | `100` | 每页数量，1 至 100 的整数 |
| `includeObjectives` | `true` | 是否附带目标文字、类型、已完成数量和所需数量 |

## 其他插件中的 Lua 调用

在依赖中声明 `QuestRoute`，并在它加载后调用：

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

游戏内输入 `/questrouteapi`，会在自己的聊天窗口只读显示当前任务列表。

## 返回结构

`call` 的返回结果包在 `result` 中；Lua 直接调用则直接得到下列结构。

```json
{
  "ok": true,
  "schemaVersion": 1,
  "scope": "active_quest_log",
  "character": { "name": "擎天", "realm": "CN1 Realm 10 RP" },
  "total": 22,
  "reportedTotal": 22,
  "logComplete": true,
  "offset": 0,
  "limit": 1,
  "count": 1,
  "hasMore": true,
  "nextOffset": 1,
  "quests": [
    {
      "questID": 1491,
      "title": "智慧饮料",
      "category": "哀嚎洞穴",
      "logIndex": 2,
      "level": 18,
      "suggestedGroup": 0,
      "frequency": 0,
      "classification": 7,
      "isHidden": false,
      "isTask": false,
      "isStory": false,
      "isComplete": false,
      "isFailed": false,
      "readyForTurnIn": false,
      "status": "in_progress",
      "objectivesLoaded": true,
      "objectives": [
        {
          "index": 1,
          "text": "0/6 哀嚎香精",
          "type": "item",
          "objectiveType": 1,
          "finished": false,
          "numFulfilled": 0,
          "numRequired": 6
        }
      ]
    }
  ]
}
```

- `total` 是枚举到的任务数，`reportedTotal` 是客户端报告的任务数；`logComplete` 表示两者一致，和是否还有下一页无关。
- `status` 为 `in_progress`（进行中）、`ready_for_turn_in`（可交付）、`complete`（目标完成但客户端尚未标为可交付）或 `failed`（失败）。
- `objectivesLoaded` 表示客户端是否返回了目标表；不保证所有目标文字都已经包含物品或怪物名称。文字和数量按客户端原样返回，目标是否完成以 `finished` 为准，不以数量自行推断。
- `includeObjectives=false` 时不返回 `objectives` 和 `objectivesLoaded`。最后一页不包含 `nextOffset`。不存在的可选字段省略。
- 每次调用实时读取。分页期间玩家接取或交付任务会改变日志；需要一致列表时优先一次读完。
- 无效参数返回 `{ "ok": false, "error": { "code": "invalid_arguments", "message": "..." } }`。
- 玩家姓名受客户端机密值限制而不可访问时，省略 `character.name`。

## 新增：玩家上下文

```json
{"addon":"QuestRoute","name":"get_player_context","args":{}}
```

返回原生 `character`（姓名、服务器、阵营、等级）、`experience`（current、maximum、rested、可选fraction）、`location`。位置包含 `available`、`coordinateMapID`、地图名和0..1的x/y，可能有 `world={continentID,x,y}`。无可用位置时提供reason，不填入虚构坐标；不会读取玩家生命或能量。

## 新增：原生任务 POI

```json
{"addon":"QuestRoute","name":"get_quest_pois","args":{"questID":881}}
```

参数 mapID、questID 均可选，必须为正整数。mapID必须是当前客户端地图。offset默认0，limit默认50、最大100。

- 指定mapID：只查询该图。
- 不指定mapID：扫描艾泽拉斯947的后代地图，结果带mapScope说明扫描数量和范围；此范围不覆盖全部副本。
- 只返回当前日志任务。questID不在日志时返回空结果和 `reason="quest_not_in_log"`。
- 先按任务过滤、合并投影、稳定排序，再分页。total为过滤去重后的总数；rawCount为合并前记录数；无可用原始坐标的数量为unusableCount。
- 去重只合并同任务、同标记语义、同continentID且世界坐标距离不大于0.1的点。先选原图记录为固定代表，避免链式近邻误合并。无世界坐标时，仅合并坐标系和坐标完全相同的记录。

POI字段：questID、coordinateMapID、reportedMapID、x、y、units="normalized"、precision="quest_poi"、source="C_QuestLog.GetQuestsOnMap"、projectionCount、queryMapIDs、worldAvailable，以及可选world。世界坐标转换失败会保留地图坐标并给worldUnavailableReason。

**x/y属于coordinateMapID，reportedMapID不是它们的替代坐标系。**显示常见地图坐标时乘100。不同continentID的世界坐标不可直接比较；直线距离不是可行走路线。

POI的inProgress不能判断任务完成，numObjectives也不是实际完成进度。坐标会随游戏状态变化，应重新读取，不把一次查询结果永久缓存成刷新点数据库。

## 新增：任务详情（原生优先）

```json
{"addon":"QuestRoute","name":"get_quest_details","args":{"questID":881}}
```

只要官方数据：

```json
{"addon":"QuestRoute","name":"get_quest_details","args":{"questID":881,"allowDatabase":false}}
```

参数：questID必填；allowDatabase默认true；includePOIs默认true；offset/limit仅对数据库references分页，默认0/50、最大100。

返回 `policy="client_first"`、`official`、`database` 两部分：

- official：source="client"，available/inLog，当前日志任务quest，及可选pois、poiCoverage、poiRawCount。不在日志的任务明确available=false，不生成假的当前进度。
- database：source="QuestieDB"、版本和契约、数据库元数据、chain、references分页，以及特殊目标关系。没有数据库、版本不兼容、任务未收录、关闭补充或数据库读取报错时给available=false和reason，官方部分继续返回。
- references只返回接取、交付和目标的实体关系，不递归展开全部坐标。role为quest_start、quest_turn_in或objective_reference，kind为npc/object/item，id为实体ID。
- objective_reference的databaseGroup/databaseIndex是数据库位置，不是官方objectiveIndex；objectiveIndexMapping固定为not_inferred。生物关联不一定是击杀要求。
- chain只是数据库关系，不能据此判断后续任务当前可接。数据库的0值ID是缺省值，不能拿它继续查询。

## 新增：QuestieDB实体查询

```json
{"addon":"QuestRoute","name":"get_database_entity","args":{"kind":"item","id":5100}}
```

```json
{"addon":"QuestRoute","name":"get_database_entity","args":{"kind":"npc","id":3475}}
```

kind为npc、object或item，id为正整数；offset默认0，limit默认50、最大100。

- item返回直接掉落、容器或商人relations，按单条关系分页；不会递归展开容器，因此不会陷入循环关系。
- npc/object返回扁平locations，按单个位置记录分页，包括不能导航的记录。total是全部位置数，usableLocationTotal是有可用地图坐标的位置数；locationAvailability为available、missing或unusable。
- 坐标保留areaID、spawnIndex、originalX/originalY（0..100）、可选phase，同时统一提供0..1的x/y、coordinateMapID、地图名、可选world。phase仅保留原值，未验证玩家当前是否处于该相位；available只说明坐标可表达，不代表目标当前在场。
- (-1,-1)保留为available=false、reason=instance_only，不转换成导航坐标。缺失地图、显示抑制、无效坐标和客户端不支持的地图分别返回原因；合法(0,0)不会被当成未知。
- 支持映射表和本版本的数字赋值数据字符串，基础映射后应用override，不执行字符串，不自动进行Era→Forever二次换算。
- 数据库不存在时 `ok=true,available=false,reason=not_loaded`；实体不存在为entity_not_found；读取异常返回 `ok=false,error.code=database_error`。

其他Lua代码可使用 `WoWBridgeNS.QuestRoute.GetPlayerContext/GetQuestPOIs/GetQuestDetails/GetDatabaseEntity`，参数与MCP入口一致。数据库在每次调用时动态发现；此机制沿用原实现，重命名安装仍须完整重启。

## 简易地图升级路线

在原生 **M 地区地图**上显示编号和青色直线，橙色1号为下一步；右上角小地图同步显示附近路线。大地图关闭后小地图继续工作。不创建额外面板，不改变原生任务追踪或放弃任务。

- 未完成任务默认排除副本/团队副本、精英和专业任务；官方确认完成后，以上类型也可作为交付步骤加入。手动跳过及失败状态始终优先。副本/精英以原生分类为准；专业优先原生、缺失时用QuestieDB.requiredSkill补充。
- 只安排目标实际属于**玩家当前所在地图**的任务：用POI.reportedMapID判定目标归属，用coordinateMapID解释坐标。邻区任务即使能投影到当前地图内，也不纳入。当前地图由玩家位置决定，浏览其他地图不会切换规划范围。
- 以直线距离为基础，按客户端相对难度和已就绪的奖励经验校准权重，按 `直线距离 / 权重` 逐步选择。容易任务略优先、困难/极难及琐碎任务靠后，低收益主要顺路做/交；每个未完目标一次，奖励参照仍每任务一次，不增加地形或交通评分，不按旧版等级阈值猜难度。
- 默认玩家相对上次规划位置移动100码后重排，每0.5秒检查；玩家跨地图或升级，即使位移不足100码也重排。任务进度更新在短暂合并事件后重排。
- 右键自己的编号标记跳过任务，立即重排；按服务器与角色保存跳过记录和移动阈值，正常退出/重载时由客户端写盘。
- 其他地图的任务保留在get_plan.excluded，reason=outside_current_map；缺少原生POI或无法换算坐标也给出原因，不用假点连线。
- 自有图层挂在地图canvas下，随缩放/平移变化；仅在查看玩家当前地区时显示，浏览其他地区隐藏。不会主动打开或切换暴雪地图。

路线命令注册为 `SlashCmdList.QUESTROUTE`：

| 命令 | 作用 |
| --- | --- |
| `/questroute` | 显示状态和命令提示 |
| `/questroute skip 852` | 跳过指定任务 |
| `/questroute unskip 852` | 恢复指定任务 |
| `/questroute unskip all` | 恢复全部手动跳过任务 |
| `/questroute distance 150` | 将移动重排阈值设为150码，范围10..5000 |
| `/questroute replan` | 解除本轮目标保持，按当前位置重新选择1号并归组 |
| `/questroute off`、`/questroute on` | 隐藏、显示路线和任务标识 |
| `/questroute nextspot` | 为当前1号换同一未完目标的地点 |
| `/questroute nextspot 878` | 为该questID换地点；ID不是地图步骤序号 |
| `/questroute resetspots` | 清除全部临时地点避让并重排 |
| `/questroute resetspots 878` | 只清该任务的地点避让 |
| `/questroute nameplates off`、`/questroute nameplates on` | 单独关闭、开启任务姓名板提示 |

额外的WoWBridge入口，addon为 `QuestRoute`：

- `get_plan({})`：当前steps、excluded、origin、sequence、moveThreshold和policy。scope=current_player_map_active_quests，policy=stable_grouped_leveling_straight_line；mapID/mapName为玩家地区，levelPriority保留referenceLevel，perLevelBonus=0、maxWeight=1.25、method=client_difficulty_and_reward。levelingPriority提供经验参照、难度权重、低收益阈值、pendingRewardCount及rewardRetrySeconds。每步priority给难度/经验来源与可用性、因子及排序原因。每步含targetMapID、priorityWeight/weightedDistance和groupIndex/groupSize，segmentDistance仍是真实直线距离。groups含index/anchor、去重questIDs、count步骤数和questCount任务数，groupRadius=200。stability含retained/reason/previousQuestID/questID/previousObjectiveKey/objectiveKey/可选lastProgressAt。count现在是目标/交付步骤数，questCount为任务数，objectiveStepCount/nativeStepCount分别计细目标和原生步骤，stepUnit=unfinished_objective_or_quest。每步stepKey稳定区分同任务不同目标，displayTitle带目标名或交付状态，questStepCount给同任务步骤数量。r13新增turnInCount和completionPendingCount，分别为本图可交与完成待确认步骤数。
- `replan({})`：主动重排，绕过当前目标保持和旧区域延续，以新1号重新归组。
- `set_quest_skip({questID:852,skipped:true})`：跳过；false恢复。
- `reset_quest_skips({})`：清空当前角色手动跳过。
- `set_route_options({moveThreshold:100,enabled:true})`：路线选项。

对应Lua函数为 `WoWBridgeNS.QuestRoute` 下的 GetPlan、Replan、SetQuestSkip、ResetQuestSkips、SetRouteOptions。原生任务POI是参考点；路线按用户要求只表示直线，不做道路寻路。Shift+M区域图尚未在当前客户端验证。

### 完成任务顺路交付（r13）

原有普通完成任务已会生成交付步骤，r13修复旧副本/精英/专业过滤仍排除已完成任务的问题。官方ReadyForTurnIn或IsComplete后不再受活动类型过滤；failed/手动skip优先，目标实际地图、可用位置和世界坐标检查继续生效。只清目标finished而整项状态仍in_progress不提升为可交。

每项已完成任务最多一个原生交付/等待确认步骤，与未完目标一起按原直线距离/升级权重及稳定规则安排。待交免战斗难度惩罚，不强迫每做完一个就立刻回城。实际交付使任务从日志移除后自动清点；走到坐标不算交付。完成任务不保留怪物热点/备选，不参与任务怪姓名板标识。

两张地图用金黄色N?表示可交（当前1号仍橙色），悬停/同组标题含“交任务”；只有IsComplete而未ready时用N~及“等待确认交付”，不冒充确认可交。原生POI仍是任务参考点，不宣称精确实时NPC位置；无原生点或交付在外图时保留excluded原因，不造位置/不拉回旧刷怪点。

在线贫瘠之地样本：6981发光的碎片48.19,32.78、1487清除变异者46.01,35.74、3261乔恩·星眼44.86,59.14、1823和鲁迦交谈44.67,59.42共4交付步骤。前两项旧版被instance过滤，现已进路线。3301/3923/1060/1483/264/742原生交付归属外图，继续不排本图。当前8任务12步骤，turnInCount=4，completionPendingCount=0。

### 密集热点与两个地图备选（r12）

用户明确选择“一个主热点＋最多两个备选，地图上都能看到”。每未完目标仍只占一条路线步骤，主热点用普通编号，备选用紫色Nb/Nc编号（如2b/2c）；备选不接入路线线段、不增加里程。Shift+右键备选精确切到该热点，Shift+右键主编号/nextspot选择同目标其他最近热点。普通右键任一编号仍跳过整项任务。M地图显示本图各主点/备选，小地图仅显示视野内备选，不将远方备选夹到边缘。

算法：世界坐标3码内去重；空间格索引统计每个真实点150码圈内的不同位置数；按密度降序、平均平方距离升序选居中真实点，再抑制中心间距不足300码的重复区域。不用全图坐标平均或单链连通把两片怪群合并。存在成群点时略去孤立噪点；全为稀疏点时保留真实点兜底，不强造3处。路线仍按既有直线距离/升级权重挑主点，备选取相邻其他区域，未新增掉率/经验收益猜测。

get_plan.hotspotRules提供radius150/separation300/maxDisplayed3/deduplicateRadius3/algorithm=fixed_radius_density_real_spawn/alternativesJoinRoute=false。steps[].hotspots第一项为selected=true的主热点，其余最多两项为备选；每项含id/selected/pointCount/radius/sparseFallback/x/y/world/coordinateMapID/targetMapID/source/precision=static_hotspot。pointCount是数据库150码内不同刷新位置数，不是实时怪数或掉率。get_quest_targets仍返回原始静态点和官方进度。

change_quest_spot可带hotspotID（来自hotspots[].id），需同时提供questID/objectiveKey；不传则兼容选其他最近区域。选择前重读进度/地图/身份和热点；重建采用草稿，二次数据失效时不提交计划、计时、避让或事件。旧150码/600秒固定圆避让继续生效，不因区域代表重算绕回原生点。静态几何按任务/目标/地图及位置版本指纹缓存，最多64项，缓存不保留旧目标进度；地图绘制只用已算结果。

实机样本878地卜师8/12时，主点51.18,57.58（150码内7处记录），备选53.32,53.19（11处）、41.39,45.77（9处）。随后官方变为寻水者6/6、织棘者12/12、地卜师12/12，878热点全部移除，仅一个ready_for_turn_in步骤，原生点44.55,59.27。战斗截图可见真实地卜师姓名板“! 击杀8/12”样本；完整场景覆盖仍按待办继续。M图实际备选观感/实机点击尚未确认。

### 多目标分别导航（r11，r12保留）

对可靠唯一对应的未完成目标，分别从QuestieDB的本图有效静态点中选一处加入路线；同目标多个刷新点仍是备选，不把全地图每个刷怪点都编号。按直线距离/既有权重和固定200码归组串联。官方finished=true的目标不生成步骤；同任务另一目标仍未完成时，独立保留。无可靠目标数据时每任务最多一条原生回退，整项完成后最多一个交付点。

真实878野猪人的内战：寻水者5/6→47.72,52.79，地卜师0/12→50.76,57.13，两者分别为步骤2和3；织棘者12/12已剔除。当前9个任务形成12步（8个细目标+4个原生交付）。小地图仅显示附近步骤和当前目标方向；完整本图步骤在M地图，不把远处所有目标夹到小地图边缘。

同坐标/近坐标编号会作固定像素错位，并以细线连接真实点；坐标/路线距离不变。悬停标题带目标名称，同组提示也包含同任务其他目标。普通右键跳过整任务及全部目标，Shift+右键只换所点objectiveKey的地点。API change_quest_spot可带questID/objectiveKey精确操作，省略key仍兼容选该任务当前最靠前步骤。

经验数据/中位数/缓存重试按任务只计一次，拆多目标不会人为增加奖励样本。同组延续按实际原组stepKey列表，不因为相同questID就优先插入原在远方的其他目标；r10旧计划升级保留必要兼容。目标缓存暂缺时多条细目标收敛为一条原生或避让等待，恢复按key各一条，原工作计时不重开；完成/跳过/外图不会复活。

### 换地点与姓名板提示（r10，r11保留）

地图编号普通右键仍跳过任务，Shift+右键为该编号对应任务换同一objectiveKey的本地图静态位置；也可用nextspot命令。成功后把所选任务/目标的备选点作为本次1号，之后仍按既有自动稳定规则安排。旧点世界坐标150码内临时避开600秒，固定圆不链式扩张，按questID/objectiveKey/mapID隔离，最多64条。到期、目标完成/移除或角色跨图后释放；同UI热加载保留，完整重载/新UI不恢复，不写SavedVariables。

没有同目标合法备选、步骤是交付/原生POI、玩家换图、目标已变或数据暂缺时，换点失败并保留原路线/计时/跳过。成功后若精确位置暂缺，等待数据恢复，避免借原生POI回到已避让的旧区域；等待期间保留原工作计时，恢复不重开已超时保护。官方完成后的交付按正常流程处理。resetspots只清地点避让，不清任务跳过。

姓名板开启后，在游戏提供的可见、可读、可攻击活NPC姓名板旁绘制自有非交互短标签，如“! 击杀 2/6 · 材料 1/5”。黄色表示仍有已确认未完用途，任一用途属于当前路线目标时为橙色。第一版只突出仍需要者，不给已够或普通怪加灰勾/否定结论；材料表示数据库记载的可能直接掉落来源，不保证每只必掉。

标识覆盖全部有效未跳过任务，不只当前1号；副本/精英/专业、失败或官方完成任务不参与。身份解析与坐标解耦：没有刷怪点、位置读取失败或仅外图位置，不抹去可靠NPC关系。击杀直接对应NPC，材料只读一层npcDrops，不为NPC标识读取spawns/objectDrops。每条保留独立任务与目标进度，任何一项仍需就继续标识；finished=false即使计数已满仍按未完成处理。

每次刷新读取可访问的UnitCreatureID，不凭相似名字或旧缓存身份。任务事件合并刷新期间清旧标签；姓名板增加/移除及0.5秒采样重新绑定，复用图元；未知/机密/读错/非活敌对NPC/forbidden框体隐藏，卸载清单位和目标引用。不会代玩家打开姓名板或改CVar，需要玩家自行开启敌方姓名板（默认V）。战斗时是否可读还需真实验证。

新WoWBridge入口：

- change_quest_spot({questID?,objectiveKey?,hotspotID?}) / Lua ChangeQuestSpot：hotspotID可指定地图备选，需同时questID/objectiveKey；省略取1号，objectiveKey如npc:3263需同时传questID，指定具体目标；成功返回questID/objectiveKey/selected/expiresAt/avoidedRadius/duration；无备选等返回ok=false/error.code/message，绝不转为任务跳过。
- clear_spot_avoidances({questID?}) / Lua ClearSpotAvoidances：省略清全部，返回重排后的计划。
- get_unit_tasks({unit?}) / Lua GetUnitTasks：默认target，只接受target/mouseover/nameplateN，只读返回state/needed、可读npcID、tasks、neededCount/knownGoalCount、可选label/currentTarget、进度/关系来源及时间。状态needed/no_remaining_known_goals/no_known_match/unknown/not_eligible；无匹配不等于证明无任务用途。任务数据待合并更新、身份或关系不可访问时unknown。
- set_route_options新增nameplatesEnabled=true/false（默认true）；enabled控制地图与标识总开关。get_plan新增spotRules/avoidedSpots/nameplates摘要，nameplates.unresolvedQuestCount说明未能完整解析的有效任务数量。

本轮在线把878刺背寻水者从45.09,55.26换为43.17,55.70，间隔约196.82码；再清除该次避让恢复45.09,55.26，跳过记录保留。实际NPC3260/3261/3263的索引各含878击杀与899獠牙材料两种用途；822仍skipped，因此不参与标识。当前无可见姓名板或目标，不能声称真实怪群/战斗提示已验收。全部512项Lua5.1检查通过，包含原436项及新增换点/身份/生命周期场景。

### 未完成目标导航（r9，r10保留）

新增只读get_quest_targets({questID,mapID?,allowDatabase?,offset?,limit?})，Lua入口GetQuestTargets。默认offset0、limit50、最大100；mapID需是有效客户端图。allowDatabase=false仅关闭本次查询补充，不更改路线偏好。只读查询不重排、不会恢复玩家跳过。

返回mode=objective_locations或native_poi，reason说明采用/回退依据；objectives始终保留完整官方进度，objectivesLoaded说明原表是否加载，mappingComplete说明数据库身份是否全部唯一对应；只有完整对应时附加key/id/name/mapping。targets按total/count/hasMore/nextOffset分页。每条目标含index/key/kind/id/name/text/finished/numFulfilled/numRequired/mapping；每点含objectiveKey/objective、entityKind/entityID/relation、source=QuestieDB、precision=static_spawn、地图/坐标/world。progressSource是C_QuestLog.GetQuestObjectives，locationSource/databaseVersion独立标明。回退时targets是原生任务POI，完整身份对应也可能因坐标不可用而回退，因此以mode判断细导航是否启用；allowDatabase=false仍返回官方目标列表。

实现使用同任务、同类型、客户端目标格式与数据库完整名称的精确唯一双射，mapping=task_scoped_exact_localized_text；不等同取得官方实体ID，不使用数组顺序或模糊名称。特殊关联/图标、缺项、歧义和未知状态回退。怪物和普通物件用本体位置，物品只追一层npcDrops/objectDrops，缺直接来源不推荐购买；phase未判定、无效地图、副本哨兵不直接导航。

get_plan新增objectiveResolution摘要、pendingObjectiveCount/objectiveRetrySeconds；临时目标状态/实体名/读取异常每5秒恢复性重读，恢复停止，固定名称不匹配不轮询。steps含objectiveKey/objective、entityKind/entityID/relation、locationVersion、targetMode/targetReason。r11起每个未完目标各安排一条地点，按其本地图有效位置选取；目标完成就解除旧子目标工作保护，即使整项仍in_progress。剩余目标在外图时不留用已完成本地目标；任务级原生回退继续用原地图归属规则。

导航状态与route.navigation_changed也含objectiveKey/objective（事件只带key）。真实进展绑定对应目标及当时玩家300码内的地点，不让其他目标或同目标远方刷新点继承当前区域的活动。整项完成后回官方交付逻辑。已解析进度按实体key匹配旧快照并独立维护修订，目标纯换序不重置计时；临时降级原生定位保存相同区域子目标计时，恢复也不重开超时。子目标完成后，同任务剩余附近目标仍参与原组候选，不能整任务排除。现有地图悬停显示当前目标、进度、静态位置来源，不把静态点称为实体实时位置。

实际878三种任务怪95点可匹配；822真实已完肝脏已剔除，剩余2种材料58点。822仍遵守玩家skipped，查询没有恢复它。9个当前路线步骤中5个细目标、4个原生待交。436项隔离检查和实机数据/小地图通过；完整证据见工作区逐目标导航调研与实现.md。实际完成一条子目标后的动态换点仍待验收。

### 当前导航状态（r8，r9保留）

get_plan.navigation与当前steps[1].navigation共享当前状态；后续步骤navigation.phase=queued。phase可为travel（赶路）、working（在这一带完成目标）、turn_in（日志可交）、completion_pending（已完成但尚未ready）、idle（无符合条件的本图任务）、unavailable（玩家/任务位置暂缺）。原action仍表示步骤类型，不随到达参考点而完成。

当前状态含phase/label/reason、questID/questStatus、mapID/targetWorld、distance/atReference、observedAt/since；工作状态还可有workStartedAt/lastProgressAt/idleFor/stale/protected、objectivesAvailable/objectiveRevision。位置或进度不可用的字段省略，不假造值。

navigationRules公开120码进入、180码退出、300码进度扩展、90秒进度窗口及180秒无进展超时。状态每0.5秒刷新，不用移动满100码；保护失效时额外比较候选。悬停现有编号显示状态，持续悬停时自动刷新。

每次真实进展绑定当时的本图POI，防止参考点跳变后旧活动保护新区域。临时目标数据缺失不伪造进展，临时坐标缺失不重置旧工作超时；超时释放强保护，仍遵守30%和50加权码切换门槛，不承诺超时必换任务。

无原生POI或位置暂缺时，pendingLocationCount/locationRetrySeconds=5说明复查状态；每5秒恢复性读取，全就绪停止。真正的外图或其他正常过滤不触发这种复查。turn_in只证实日志可交，navigation.locationPrecision=quest_poi、deliveryLocationConfirmed=false，提示交付位置以游戏提示为准。

新增事件route.navigation_changed，带questID/phase/reason/protected/stale/distance/mapID，仅状态有语义变化时报告；通过工坊events读取。GetTime计时与工作会话仅在当前UI内存，不写存档。

实现与352项检查见工作区导航状态与验收.md；实机已确认赶路和小地图提示，真实完成“赶路→工作→交付”的一整轮仍在待办中。

### 适合升级的任务优先（r7）

客户端C_PlayerInfo.GetContentDifficultyQuestForPlayer返回的Trivial/Easy/Fair/Difficult/Impossible，在任务进行中分别给难度权重0.4/1.25/1/0.65/0.4；IsQuestTrivial=true也按琐碎处理。未知难度按1，完全缺失时回到距离排序。任务等级仅展示，不再每低一级累加权重。

经验使用本客户端已实测的GetQuestLogRewardXP(questID)，只在HaveQuestData和HaveQuestRewardData均为true时接受有限非负结果。函数缺失/读取失败、缓存未就绪或受限值标记未知，绝不当作0；缓存就绪的0经验因子为0.5。

本次已过滤、同图Easy/Fair候选至少3项已知正奖励时，用其中位数作相对参照：不足参照25%经验因子0.55，不足50%为0.8。另用UnitXPMax提供本级升级所需总经验：不足0.5%也给0.55，不足1%给0.8；两种参照取较低因子。参照未知不猜值，所有信息不足时经验因子1。比例是简单路线策略，不能解释为精确经验/小时或服务端衰减规则。

最终权重为难度×经验因子，仍按距离÷权重选择，最大1.25。已完成/待交的任务难度权重为1，经验因子最低0.85，便于附近交付；complete但未ready时priority.reason与action均为completion_pending，不宣称已可交付。

悬停现有地图编号可见建议与客户端奖励经验。任务/奖励加载事件会合并刷新；暂缺奖励每5秒复查，全就绪后停止，不要求玩家必须移动。难度高或奖励低只降权，不自动跳过任务。更完整的实测依据见工作区升级优先级调研.md。

### 目标稳定与附近任务归组

- 自动更新仍重读原生POI与任务状态，但候选只有在加权距离至少改善30%、同时至少减少50加权码时才替换旧1号，避免距离接近时来回跳换。
- 对仍在进行中的1号：120码内进入工作状态，已在工作时180码内继续；或300码内且最近90秒有同阶段、同区域真实进展时保持。连续180秒无进度则释放强保护，即使仍站在区域内。这不代表到点或超时就完成任务。
- 状态变为complete/ready_for_turn_in、任务被跳过/失败/移除、目标转到其他图、位置缺失，或POI移动超过100码时，解除旧目标保持。重新使用客户端当前坐标；complete但尚无ready标记时，action=completion_pending，提示确认交付信息。
- 原生目标数据暂缺/空表/读取异常时不伪造进度；计数重置、目标结构或顺序变化也不刷新90秒保护。时间戳只保存在本次UI会话内，不写进SavedVariables。
- 一个任务组以首个点为固定中心，先安排其200码内的任务，再选下一组。不会沿着相邻点不断扩大分组。组内仍用距离/适合升级的权重排序；同任务多点只选择符合本组距离的一处，每个任务只出现一次。
- 当前任务完成/消失/跳过后，玩家仍在原区域300码内时，优先接着安排原组剩余有效任务；不满足时重新选区。悬停编号显示“附近还有N个任务”和最多3个任务名。
- `/questroute replan`或API replan可随时主动重新选择，不受上述保持/旧组影响。热加载复用框体但重新绑定回调，确保两张地图提示同步更新。

### 右上角小地图

- 使用同一份当前地区路线，橙色1号为下一目标；后续点仅在附近显示。下一目标超出视野时，将1号放在边缘指示方向，提示文字明确它是视野外目标。
- 使用原生C_Minimap.GetViewRadius读取实时视野半径，配合世界坐标投影；缩放变化无需重新规划，旋转模式结合GetPlayerFacing和IsRotateMinimapIgnored更新方向。
- 线段按圆形边界裁剪，只画真实路线在视野内的部分，不把多个视野外点夹到边缘后重新连线。中心留出角色箭头位置。
- 绘制每0.1秒更新；位置采样与原有移动重排仍每0.5秒进行。附近点随移动更新，无需先走满100码。
- 小地图编号也可右键跳过。`/questroute off`、`/questroute on`和set_route_options.enabled同时控制大地图、小地图。
- 当前小地图为圆形；对其他外形保留内接椭圆范围。没有位置/视野半径或旋转朝向时隐藏本次图层，不保留错误方向。

## 验证与安装

历史验证：2026-11-12 在客户端1.60.1.70888、Interface16001，以旧插件名完成热加载检查，无错误、无警告。上轮Lua5.1隔离检查共626项通过：r12原598项+28项交付检查（已完成各活动类型/未完成仍过滤、失败/skip优先、外图/无POI、完成待确认、两图?和~显示、事件插入/到点不算交付/实际日志移除）。保留r11原557项+41项热点/备选检查；旧散点轮换用例改为区域轮换，保留原150码边界/600秒到期/精确目标/skip/回退/工作计时语义。新增密度/实际中心/重复与混源去重、链/环/稀疏分布、主备最多3且不加路线/里程、两图备选渲染和指定c点击、二次读取失败无副作用、2400点冷/暖缓存及70个不同目标的64项淘汰边界。

离线验证还实际重执行源码，覆盖同namespace复用、旧revision缺字段升级、新namespace启动；确认driver不重复、两张地图共用步骤、旧回调被替换、跳过记录继续有效、不跨UI会话恢复基于GetTime的工作保护。

历史r13在线快照：贫瘠之地8任务12步骤，其中4交付；断言所有点targetMapID为本图，可交各任务一条且无objectiveKey/热点，turnInCount一致。小地图1?可见；用户手动打开M图后截图确认金色1?/2?/4?/5?、交任务悬停和紫色6b/7b/9b备选可见。load/try无错误/拦截，ERR/BLOCKED空。r12真实878完成前后/地卜师战斗8/12及13.91ms暖重排证据保留；实际备选点击、交付日志移除及第4整轮继续待验收。

离线测试位于工作区 `C:\Users\Pillar\Desktop\WowFac\tests\verify_quest_data.py`，使用lupa.lua51在独立环境运行，不连接游戏。

本次已同步重命名目录、Lua、toc、命令、存档变量及测试入口，apiRevision仍为13。新路径下626项离线检查通过，可在仓库根目录运行 `python tests/verify_quest_data.py`，或用 `--addon addons/QuestRoute/QuestRoute.lua` 显式指定源码。

安装时完整退出游戏，禁用或移走旧 `YYQQuestAPI` 目录后复制 `addons/QuestRoute`，再启动游戏；新目录、新文件和 `.toc` 变更都需要完整重启，不能用热加载或 `/reload` 代替。SavedVariables 文件改为 `QuestRoute.lua`，不会自动读取旧文件；退出游戏后按根 README 备份并迁移旧顶层变量，已有新配置先备份，保留完整 routes 内容。

历史r13修改前checkpoint=53、保存版55和 `YYQQuestAPI-r*.zip` 备份见开发进度.md及任务交付路线.md，仍保留原名。历史M图交付和b备选显示已有截图，实机备选点击、真正交付与完整工作过程仍待验收，隔离模拟不替代现场证据。完整状态保留在待办事项.md。
