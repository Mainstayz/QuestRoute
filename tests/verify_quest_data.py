"""Offline Lua 5.1 checks of public quest-data contracts and failure isolation.

Needs lupa (tests use lupa.lua51). Example:
  python tests/verify_quest_data.py
This harness executes the installed addon against isolated, deterministic API fixtures.
It does not connect to or change the game.
"""
from pathlib import Path
import argparse
from lupa.lua51 import LuaRuntime

DEFAULT_ADDON = Path(r"C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\YYQQuestAPI\YYQQuestAPI.lua")

SETUP = r'''
Fixture = {
    mapOrder = {101, 102, 103}, pois = {}, conversionFail = {},
    worldContinent = {}, worldOffset = {}, phase = 7,
    spawns = {[17] = {{0, 0}, {-1, -1}, {55, 20, 7}}, [718] = {{20, 20}}},
    metadataVersion = 'test-version',
}
local function clone(value)
    if type(value) ~= 'table' then return value end
    local out = {}; for k,v in pairs(value) do out[k] = clone(v) end; return out
end
function canaccessvalue(value) return true end
function UnitName() return 'FixturePlayer' end
function GetRealmName() return 'FixtureRealm' end
function UnitLevel() return 19 end
function UnitXP() return 100 end
function UnitXPMax() return 1000 end
function GetXPExhaustion() return 0 end
function UnitFactionGroup() return 'Horde' end
function CreateVector2D(x,y) return {x=x,y=y} end
function IsLoggedIn() return Fixture.loggedIn or false end
function GetTime() return Fixture.time or 0 end
function IsShiftKeyDown() return Fixture.shift or false end
function UnitExists(unit) return Fixture.units and Fixture.units[unit]~=nil or false end
function UnitIsPlayer(unit) return Fixture.units[unit].player or false end
function UnitCanAttack(_,unit) return Fixture.units[unit].attack~=false end
function UnitIsDeadOrGhost(unit) return Fixture.units[unit].dead or false end
function UnitCreatureID(unit)
    local row=Fixture.units[unit]
    if row.readError then error('fixture unit identity error') end
    return row.id
end
C_NamePlate={GetNamePlates=function() return Fixture.plates or {} end}
function CreateFrame(kind,name,parent)
    local f={scripts={},events={},parent=parent}
    function f:GetFrameLevel() return self.level or 3 end
    function f:GetWidth() return self.width or 200 end
    function f:GetHeight() return self.height or 200 end
    function f:GetScale() return self.scale or 1 end
    function f:SetScale(scale) self.scale=scale end
    function f:IsShown() return self.shown~=false end
    function f:IsForbidden() return self.forbidden or false end
    function f:SetSize(w,h) self.width=w;self.height=h end
    function f:RegisterForClicks(button) self.click=button end
    function f:ClearAllPoints() self.point=nil end
    function f:SetPoint(...) self.point={...} end
    function f:SetColorTexture(...) self.color={...} end
    function f:SetTextColor(...) self.textColor={...} end
    function f:SetText(text) self.text=text end
    function f:SetThickness(value) self.thickness=value end
    function f:SetStartPoint(...) self.startPoint={...} end
    function f:SetEndPoint(...) self.endPoint={...} end
    function f:CreateTexture() return CreateFrame('Texture',nil,self) end
    function f:CreateFontString() return CreateFrame('FontString',nil,self) end
    function f:CreateLine() return CreateFrame('Line',nil,self) end
    function f:IsVisible() return self.shown~=false and (not self.parent or not self.parent.IsVisible or self.parent:IsVisible()) end
    function f:RegisterEvent(event) self.events[event]=true end
    function f:UnregisterAllEvents() self.events={} end
    function f:SetScript(event,func) self.scripts[event]=func end
    function f:GetScript(event) return self.scripts[event] end
    function f:SetAllPoints(parent) self.parent=parent end
    function f:SetFrameLevel(level) self.level=level end
    function f:EnableMouse(enabled) self.mouse=enabled end
    function f:Show() self.shown=true end
    function f:Hide() self.shown=false end
    return f
end
SlashCmdList = {}
C_PlayerInfo={GetContentDifficultyQuestForPlayer=function(id)
    local value=Fixture.difficulties and Fixture.difficulties[id]
    if value==false then return nil end
    return value or 2
end}
function HaveQuestData(id) return not (Fixture.uncached and Fixture.uncached[id]) end
function HaveQuestRewardData(id) return not (Fixture.rewardMissing and Fixture.rewardMissing[id]) end
function GetQuestLogRewardXP(id)
    assert(type(id)=='number' and id>0,'reward reads require explicit questID')
    local value=Fixture.rewards and Fixture.rewards[id]
    if value==false then return nil end
    return value or 1000
end
C_AddOns = {GetAddOnMetadata=function() return Fixture.metadataVersion end}
C_Map = {
    GetMapInfo = function(id) if id == 279 or id == 9999 then return nil end; return {mapID=id,name='Map '..id} end,
    GetBestMapForUnit = function() return Fixture.playerMapID or 101 end,
    GetPlayerMapPosition = function() return {x=Fixture.playerX or 0,y=Fixture.playerY or 0} end,
    GetMapChildrenInfo = function()
        local out = {}; for _,id in ipairs(Fixture.mapOrder) do out[#out+1] = {mapID=id} end; return out
    end,
    GetWorldPosFromMapPos = function(id,p)
        if Fixture.conversionFail[id] == 'throw' then error('fixture conversion error') end
        if Fixture.conversionFail[id] then return nil end
        return Fixture.worldContinent[id] or 1, {x=p.x*(Fixture.worldScale or 1)+(Fixture.worldOffset[id] or 0),y=p.y*(Fixture.worldScale or 1)}
    end,
}
C_QuestLog = {
    GetNumQuestLogEntries = function() return 2,2 end,
    GetInfo = function(i)
        return {questID=i,title='Official '..i,questLogIndex=i,level=19,isHeader=false}
    end,
    IsComplete = function(id) return id==2 end,
    IsFailed = function() return false end,
    ReadyForTurnIn = function(id) return id==2 end,
    GetQuestTagInfo = function(id) if id==1 then return {tagID=81,tagName='Dungeon'} end end,
    GetQuestObjectives = function() return {{text='Official skill goal',finished=false,numFulfilled=1,numRequired=1,type='object'}} end,
    GetQuestsOnMap = function(id) return clone(Fixture.pois[id] or {}) end,
    IsQuestTrivial = function(id) return Fixture.trivial and Fixture.trivial[id] or false end,
}
local mapStrings = {
    areaIdToUiMapId='return {\n [17] = 9999,\n [718] = 279,\n}',
    areaIdToUiMapIdOverride='return {\n [17] = 101,\n}',
}
local function entity(kind)
    return {
        Exists = function(id) return id ~= 999 end,
        name = function(id) return kind..id end,
        spawns = function() return clone(Fixture.spawns) end,
        npcDrops = function() return {1,2} end,
        objectDrops = function() return {3} end,
        itemDrops = function() return {4} end,
        vendors = function() return {5} end,
        startQuest = function() return 0 end,
    }
end
local quest = {
    Exists = function(id) return id ~= 999 end,
    name = function() return 'Conflicting database title' end,
    questLevel = function() return 2 end, requiredLevel = function() return 1 end,
    objectivesText = function() return {'Database trainer relation'} end,
    objectives = function() return {[1]={{5938,nil,3}}} end,
    startedBy = function() return {[1]={265810},[2]={3972},[3]={1234}} end,
    finishedBy = function() return {[2]={24776}} end,
    preQuestSingle = function() return {3} end, preQuestGroup = function() return {} end,
    childQuests = function() return {4} end, nextQuestInChain = function() return 4 end,
    exclusiveTo = function() return {} end,
}
FixtureDB = {
    addonName='QuestieDB',contractVersion=4,
    RequireContract=function() return true end,
    Quest=quest,Npc=entity('npc'),Object=entity('object'),Item=entity('item'),
    Support={Get=function() return {private=mapStrings} end},
    GetProvenance=function() return 'FixtureOwner' end,
}
LibQuestieDB=FixtureDB
function NewPOI(map,x,questID)
    return {questID=questID or 1,mapID=map,x=x,y=0,numObjectives=1,inProgress=true,isQuestStart=false}
end
'''

CHECKS = r'''
local api=WoWBridgeNS.YYQQuestAPI
local passed=0
local function check(value,label)
    if not value then error('FAIL: '..label) end
    passed=passed+1
end
local function points()
    local r=api.GetQuestPOIs({limit=100}); check(r.ok,'POI request succeeds'); return r
end
-- Projection order and canonical representative must not depend on child-map enumeration.
Fixture.pois={[101]={NewPOI(103,.01)},[102]={NewPOI(103,.012)},[103]={NewPOI(103,.011)}}
local r=points()
check(r.total==1 and r.pois[1].coordinateMapID==103 and r.pois[1].projectionCount==3,'native-map representative')
Fixture.mapOrder={103,101,102}; local reverse=points()
check(reverse.total==r.total and reverse.pois[1].x==r.pois[1].x,'map traversal order independent')
-- Fixed representative prevents A-B-C proximity chains from collapsing distant A/C.
Fixture.mapOrder={101,102,103}
Fixture.pois={[101]={NewPOI(101,0)},[102]={NewPOI(102,.09)},[103]={NewPOI(103,.18)}}
r=points(); check(r.total==2,'no transitive proximity collapse')
-- Threshold, separate world spaces, physically distinct points.
Fixture.pois={[101]={NewPOI(101,0)},[102]={NewPOI(101,.1)}}
r=points(); check(r.total==1,'distance 0.1 included')
Fixture.pois[102][1].x=.10001
r=points(); check(r.total==2,'distance greater than 0.1 excluded')
Fixture.pois[102][1].x=0; Fixture.worldContinent[102]=2
r=points(); check(r.total==2,'different continents preserved')
Fixture.worldContinent={}
-- A failed conversion retains the projected map frame instead of fabricating world coords.
Fixture.conversionFail={[102]=true}
r=points(); check(r.total==2,'nil world conversion preserves record')
local failed
for _,p in ipairs(r.pois) do if p.coordinateMapID==102 then failed=p end end
check(failed and not failed.worldAvailable and failed.worldUnavailableReason=='conversion_unavailable','world conversion reason')
Fixture.conversionFail[102]='throw'
r=points(); check(r.total==2,'throwing world conversion isolated')
Fixture.conversionFail={}
-- Semantic flags and real locations must survive deduplication.
Fixture.pois={[101]={NewPOI(101,0),NewPOI(101,.5)}}
Fixture.pois[101][2].isQuestStart=true
r=points(); check(r.total==2,'different semantic points retained')
-- Pagination happens after filtering and deduplication, on flat records.
Fixture.pois={[101]={NewPOI(101,0),NewPOI(101,.5),NewPOI(101,0,2)}}
r=points()
for i=0,r.total-1 do
    local page=api.GetQuestPOIs({offset=i,limit=1})
    check(page.total==r.total and page.pois[1].questID==r.pois[i+1].questID and page.pois[1].x==r.pois[i+1].x,'stable POI pages')
end
check(api.GetQuestPOIs({offset=1000}).count==0,'out-of-range empty POI page')
check(api.GetQuestPOIs({questID=999}).total==0,'not-in-log filter')
-- A secret-like failure is not fabricated into a coordinate; zero itself remains valid.
local context=api.GetPlayerContext({})
check(context.location.available and context.location.x==0,'zero coordinate valid')
-- DB coordinate units, overrides, phase, sentinel, nonexistent maps, flat pagination.
local entity=api.GetDatabaseEntity({kind='npc',id=1,limit=1})
check(entity.total==4 and entity.count==1 and entity.hasMore,'flat location pagination')
check(entity.locations[1].coordinateMapID==101 and entity.locations[1].available and entity.locations[1].x==0,'override and zero coordinate')
local sentinel=api.GetDatabaseEntity({kind='npc',id=1,offset=1,limit=1}).locations[1]
check(not sentinel.available and sentinel.reason=='instance_only' and sentinel.x==nil,'sentinel not navigable')
local phased=api.GetDatabaseEntity({kind='npc',id=1,offset=2,limit=1}).locations[1]
check(phased.phase==7 and phased.x==.55 and phased.originalX==55,'phase and coordinate units retained')
local invalidMap=api.GetDatabaseEntity({kind='npc',id=1,offset=3,limit=1}).locations[1]
check(not invalidMap.available and invalidMap.reason=='unsupported_map','unsupported map retained')
check(api.GetDatabaseEntity({kind='npc',id=999}).reason=='entity_not_found','unknown entity')
Fixture.spawns={}
check(api.GetDatabaseEntity({kind='npc',id=1}).locationAvailability=='missing','known entity missing coordinates')
Fixture.spawns={[17]={{1,2}}}
-- 1,001 points are paged; details do not recursively embed their geometry.
Fixture.spawns[17]={}; for i=1,1001 do Fixture.spawns[17][i]={i/20,25} end
entity=api.GetDatabaseEntity({kind='npc',id=1,limit=100})
check(entity.total==1001 and entity.count==100 and entity.nextOffset==100,'large location set bounded')
local details=api.GetQuestDetails({questID=1,limit=1})
check(details.database.count==1 and details.database.hasMore and details.database.locations==nil,'details paginate references without locations')
check(details.official.quest.title=='Official 1' and details.official.quest.objectives[1].text=='Official skill goal','official data wins')
check(details.database.objectiveIndexMapping=='not_inferred','no invented objective order')
check(details.official.quest.tag.id==81 and details.official.quest.tag.name=='Dungeon','native dungeon tag retained')
local full=api.GetQuestDetails({questID=1,limit=100})
local hasItemStart,hasObjectEnd=false,false
for _,ref in ipairs(full.database.references) do
    if ref.role=='quest_start' and ref.kind=='item' then hasItemStart=true end
    if ref.role=='quest_turn_in' and ref.kind=='object' and ref.id==24776 then hasObjectEnd=true end
end
check(hasItemStart and hasObjectEnd,'starter/finisher entity kinds retained')
local pending=api.GetQuestDetails({questID=2})
check(pending.official.quest.status=='ready_for_turn_in','native turn-in status wins over inProgress')
check(not api.GetQuestDetails({questID=999}).official.available,'unknown quest not fabricated')
local item=api.GetDatabaseEntity({kind='item',id=1,limit=2})
check(item.total==5 and item.count==2 and item.hasMore,'direct item relations paginated')
-- No DB at addon load/call time, incompatible contract, getter error, late load.
local db=LibQuestieDB
LibQuestieDB=nil
check(api.GetQuestDetails({questID=1}).official.available,'DB absence preserves native details')
check(api.GetDatabaseEntity({kind='npc',id=1}).reason=='not_loaded','DB absence explicit')
check(api.GetQuests({}).ok and api.GetQuestPOIs({}).ok,'native reads independent of DB')
LibQuestieDB=db
check(api.GetDatabaseEntity({kind='npc',id=1}).available,'late DB detected')
local contract=db.RequireContract
 db.RequireContract=function() return false end
check(api.GetDatabaseEntity({kind='npc',id=1}).reason=='unsupported_contract','contract mismatch explicit')
db.RequireContract=contract
local name=db.Quest.name; db.Quest.name=function() error('fixture DB read failure') end
local broken=api.GetQuestDetails({questID=1})
check(broken.ok and broken.official.available and broken.database.reason=='database_error','DB getter error isolated')
db.Quest.name=name
local spawns=db.Npc.spawns;db.Npc.spawns=function() error('fixture entity failure') end
check(api.GetDatabaseEntity({kind='npc',id=1}).error.code=='database_error','entity read error explicit')
db.Npc.spawns=spawns
local disabled=api.GetQuestDetails({questID=1,allowDatabase=false})
check(disabled.database.reason=='disabled_by_request' and disabled.official.available,'DB disabled per request')
-- Existing API contract and input validation.
local old=api.GetQuests({includeObjectives=false})
check(old.schemaVersion==1 and old.limit==100 and old.quests[1].objectives==nil,'old get_quests compatibility')
local cases={
    {api.GetQuestPOIs,{limit=0}},{api.GetQuestPOIs,{limit=101}},{api.GetQuestPOIs,{offset=-1}},
    {api.GetQuestPOIs,{mapID='101'}},{api.GetQuestPOIs,{mapID=9999}},
    {api.GetQuestPOIs,{limit=0/0}},{api.GetQuestPOIs,{offset=math.huge}},
    {api.GetQuestDetails,{questID=0}},{api.GetQuestDetails,{questID=1,allowDatabase='false'}},
    {api.GetDatabaseEntity,{kind='unknown',id=1}},{api.GetDatabaseEntity,{kind='npc',id=1.5}},
}
for _,c in ipairs(cases) do
    local value=c[1](c[2]);check(not value.ok and value.error.code=='invalid_arguments','invalid arguments')
end
-- Route contracts: only straight distance, mandatory filters, skip state, displacement threshold.
Fixture.worldScale=1000
Fixture.mapOrder={101,102,103}
Fixture.pois={[101]={}}
for id=101,107 do Fixture.pois[101][#Fixture.pois[101]+1]=NewPOI(101,(id-100)/10,id) end
C_QuestLog.GetNumQuestLogEntries=function() return 7,7 end
C_QuestLog.GetInfo=function(i) return {questID=100+i,title='Route '..(100+i),level=40,questLogIndex=i} end
C_QuestLog.GetQuestTagInfo=function(id) if id==104 then return {tagID=81,tagName='Dungeon'} end end
C_QuestLog.GetQuestType=function(id) return id==104 and 81 or 0 end
C_QuestLog.IsEliteQuest=function(id) return id==105 end
C_QuestLog.IsFailed=function(id) return id==107 end
C_QuestLog.IsComplete=function(id) return id==102 end
C_QuestLog.ReadyForTurnIn=function(id) return id==102 end
FixtureDB.Quest.requiredSkill=function(id) if id==106 then return {356,1} end end
local plan=api.Replan({})
check(plan.count==3,'instance elite profession and failed excluded')
check(plan.steps[1].questID==101 and plan.steps[2].questID==102 and plan.steps[3].questID==103,'nearest neighbor order')
check(plan.steps[1].level==40,'no unsolicited quest level filter')
check(plan.steps[2].action=='turn_in','turn-in action preserved')
local why={};for _,q in ipairs(plan.excluded) do why[q.questID]=q.reason end
check(why[104]=='instance' and why[105]=='elite' and why[106]=='profession','filter reasons')
api.SetQuestSkip({questID=102})
plan=api.GetPlan({})
check(plan.count==2 and plan.steps[1].questID==101 and plan.steps[2].questID==103,'skip removes entire quest')
check(YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped[102],'skip saved per character')
api.SetQuestSkip({questID=102,skipped=false})
check(api.GetPlan({}).count==3,'restore skipped quest')
-- Tick without the map: movement below threshold does not trigger replanning.
Fixture.loggedIn=true
Fixture.time=100
api.StartRoute()
local driver=api.route.driver
local tick=driver:GetScript('OnUpdate')
local sequence=api.GetPlan({}).sequence
Fixture.playerX=.05;Fixture.time=101;tick(driver,.5)
check(api.GetPlan({}).sequence==sequence,'50 unit displacement below 100 threshold')
Fixture.playerX=.1;Fixture.time=102;tick(driver,.5)
check(api.GetPlan({}).sequence==sequence+1 and api.GetPlan({}).reason=='player_moved','100 unit displacement replans')
sequence=api.GetPlan({}).sequence
Fixture.playerX=.15;Fixture.time=103;tick(driver,.5)
check(api.GetPlan({}).sequence==sequence,'threshold measured from last plan origin')
Fixture.playerX=.21;Fixture.time=104;tick(driver,.5)
check(api.GetPlan({}).sequence==sequence+1,'cumulative displacement from plan triggers')
sequence=api.GetPlan({}).sequence
local onEvent=driver:GetScript('OnEvent')
onEvent(driver,'QUEST_LOG_UPDATE')
Fixture.time=104.2;tick(driver,.5)
check(api.GetPlan({}).sequence==sequence,'quest events debounced')
Fixture.time=104.7;tick(driver,.5)
check(api.GetPlan({}).sequence==sequence+1,'quest progress triggers replan')
api.SetRouteOptions({moveThreshold=200})
check(api.GetPlan({}).moveThreshold==200,'movement threshold adjustable')
check(not api.SetRouteOptions({moveThreshold=0}).ok,'invalid threshold rejected')
api.SetRouteOptions({enabled=false})
check(not api.GetPlan({}).enabled,'display off stored')
api.SetRouteOptions({enabled=true,moveThreshold=100})
api.SetQuestSkip({questID=101});api.ResetQuestSkips({})
check(api.GetPlan({}).count==3,'all skips reset')
-- Lifecycle reuses driver and clears polling before reload.
api.OnUnload()
check(driver:GetScript('OnUpdate')==nil and next(driver.events)==nil,'unload stops driver')
api.OnReload()
check(api.route.driver==driver and driver:GetScript('OnUpdate')~=nil,'reload reuses driver')
local started=api.GetPlan({}).sequence
api.StartRoute()
check(api.GetPlan({}).sequence==started,'initialization idempotent')
-- Regression: a foreign target can project inside the current map (including extremely nearby points).
Fixture.playerX=0;Fixture.playerMapID=101;Fixture.time=200
C_QuestLog.GetNumQuestLogEntries=function() return 10,10 end
Fixture.questLevels={}
C_QuestLog.GetInfo=function(i)
    local id=100+i
    return {questID=id,title='Route '..id,level=Fixture.questLevels[id] or 40,questLogIndex=i}
end
Fixture.pois[101][#Fixture.pois[101]+1]=NewPOI(102,.00001,108)
Fixture.pois[101][#Fixture.pois[101]+1]=NewPOI(103,.00002,109)
Fixture.pois[101][#Fixture.pois[101]+1]=NewPOI(102,.00003,110)
Fixture.pois[101][#Fixture.pois[101]+1]=NewPOI(101,.9,110)
plan=api.Replan({})
check(plan.count==4 and plan.mapID==101 and plan.scope=='current_player_map_active_quests','current player map only')
why={};for _,q in ipairs(plan.excluded) do why[q.questID]=q.reason end
check(why[108]=='outside_current_map' and why[109]=='outside_current_map','near foreign projections excluded')
local multi
for _,q in ipairs(plan.steps) do
    check(q.targetMapID==101,'every selected target owned by player map')
    if q.questID==110 then multi=q end
end
check(multi and multi.x==.9,'multi-location quest uses local point not nearer foreign point')
-- r7 replaces level-gap bonuses: native difficulty wins; labels/unknown levels do not imply good XP.
Fixture.questLevels={[101]=19,[102]=16,[103]=14,[110]=19}
Fixture.pois[101][2].x=.15
Fixture.pois[101][3].x=.4
Fixture.difficulties={[103]=0};Fixture.trivial={[103]=true};Fixture.rewards={[103]=100}
plan=api.Replan({})
check(plan.steps[1].questID==101,'farther old low-level quest no longer wins only by level gap')
check(math.abs(plan.steps[1].weightedDistance-plan.steps[1].segmentDistance/plan.steps[1].priorityWeight)<.0001,'score still physical distance divided by weight')
local measured={};for _,q in ipairs(plan.steps) do measured[q.questID]=q end
check(measured[103].priorityWeight<1,'native trivial task is deprioritized')
Fixture.questLevels[103]=1
plan=api.Replan({})
for _,q in ipairs(plan.steps) do if q.questID==103 then check(q.priorityWeight<1,'very low levels do not regain old double bonus') end end
Fixture.questLevels[102]=19
plan=api.Replan({})
check(plan.steps[1].questID==101,'fair difficulty keeps nearby task first')
Fixture.difficulties={};Fixture.trivial={};Fixture.rewards={}
Fixture.questLevels[103]=0
plan=api.Replan({})
for _,q in ipairs(plan.steps) do if q.questID==103 then check(q.priorityWeight==1,'unknown level zero does not invent difficulty') end end
Fixture.questLevels[103]=-1
plan=api.Replan({})
for _,q in ipairs(plan.steps) do if q.questID==103 then check(q.priorityWeight==1,'dynamic level sentinel relies on native difficulty') end end
Fixture.questLevels[103]=40;Fixture.questLevels[102]=14;Fixture.pois[101][2].x=.5
plan=api.Replan({})
check(plan.steps[1].questID==101,'far low-level does not override much closer task')
Fixture.questLevels[101]=40
local unitLevel=UnitLevel;UnitLevel=function() return nil end
plan=api.Replan({})
check(plan.levelPriority.referenceLevel==nil,'unknown player level supported')
for _,q in ipairs(plan.steps) do check(q.priorityWeight==1,'fair native difficulty works without player level') end
UnitLevel=unitLevel;api.Replan({})
-- Cross a map boundary with zero world displacement: immediately replace local route.
Fixture.playerMapID=102;Fixture.time=201
local activeTick=driver:GetScript('OnUpdate')
activeTick(driver,.5)
plan=api.GetPlan({})
check(plan.mapID==102 and plan.reason=='player_map_changed','map change replans below movement threshold')
check(plan.count==2,'new map activates only its two targets')
for _,q in ipairs(plan.steps) do check(q.targetMapID==102,'new map target ownership') end
Fixture.playerMapID=101;Fixture.time=202;activeTick(driver,.5)
check(api.GetPlan({}).mapID==101 and api.GetPlan({}).count==4,'returning map restores its local candidates')
-- Browsing a different map never changes planning scope and hides the old region overlay.
local canvas={GetFrameLevel=function() return 3 end,GetWidth=function() return 1002 end,GetHeight=function() return 668 end}
WorldMapFrame={GetCanvas=function() return canvas end,GetMapID=function() return 102 end,IsShown=function() return true end}
sequence=api.GetPlan({}).sequence
Fixture.time=203;activeTick(driver,.5)
check(api.GetPlan({}).mapID==101 and api.GetPlan({}).sequence==sequence,'viewed map does not change player scope')
check(api.route.views[1].overlay.shown==false,'viewing other region hides local route overlay')
WorldMapFrame=nil
-- Level changes refresh weights even when standing still.
UnitLevel=function() return 20 end
Fixture.time=204;activeTick(driver,.5)
check(api.GetPlan({}).reason=='player_level_changed' and api.GetPlan({}).levelPriority.referenceLevel==20,'level-up recalculates weights')
UnitLevel=unitLevel
-- Minimap integration: known cardinal points, actual radius, rotation, geometry clipping, lifecycle.
Fixture.playerX=.5;Fixture.playerY=.5;Fixture.playerMapID=101
Fixture.radius=100;Fixture.rotate=false;Fixture.ignoreRotation=false;Fixture.facing=0
C_Minimap={GetViewRadius=function() return Fixture.radius end,IsRotateMinimapIgnored=function() return Fixture.ignoreRotation end}
C_CVar={GetCVarBool=function() return Fixture.rotate end}
function GetPlayerFacing() return Fixture.facing end
Minimap=CreateFrame('Minimap');Minimap:SetSize(200,200);Minimap:Show()
C_QuestLog.GetNumQuestLogEntries=function() return 3,3 end
C_QuestLog.GetInfo=function(i) return {questID=100+i,title='Mini '..i,level=19,questLogIndex=i} end
C_QuestLog.IsFailed=function() return false end
C_QuestLog.IsEliteQuest=function() return false end
C_QuestLog.GetQuestType=function() return 0 end
Fixture.pois={[101]={NewPOI(101,.55,101),NewPOI(101,.8,102),NewPOI(101,.9,103)}}
for _,p in ipairs(Fixture.pois[101]) do p.y=.5 end
plan=api.Replan({})
local function miniTick() Fixture.time=Fixture.time+1;activeTick(driver,.2) end
local function near(a,b) return math.abs(a-b)<.00001 end
miniTick()
local mini=api.route.minimapView
check(mini and mini.overlay:IsVisible() and WorldMapFrame==nil,'minimap renders while world map closed')
local pin=mini.pins[1]
check(near(pin.point[4],0) and near(pin.point[5],50),'north target 50 yards at radius100 is halfway up')
check(pin.step.questID==101 and not pin.onEdge,'nearby first target numbered at actual point')
check(not mini.pins[2] or not mini.pins[2]:IsVisible(),'far future target not clamped into fake point')
check(mini.lines[1]:IsVisible() and mini.lines[2]:IsVisible(),'nearby route segment and boundary continuation visible')
check(not mini.lines[3] or not mini.lines[3]:IsVisible(),'wholly outside segment hidden')
Fixture.radius=200;miniTick()
check(near(pin.point[5],25),'view radius change updates without replan')
Fixture.radius=100;Fixture.rotate=true;Fixture.facing=math.pi/2;miniTick()
check(near(pin.point[4],50) and near(pin.point[5],0),'west-facing rotation puts north on right')
Fixture.ignoreRotation=true;miniTick()
check(near(pin.point[4],0) and near(pin.point[5],50),'ignored rotation keeps north-up')
Fixture.ignoreRotation=false;Fixture.rotate=false
-- Next objective outside viewport: only its marker at rim; actual leg clipped at round border.
plan=api.GetPlan({})
plan.steps[1].world={continentID=1,x=800,y=500}
plan.steps[2].world={continentID=1,x=900,y=900}
plan.navigation=nil -- Geometry-only fixtures intentionally replace route destinations.
miniTick()
check(pin.onEdge and near(pin.point[4],0) and near(pin.point[5],84),'offscreen next objective direction at inner rim')
check(near(mini.lines[1].endPoint[4],90) and near(mini.lines[1].startPoint[4],7),'line clipped to circle with gap for player arrow')
check(not mini.lines[2]:IsVisible(),'no phantom connection between clamped edge pins')
-- Outside-to-outside segment passing through the circle must retain its actual chord.
plan.steps[1].world={continentID=1,x=500,y=800}
plan.steps[2].world={continentID=1,x=500,y=200}
plan.navigation=nil
miniTick()
local chord=mini.lines[2]
check(chord:IsVisible() and near(chord.startPoint[3],-90) and near(chord.endPoint[3],90),'circle-crossing outside endpoints clipped to diameter')
-- Moving across the point updates its direction, without waiting 100 yards to replan.
plan.steps[1].world={continentID=1,x=550,y=500}
plan.navigation=nil
Fixture.playerX=.56;miniTick()
check(not pin.onEdge and pin.point[5]<0,'subthreshold movement updates target projection')
-- Independent map masks/size and display state do not create unbounded geometry.
Minimap:SetSize(240,120);miniTick()
for _,line in pairs(mini.lines) do
    if line:IsVisible() then
        for _,point in ipairs({line.startPoint,line.endPoint}) do
            check((point[3]/120)^2+(point[4]/60)^2<=.9^2+.00001,'all endpoints inside minimap ellipse')
        end
    end
end
local wasEnabled=plan.enabled;plan.enabled=false;miniTick()
check(not mini.overlay:IsVisible(),'route off hides minimap')
plan.enabled=wasEnabled;Minimap:Hide();miniTick()
check(not mini.overlay:IsVisible(),'hidden minimap hides overlay')
Minimap:Show();Fixture.radius=0;miniTick()
check(not mini.overlay:IsVisible(),'invalid view radius hides geometry')
Fixture.radius=100;Fixture.rotate=true;Fixture.facing=nil;miniTick()
check(not mini.overlay:IsVisible(),'missing facing under rotation hides stale direction')
Fixture.rotate=false;Fixture.facing=0;miniTick()
local cached=api.route.minimapView
api.OnUnload()
check(not cached.overlay:IsVisible() and pin.step==nil,'hot unload hides minimap and clears target references')
api.OnReload()
check(api.route.minimapView==cached and cached.overlay:IsVisible(),'hot reload reuses minimap overlay')
-- Reuse the same right-click interaction on small-map pins; restore the fixture afterward.
local pinID=mini.pins[1].step.questID
GameTooltip={Hide=function() end}
mini.pins[1]:GetScript('OnClick')(mini.pins[1],'RightButton')
check(YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped[pinID],'minimap right click uses quest skip')
api.SetQuestSkip({questID=pinID,skipped=false})
-- Intelligent route scenarios use independent quest rows; they never touch the live game.
Minimap=nil;WorldMapFrame=nil
Fixture.worldScale=1000;Fixture.playerMapID=101;Fixture.playerY=0;Fixture.time=1000
FixtureDB.Quest.requiredSkill=function() return nil end
local function routeRow(id,x,extra)
    local row=extra or {};row.id=id;row.x=x;return row
end
local function rowFor(id) for _,row in ipairs(Fixture.routeRows) do if row.id==id then return row end end end
C_QuestLog.GetNumQuestLogEntries=function() return #Fixture.routeRows,#Fixture.routeRows end
C_QuestLog.GetInfo=function(i)
    local row=Fixture.routeRows[i]
    return {questID=row.id,title='Stable '..row.id,level=row.level or 19,questLogIndex=i}
end
C_QuestLog.GetQuestTagInfo=function() return nil end
C_QuestLog.IsComplete=function(id) local row=rowFor(id);return row and (row.complete or row.ready) or false end
C_QuestLog.ReadyForTurnIn=function(id) local row=rowFor(id);return row and row.ready or false end
C_QuestLog.IsFailed=function(id) local row=rowFor(id);return row and row.failed or false end
C_PlayerInfo.GetContentDifficultyQuestForPlayer=function(id)
    local row=rowFor(id);if row.difficulty==false then return nil end
    return row.difficulty or 2
end
C_QuestLog.IsQuestTrivial=function(id) local row=rowFor(id);return row.trivial or false end
function HaveQuestData(id) return not rowFor(id).uncached end
function HaveQuestRewardData(id) return not rowFor(id).rewardMissing end
function GetQuestLogRewardXP(id)
    assert(type(id)=='number' and rowFor(id),'explicit active questID required')
    local row=rowFor(id);if row.xp==false then return nil end
    return row.xp or 1000
end
C_QuestLog.GetQuestObjectives=function(id)
    local row=rowFor(id)
    if row.missing then return nil end
    if row.empty then return {} end
    if row.readError then error('temporary objective cache failure') end
    if row.objectives then return row.objectives end
    return {{type=row.kind or 'monster',text='Goal '..id..': '..(row.fulfilled or 0)..'/'..(row.required or 10),
        numFulfilled=row.fulfilled or 0,numRequired=row.required or 10,finished=row.finished or false}}
end
local function syncPOIs()
    Fixture.pois={[101]={}}
    for _,row in ipairs(Fixture.routeRows) do
        if not row.noPOI then
            local poi=NewPOI(row.map or 101,row.x/Fixture.worldScale,row.id);poi.y=(row.y or 0)/Fixture.worldScale
            Fixture.pois[101][#Fixture.pois[101]+1]=poi
            for _,x in ipairs(row.otherX or {}) do Fixture.pois[101][#Fixture.pois[101]+1]=NewPOI(row.map or 101,x/Fixture.worldScale,row.id) end
        end
    end
end
local function scenario(rows,playerX)
    Fixture.routeRows=rows;Fixture.playerX=(playerX or 0)/Fixture.worldScale;Fixture.playerY=0
    Fixture.playerMapID=101;Fixture.time=Fixture.time+10
    api.route.plan=nil;api.route.progress={};api.route.spotAvoidances={};api.route.nextSpotCheck=nil
    YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped={}
    syncPOIs();return api.Replan({})
end
local function autoPlan()
    syncPOIs()
    local d=api.route.driver
    d:GetScript('OnEvent')(d,'QUEST_LOG_UPDATE')
    Fixture.time=Fixture.time+1
    d:GetScript('OnUpdate')(d,.2)
    return api.GetPlan({})
end
-- The incumbent is a little worse after walking: keep it, but honor manual replan.
local rows={routeRow(201,500),routeRow(202,900)}
plan=scenario(rows)
check(plan.steps[1].questID==201,'stability baseline picks weighted nearest')
Fixture.playerX=.73;plan=autoPlan()
check(plan.steps[1].questID==201 and plan.stability.reason=='avoid_small_switch','small improvement does not reverse direction')
plan=api.Replan({})
check(plan.steps[1].questID==202 and plan.stability.reason=='manual_replan','manual replan immediately bypasses hold')
-- Clearly better (>30% and >=50 weighted yards), then repeated updates stay on chosen target.
scenario({routeRow(201,500),routeRow(202,900)})
Fixture.playerX=.76;plan=autoPlan()
check(plan.steps[1].questID==202 and plan.stability.reason=='clearly_better_candidate','large improvement switches target')
local target=plan.steps[1].questID
for i=1,3 do plan=autoPlan() end
check(plan.steps[1].questID==target,'repeated quest events do not bounce target')
-- A ratio improvement alone on short distances must not trigger a pointless switch.
scenario({routeRow(201,200,{ready=true}),routeRow(202,300,{ready=true})})
Fixture.playerX=.26;plan=autoPlan()
check(plan.steps[1].questID==201,'ratio threshold alone cannot override minimum saving')
-- When actually at the objective, strong alternatives do not pull player away.
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);rows[2].x=610;Fixture.playerX=.6;plan=autoPlan()
check(plan.steps[1].questID==201 and plan.stability.reason=='at_objective_area','working at objective retains first even against much closer alternative')
check(plan.steps[1].status=='in_progress' and not rowFor(201).complete,'arrival never fabricates quest completion')
-- Recent actual progress extends work area to300 yards; loading objectives does not count.
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);rows[1].fulfilled=1;rows[2].x=750;Fixture.playerX=.76
plan=autoPlan()
check(plan.steps[1].questID==201 and plan.stability.reason=='recent_objective_progress','count increase holds ongoing task within work area')
local progressAt=api.route.progress[201].lastProgressAt
rows[1].missing=true;plan=autoPlan()
check(api.route.progress[201].lastProgressAt==progressAt,'temporarily missing objectives preserve real progress timestamp')
rows[1].missing=false;rows[1].empty=true;plan=autoPlan()
check(api.route.progress[201].lastProgressAt==progressAt,'empty target cache is not treated as completed or reset')
rows[1].empty=false;Fixture.time=Fixture.time+91;plan=autoPlan()
check(plan.steps[1].questID==202,'expired progress protection releases when other task clearly better')
rows={routeRow(201,500,{missing=true}),routeRow(202,900)}
scenario(rows);rows[1].missing=false;rows[1].fulfilled=5;rows[2].x=750;Fixture.playerX=.76
plan=autoPlan()
check(plan.steps[1].questID==202 and not api.route.progress[201].lastProgressAt,'first objective data load is not fabricated progress')
-- A nearby old point moving to a new target area must not remain a locked destination.
rows={routeRow(201,400),routeRow(202,900)}
scenario(rows);rows[1].x=950;rows[2].x=410;Fixture.playerX=.4;plan=autoPlan()
check(plan.steps[1].questID==202 and not plan.stability.retained,'large POI change releases old target')
rows={routeRow(201,400),routeRow(202,900)}
scenario(rows);rows[1].fulfilled=1;rows[2].x=750;Fixture.playerX=.76;plan=autoPlan()
check(plan.steps[1].questID==202,'progress outside300yard work area does not trap route')
-- Readiness/completion, filtering, missing targets, and skips override previous working lock.
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);rows[1].ready=true;rows[1].x=950;rows[2].x=610;Fixture.playerX=.6
plan=autoPlan()
check(plan.steps[1].questID==202,'completion and new turnin location release former objective')
local turnin;for _,s in ipairs(plan.steps) do if s.questID==201 then turnin=s end end
check(turnin and turnin.action=='turn_in' and turnin.world.x==950,'completed task now routes to refreshed native turnin point')
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);rows[1].failed=true;Fixture.playerX=.5;plan=autoPlan()
check(plan.steps[1].questID==202,'failed incumbent excluded despite proximity')
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);rows[1].map=102;Fixture.playerX=.5;plan=autoPlan()
check(plan.steps[1].questID==202,'target leaving current map releases working lock')
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);rows[1].noPOI=true;plan=autoPlan()
check(plan.steps[1].questID==202,'target coordinate disappearance never keeps stale destination')
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);table.remove(rows,1);plan=autoPlan()
check(plan.steps[1].questID==202 and api.route.progress[201]==nil,'removed quest pruned from route and progress cache')
scenario({routeRow(201,500),routeRow(202,900)});Fixture.playerX=.5;autoPlan()
api.SetQuestSkip({questID=201});plan=api.GetPlan({})
check(plan.steps[1].questID==202,'skip overrides incumbent working area')
-- Release working hold even when only IsComplete is available, not ReadyForTurnIn yet.
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);rows[1].complete=true;rows[1].x=950;rows[2].x=610;Fixture.playerX=.6;plan=autoPlan()
check(plan.steps[1].questID==202,'IsComplete alone releases active working lock')
for _,s in ipairs(plan.steps) do if s.questID==201 then check(s.action=='completion_pending','completed without ready flag never advertised as doing objectives') end end
-- Exact hysteresis boundaries use weighted distances, not incorrectly unscaled squares.
for _,case in ipairs({{200,160,false},{200,140,true},{150,105,false},{150,100,true}}) do
    rows={routeRow(201,case[1],{ready=true}),routeRow(202,900,{ready=true})}
    scenario(rows);rows[2].x=case[2];plan=autoPlan()
    check((plan.steps[1].questID==202)==case[3],'ratio and minimum-saving threshold boundary')
end
for _,distance in ipairs({120,120.01}) do
    rows={routeRow(201,distance),routeRow(202,900)}
    scenario(rows);rows[2].x=10;plan=autoPlan()
    check((plan.steps[1].questID==201)==(distance==120),'arrival radius equality and just outside')
end
for _,shift in ipairs({100,100.01}) do
    rows={routeRow(201,500),routeRow(202,900)}
    scenario(rows);rows[1].x=500+shift;rows[2].x=551;Fixture.playerX=.55;plan=autoPlan()
    check((plan.steps[1].questID==201)==(shift==100),'POI movement tolerance equality and just outside')
end
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);rows[1].fulfilled=1;rows[2].x=210;Fixture.playerX=.2;plan=autoPlan()
check(plan.steps[1].questID==201,'recent work300yard equality retains target')
Fixture.time=Fixture.time+89;plan=autoPlan()
check(plan.steps[1].questID==201 and plan.stability.reason=='recent_objective_progress','recent work90second equality retains target')
Fixture.time=Fixture.time+.01;plan=autoPlan()
check(plan.steps[1].questID==202,'recent progress protection expires after90seconds')
-- Counts resetting, rearranged targets and another quest progress cannot create protection.
rows={routeRow(201,500,{fulfilled=3}),routeRow(202,900)}
scenario(rows);rows[1].fulfilled=2;rows[2].x=750;rows[2].fulfilled=1;Fixture.playerX=.76;plan=autoPlan()
check(plan.steps[1].questID==202 and not api.route.progress[201].lastProgressAt,'regression and other quest progress do not count for incumbent')
rows={routeRow(201,500),routeRow(202,900)}
rows[1].objectives={{type='monster',text='Wolf: 3/10',numFulfilled=3,numRequired=10,finished=false},
    {type='monster',text='Boar: 0/10',numFulfilled=0,numRequired=10,finished=false}}
scenario(rows)
rows[1].objectives={rows[1].objectives[2],rows[1].objectives[1]}
rows[2].x=750;Fixture.playerX=.76;plan=autoPlan()
check(plan.steps[1].questID==202 and not api.route.progress[201].lastProgressAt,'reordered objectives are baseline changes not progress')
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);rows[1].fulfilled=1;rows[2].x=750;Fixture.playerX=.76;autoPlan()
progressAt=api.route.progress[201].lastProgressAt
rows[1].readError=true;plan=autoPlan()
check(plan.ok and api.route.progress[201].lastProgressAt==progressAt,'throwing objective read isolated and snapshot preserved')
rows[1].readError=false;plan=autoPlan()
check(api.route.progress[201].lastProgressAt==progressAt,'same counters after cache recovery do not refresh time')
-- Alternative locations for the same task remain distinct destinations, and grouping selects a real local point.
rows={routeRow(201,500,{otherX={900}}),routeRow(202,700)}
scenario(rows);Fixture.playerX=.89;plan=autoPlan()
check(plan.steps[1].questID==201 and plan.steps[1].world.x==900,'same quest can switch to clearly nearer alternative POI')
rows={routeRow(201,500),routeRow(202,300,{otherX={900}}),routeRow(203,880)}
plan=scenario(rows,500)
check(plan.steps[2].questID==202 and plan.steps[2].world.x==300,'group chooses only qualifying location of multi-POI quest')
-- Fixed-anchor grouping: a B-C bridge must not bypass another task still in A's area.
plan=scenario({routeRow(201,500),routeRow(202,690),routeRow(203,880),routeRow(204,305)},500)
check(plan.steps[1].questID==201 and plan.steps[2].questID==202 and plan.steps[3].questID==204 and plan.steps[4].questID==203,'complete A-B-D-C order prevents transitive bridge')
check(#plan.groups==2 and plan.steps[1].groupSize==3 and plan.steps[4].groupSize==1,'group membership is fixed to original area anchor')
local seen={}
for _,s in ipairs(plan.steps) do
    check(not seen[s.questID],'grouped route does not duplicate quests');seen[s.questID]=true
    local anchor=plan.groups[s.groupIndex].anchor
    check((s.world.x-anchor.x)^2+(s.world.y-anchor.y)^2<=200^2+.00001,'all group members remain within original200yard anchor')
end
plan=scenario({routeRow(201,500),routeRow(202,700),routeRow(203,700.01)},500)
check(plan.steps[2].groupIndex==1 and plan.steps[3].groupIndex==2,'200yard group boundary included and farther point starts new group')
plan=scenario({routeRow(201,200),routeRow(202,390),routeRow(203,700,{level=14,difficulty=1}),routeRow(204,5)},200)
check(plan.steps[3].questID==204 and plan.steps[4].questID==203,'nearby ordinary task precedes leaving area for lower-level task')
-- Finish nearby group after completing first task, but manual replan bypasses group continuity.
rows={routeRow(201,500),routeRow(202,680),routeRow(203,710,{level=14,difficulty=1})}
plan=scenario(rows,500);check(plan.groups[1].count==2,'local group baseline')
table.remove(rows,1);Fixture.playerX=.52;plan=autoPlan()
check(plan.steps[1].questID==202 and plan.stability.reason=='continue_nearby_group','completed incumbent continues remaining local task')
check(plan.groups[1].anchor.x==500,'group anchor does not drift across replans')
plan=api.Replan({})
check(plan.steps[1].questID==203 and plan.groups[1].anchor.x==710,'manual replan resets old target and old area preference')
plan=autoPlan();check(plan.steps[1].questID==203,'ordinary event after manual choice never resurrects old hold')
-- API and slash both release a target protected by proximity and real objective progress.
rows={routeRow(201,500),routeRow(202,900)}
scenario(rows);rows[1].fulfilled=1;rows[2].x=610;Fixture.playerX=.6;plan=autoPlan()
check(plan.steps[1].questID==201,'protected target before slash replan')
SlashCmdList['YYQROUTE']('replan');plan=api.GetPlan({})
check(plan.steps[1].questID==202 and plan.stability.reason=='manual_replan','slash replan bypasses proximity and progress protection')
-- Read-only POIs changing to no available location should yield an empty route, not stale1.
for _,row in ipairs(rows) do row.noPOI=true end
plan=autoPlan();check(plan.count==0 and plan.stability.questID==nil,'no candidates cleanly clears first and groups')
-- r7 leveling scenarios exercise real route choices with native difficulty and cached rewards.
Fixture.worldScale=10000
local function stepFor(id)
    for _,s in ipairs(api.GetPlan({}).steps) do if s.questID==id then return s end end
end
rows={routeRow(201,600),routeRow(202,650,{difficulty=1,level=16}),
    routeRow(203,550,{difficulty=0,trivial=true,level=1,xp=100}),
    routeRow(204,700,{difficulty=3,xp=1300}),routeRow(205,750,{difficulty=4,xp=2000}),routeRow(206,2000)}
plan=scenario(rows)
check(plan.steps[1].questID==202,'easy normal-reward task can beat slightly nearer fair task')
check(stepFor(203).priorityWeight<stepFor(201).priorityWeight,'very low-level trivial task no longer gets maximum bonus')
check(stepFor(204).priorityWeight<stepFor(201).priorityWeight and stepFor(205).priorityWeight<stepFor(204).priorityWeight,'difficult and impossible quests progressively deferred')
check(plan.count==6,'priority adjustments do not filter or abandon high-level or low-reward tasks')
check(plan.levelingPriority.reference.sampleCount==3 and plan.levelingPriority.reference.value==1000,'reference uses eligible positive easy-fair native rewards')
check(plan.levelPriority.perLevelBonus==0,'obsolete level-gap bonus explicitly disabled')
rows={routeRow(201,600,{difficulty=1,level=60}),routeRow(202,620,{difficulty=3,level=1})}
plan=scenario(rows)
check(plan.steps[1].questID==201,'native difficulty takes precedence over misleading quest-level labels')
rows={routeRow(201,600),routeRow(202,650,{difficulty=4,xp=100000})}
plan=scenario(rows)
check(plan.steps[1].questID==201,'large raw XP never cancels extreme combat difficulty')
-- Low XP lowers priority for ongoing objectives; completed tasks need no additional combat.
rows={routeRow(201,600),routeRow(202,550,{difficulty=1,xp=100}),routeRow(203,2000),routeRow(204,2100)}
plan=scenario(rows)
check(plan.steps[1].questID==201,'easy but very low-reward task yields to nearby normal-reward task')
check(stepFor(202).priority.reason=='low_reward_on_the_way','low-reward reason is observable in API')
rows[2].ready=true;plan=api.Replan({})
check(plan.steps[1].questID==201 and stepFor(202).priorityWeight<1,'low-reward turnin remains a moderate on-the-way preference')
rows[2].x=300;syncPOIs();plan=api.Replan({})
check(plan.steps[1].questID==202 and plan.steps[1].action=='turn_in','nearby low-reward turnin can still be recommended')
rows={routeRow(201,600),routeRow(202,550,{difficulty=4,xp=1000,ready=true}),routeRow(203,2000)}
plan=scenario(rows)
check(plan.steps[1].questID==202 and stepFor(202).priority.difficultyWeight==1,'already-completed high-level task has no combat penalty')
rows[2].ready=false;rows[2].complete=true;plan=api.Replan({})
check(plan.steps[1].questID==202 and plan.steps[1].action=='completion_pending','complete-without-ready also releases combat difficulty penalty')
-- Reward caches are distinct: missing/invalid data is not a verified zero reward.
rows={routeRow(201,500,{xp=0}),routeRow(202,550,{xp=0,rewardMissing=true}),routeRow(203,2000),routeRow(204,2100),routeRow(205,2200)}
plan=scenario(rows)
check(plan.steps[1].questID==202,'unknown reward stays neutral while verified zero is deweighted')
check(stepFor(201).priority.experience.available and stepFor(201).priority.experience.value==0,'cached zero reward is explicitly represented')
check(not stepFor(202).priority.experience.available and stepFor(202).priority.experience.value==nil,'uncached zero is unavailable rather than zero experience')
check(stepFor(202).priority.experienceWeight==1,'unknown XP never receives low-reward penalty')
local beforeLoad=plan.sequence
rows[2].rewardMissing=false
local dataDriver=api.route.driver
syncPOIs();dataDriver:GetScript('OnEvent')(dataDriver,'QUEST_DATA_LOAD_RESULT',202,true)
Fixture.time=Fixture.time+1;dataDriver:GetScript('OnUpdate')(dataDriver,.2);plan=api.GetPlan({})
check(plan.sequence==beforeLoad+1 and plan.reason=='QUEST_DATA_LOAD_RESULT','active quest data-load event refreshes priority without walking')
check(stepFor(202).priority.experience.available and stepFor(202).priority.experienceWeight<1,'newly ready reward participates in ranking')
local previousSequence=plan.sequence
dataDriver:GetScript('OnEvent')(dataDriver,'QUEST_DATA_LOAD_RESULT',99999999,true)
Fixture.time=Fixture.time+1;dataDriver:GetScript('OnUpdate')(dataDriver,.2)
check(api.GetPlan({}).sequence==previousSequence,'unrelated cache event does not rebuild current route')
-- Reward/difficulty reader failures and missing APIs are isolated from the route.
local xpReader=GetQuestLogRewardXP
GetQuestLogRewardXP=function() error('fixture reward read failure') end
plan=api.Replan({})
check(plan.ok and plan.count==5 and not stepFor(201).priority.experience.available,'reward read errors preserve all route candidates')
check(stepFor(201).priority.experience.reason=='read_error' and stepFor(201).priority.experienceWeight==1,'failed reward reads explicitly neutral')
GetQuestLogRewardXP=nil;plan=api.Replan({})
check(stepFor(201).priority.experience.reason=='api_unavailable','missing undocumented XP API falls back cleanly')
GetQuestLogRewardXP=xpReader
local rewardCache=HaveQuestRewardData
HaveQuestRewardData=nil;plan=api.Replan({})
check(not stepFor(201).priority.experience.available and stepFor(201).priorityWeight==1,'no reward-cache API never assumes zero XP is ready')
HaveQuestRewardData=rewardCache
rows[1].uncached=true;rows[1].difficulty=0;rows[1].trivial=true
plan=api.Replan({})
check(not stepFor(201).priority.difficulty.available and not stepFor(201).priority.experience.available and stepFor(201).priorityWeight==1,'quest data not ready does not create trivial or zero-XP penalty')
rows[1].uncached=false;rows[1].trivial=false
for _,bad in ipairs({-1,math.huge,0/0,false}) do
    rows[1].xp=bad;plan=api.Replan({})
    check(not stepFor(201).priority.experience.available,'invalid native reward excluded without inventing zero')
end
rows[1].xp=1000;rows[1].difficulty=false;plan=api.Replan({})
check(stepFor(201).priority.difficulty.name=='unknown' and stepFor(201).priorityWeight==1,'unknown difficulty uses neutral fallback')
rows[1].difficulty=99;plan=api.Replan({})
check(stepFor(201).priorityWeight==1,'unknown future enum value never crashes or gets fabricated bonus')
local difficultyReader=C_PlayerInfo.GetContentDifficultyQuestForPlayer
C_PlayerInfo.GetContentDifficultyQuestForPlayer=function() error('fixture difficulty read failure') end
plan=api.Replan({})
check(plan.ok and not stepFor(201).priority.difficulty.available,'difficulty read error isolated')
C_PlayerInfo.GetContentDifficultyQuestForPlayer=difficultyReader
rows[1].difficulty=2;rows[1].trivial=true;plan=api.Replan({})
check(stepFor(201).priority.difficulty.code==0 and stepFor(201).priorityWeight<1,'native trivial flag overrides neutral enum fallback')
local oldAccessible=canaccessvalue
canaccessvalue=function(value) return value~='secret-fixture' end
GetQuestLogRewardXP=function(id) if id==201 then return 'secret-fixture' end return xpReader(id) end
rows[1].trivial=false;rows[1].difficulty='secret-fixture';plan=api.Replan({})
check(not stepFor(201).priority.experience.available and stepFor(201).priority.experience.reason=='restricted','restricted reward never enters arithmetic')
check(not stepFor(201).priority.difficulty.available and stepFor(201).priority.difficulty.reason=='restricted','restricted difficulty never used as table key')
canaccessvalue=oldAccessible;GetQuestLogRewardXP=xpReader
-- Reward thresholds and small-sample fallback use current filtered candidates only.
for _,case in ipairs({{249,true},{250,false},{499,false},{500,false}}) do
    rows={routeRow(201,600,{xp=case[1]}),routeRow(202,1200),routeRow(203,1800),routeRow(204,2400),routeRow(205,3000)}
    plan=scenario(rows)
    check(stepFor(201).priority.lowReward==case[2],'25percent low-reward classification boundary')
    check((stepFor(201).priority.experienceWeight<1)==(case[1]<500),'50percent discount boundary')
end
plan=scenario({routeRow(201,600,{xp=10}),routeRow(202,900,{xp=1000})})
check(not plan.levelingPriority.reference.available and stepFor(201).priority.experienceWeight==1,'fewer than3 samples never claim precise low-reward baseline')
rows={routeRow(201,600,{xp=1000}),routeRow(202,1200,{xp=1100}),routeRow(203,1800,{xp=1200}),routeRow(204,2400,{xp=1000000})}
plan=scenario(rows)
check(plan.levelingPriority.reference.value==1150,'median resists extreme reward outlier')
local originalType,originalElite,originalTag=C_QuestLog.GetQuestType,C_QuestLog.IsEliteQuest,C_QuestLog.GetQuestTagInfo
C_QuestLog.GetQuestType=function(id) return rowFor(id).instance and 81 or 0 end
C_QuestLog.IsEliteQuest=function(id) return rowFor(id).elite or false end
C_QuestLog.GetQuestTagInfo=function(id) if rowFor(id).profession then return {tradeskillLineID=356} end end
rows={routeRow(201,600),routeRow(202,1200),routeRow(203,1800),routeRow(204,1900,{map=102,xp=1000000}),
    routeRow(205,2000,{instance=true,xp=1000000}),routeRow(206,2100,{elite=true,xp=1000000}),
    routeRow(207,2200,{profession=true,xp=1000000}),routeRow(208,2300,{xp=1000000})}
scenario(rows);api.SetQuestSkip({questID=208});plan=api.GetPlan({})
check(plan.count==3 and plan.levelingPriority.reference.sampleCount==3 and plan.levelingPriority.reference.value==1000,'foreign instance elite profession and skipped quests cannot contaminate reference')
local exclusions={};for _,e in ipairs(plan.excluded) do exclusions[e.questID]=e.reason end
check(exclusions[204]=='outside_current_map' and exclusions[205]=='instance' and exclusions[206]=='elite' and exclusions[207]=='profession' and exclusions[208]=='skipped','all mandatory filters survive priority integration')
C_QuestLog.GetQuestType,C_QuestLog.IsEliteQuest,C_QuestLog.GetQuestTagInfo=originalType,originalElite,originalTag
-- Small rewards cannot normalize each other when the next-level experience requirement is known.
local xpMaximum=UnitXPMax
UnitXPMax=function() return 20000 end
rows={routeRow(201,600,{xp=1000}),routeRow(202,550,{difficulty=1,xp=10}),routeRow(203,650,{difficulty=1,xp=10})}
plan=scenario(rows)
check(plan.levelingPriority.reference.value==10 and plan.steps[1].questID==201,'tiny-reward majority cannot hide low progression value')
check(stepFor(202).priority.lowReward and stepFor(202).priority.experience.fractionOfLevel==.0005,'real per-level progress makes tiny rewards observable')
for _,case in ipairs({{99,true,true},{100,false,true},{199,false,true},{200,false,false}}) do
    plan=scenario({routeRow(201,600,{xp=case[1]}),routeRow(202,1200,{xp=1000})})
    check(stepFor(201).priority.lowReward==case[2],'half-percent per-level threshold boundary')
    check((stepFor(201).priority.experienceWeight<1)==case[3],'one-percent per-level threshold boundary')
end
UnitXPMax=function() return nil end
plan=scenario({routeRow(201,600,{xp=10}),routeRow(202,900)})
check(stepFor(201).priority.experienceWeight==1 and stepFor(201).priority.experience.fractionOfLevel==nil,'missing level XP requirement never invents progression fraction')
UnitXPMax=xpMaximum
-- An independently filled reward cache refreshes without any event or player movement.
rows={routeRow(201,450,{xp=0,rewardMissing=true}),routeRow(202,500)}
plan=scenario(rows)
check(plan.steps[1].questID==201 and plan.levelingPriority.pendingRewardCount==1,'unknown reward can start as nearest candidate with retry scheduled')
rows[1].rewardMissing=false;Fixture.time=plan.plannedAt+4.99
local cacheTick=api.route.driver:GetScript('OnUpdate')
cacheTick(api.route.driver,.2)
check(api.GetPlan({}).sequence==plan.sequence,'cache retry waits five seconds')
Fixture.time=plan.plannedAt+5;cacheTick(api.route.driver,.2);plan=api.GetPlan({})
check(plan.reason=='reward_cache_refresh' and plan.steps[1].questID==202,'independent cache completion changes priorities while standing still')
check(plan.levelingPriority.pendingRewardCount==0 and api.route.nextRewardCheck==nil,'fully loaded rewards stop retry polling')
previousSequence=plan.sequence;Fixture.time=Fixture.time+10;cacheTick(api.route.driver,.2)
check(api.GetPlan({}).sequence==previousSequence,'loaded data does not trigger recurring route rebuild')
rows={routeRow(201,100,{xp=0,rewardMissing=true}),routeRow(202,105)}
plan=scenario(rows);rows[1].rewardMissing=false;Fixture.time=plan.plannedAt+5;cacheTick(api.route.driver,.2)
plan=api.GetPlan({})
check(plan.steps[1].questID==201 and plan.stability.reason=='at_objective_area','cache refresh still respects task already being worked nearby')
plan=api.Replan({})
check(plan.steps[1].questID==202,'manual choice applies updated reward and bypasses work protection')
plan=scenario({routeRow(201,500,{complete=true}),routeRow(202,900)})
check(stepFor(201).action=='completion_pending' and stepFor(201).priority.reason=='completion_pending','pending completion never claims turnin availability in priority explanation')
-- r8 navigation state uses position samples, not the100yard route-rebuild threshold.
YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].moveThreshold=5000
local function samplePosition(yards,advance)
    if yards then Fixture.playerX=yards/Fixture.worldScale end
    Fixture.time=Fixture.time+(advance or .6)
    local d=api.route.driver;d:GetScript('OnUpdate')(d,.2)
    return api.GetPlan({})
end
rows={routeRow(201,500),routeRow(202,2000)}
plan=scenario(rows)
check(plan.navigation.phase=='travel' and not plan.navigation.protected,'distant active objective starts in travel state')
check(plan.navigation==plan.steps[1].navigation and plan.steps[2].navigation.phase=='queued','first step shares plan state and future steps stay queued')
local phaseSequence=plan.sequence
plan=samplePosition(379.99)
check(plan.navigation.phase=='travel' and plan.sequence==phaseSequence,'just outside120 stays traveling without route rebuild')
plan=samplePosition(380)
check(plan.navigation.phase=='working' and plan.navigation.protected and plan.sequence==phaseSequence,'120yard arrival enters working below movement threshold')
check(plan.steps[1].status=='in_progress' and not rows[1].complete,'arrival at an area never changes official completion')
local entered=plan.navigation.workStartedAt
plan=samplePosition(320)
check(plan.navigation.phase=='working' and plan.navigation.workStartedAt==entered,'180yard departure boundary keeps same work session')
plan=samplePosition(319.99)
check(plan.navigation.phase=='travel' and not plan.navigation.protected,'outside180 leaves work area without progress')
check(plan.reason=='work_protection_ended','leaving work protection triggers fresh candidate comparison')
plan=samplePosition(350)
check(plan.navigation.phase=='travel','between120and180 does not reenter from travel')
plan=samplePosition(400)
check(plan.navigation.phase=='working' and plan.navigation.workStartedAt>entered,'reentering120 starts a new work session')
-- Real progress extends the work area, but it cannot protect forever or outside300.
rows={routeRow(201,500),routeRow(202,2000)}
scenario(rows,400);rows[1].fulfilled=1;plan=autoPlan()
local actualProgress=api.route.progress[201].lastProgressAt
plan=samplePosition(750)
check(plan.navigation.phase=='working' and plan.navigation.reason=='recent_objective_progress','real progress retains working at250yards')
Fixture.time=actualProgress+90;plan=samplePosition(nil,0)
check(plan.navigation.phase=='working','90second real-progress equality still works')
plan=samplePosition(nil,.6)
check(plan.navigation.phase=='travel' and not plan.navigation.protected,'expired progress outside180 returns to travel while stationary')
rows[1].fulfilled=2;plan=autoPlan();plan=samplePosition(800)
check(plan.navigation.phase=='working' and plan.navigation.protected,'300yard boundary permits genuine recent work')
plan=samplePosition(800.01)
check(plan.navigation.phase=='travel' and not plan.navigation.protected,'beyond300 no progress protection remains')
-- Long idle does not fake completion and does not renew on ordinary quest events.
rows={routeRow(201,500),routeRow(202,2000)}
plan=scenario(rows,400);entered=plan.navigation.workStartedAt
plan=autoPlan()
check(plan.navigation.workStartedAt==entered,'ordinary quest updates do not restart no-progress timer')
Fixture.time=entered+179.4;plan=samplePosition(nil,0)
check(plan.steps[1].questID==201 and plan.navigation.protected,'idle work remains protected before180seconds')
rows[2].x=410;syncPOIs()
Fixture.time=entered+180;plan=samplePosition(nil,0)
check(plan.steps[1].questID==202 and plan.reason=='work_protection_ended','180second idle releases much better alternative without walking or event: quest='..plan.steps[1].questID..' reason='..plan.reason..' idle='..tostring(plan.navigation.idleFor)..' phase='..plan.navigation.phase..' now='..Fixture.time..' next='..api.route.nextPositionCheck)
check(rows[1].complete==nil and stepFor(201).status=='in_progress','idle timeout does not complete or abandon previous task')
rows={routeRow(201,100),routeRow(202,900)}
plan=scenario(rows);entered=plan.navigation.workStartedAt
rows[2].x=60;syncPOIs();Fixture.time=entered+180;plan=samplePosition(nil,0)
check(plan.steps[1].questID==201 and plan.navigation.phase=='working' and plan.navigation.stale and not plan.navigation.protected,'idle releases protection but minimum saving still avoids needless switch')
check(plan.navigation.reason=='no_progress_timeout' and plan.navigation.idleFor==180,'API exposes explicit stale work and idle duration')
local staleStart=plan.navigation.workStartedAt
plan=autoPlan()
check(plan.navigation.stale and plan.navigation.workStartedAt==staleStart,'rebuild does not revive stale proximity protection')
rows[1].fulfilled=1;plan=autoPlan()
check(plan.navigation.protected and not plan.navigation.stale and plan.navigation.lastProgressAt==api.route.progress[201].lastProgressAt,'new real progress revives active work after idle')
-- Missing objectives preserve prior progress, but never create progress or an endless timer.
rows={routeRow(201,500),routeRow(202,2000)}
scenario(rows,400);rows[1].fulfilled=1;plan=autoPlan();actualProgress=plan.navigation.lastProgressAt
rows[1].missing=true;plan=autoPlan()
check(plan.navigation.phase=='working' and plan.navigation.objectivesAvailable==false and plan.navigation.lastProgressAt==actualProgress,'missing objectives retain truthful work with missing-data flag')
rows[1].missing=false;rows[1].empty=true;plan=autoPlan()
check(plan.navigation.objectivesAvailable==false and plan.navigation.lastProgressAt==actualProgress,'empty objectives do not invent finished targets')
rows[1].empty=false;rows[1].readError=true;plan=autoPlan()
check(plan.navigation.lastProgressAt==actualProgress,'throwing objective reader does not fake progress in navigation')
rows[1].readError=false;plan=autoPlan()
check(plan.navigation.lastProgressAt==actualProgress,'cache recovery with unchanged values never refreshes work')
Fixture.time=actualProgress+180;plan=samplePosition(nil,0)
check(plan.navigation.stale and not plan.navigation.protected,'missing-data recovery cannot defeat idle timeout')
-- Goal structure changes reset the old activity proof, even with same questID and status.
rows={routeRow(201,500),routeRow(202,2000)}
scenario(rows,400);rows[1].fulfilled=1;autoPlan();plan=samplePosition(750)
local oldRevision=plan.navigation.objectiveRevision
rows[1].kind='item';plan=autoPlan()
check(plan.navigation.phase=='travel' and plan.navigation.objectiveRevision>oldRevision and plan.navigation.lastProgressAt==nil,'new objective stage cannot inherit old remote work protection')
plan=samplePosition(400);entered=plan.navigation.workStartedAt
rows[1].required=20;plan=autoPlan()
check(plan.navigation.workStartedAt>entered and plan.navigation.idleFor==0,'new stage in same area starts its own work session')
-- Task-level native POI is re-read for completion and new stages; reaching it is never auto turn-in.
rows={routeRow(201,500)}
plan=scenario(rows)
check(plan.navigation.phase=='travel','end-to-end fixture begins traveling')
plan=samplePosition(400)
check(plan.navigation.phase=='working','end-to-end fixture arrives to work')
rows[1].fulfilled=3;plan=autoPlan()
check(plan.navigation.lastProgressAt~=nil and plan.steps[1].status=='in_progress','end-to-end fixture registers genuine goal increase')
rows[1].complete=true;rows[1].x=1500;plan=autoPlan()
check(plan.navigation.phase=='completion_pending' and not plan.navigation.protected,'official completion without ready uses pending status')
check(plan.steps[1].world.x==1500 and plan.navigation.targetWorld.x==1500,'completion re-reads native destination rather than old work point')
rows[1].ready=true;plan=autoPlan()
check(plan.navigation.phase=='turn_in' and plan.navigation.reason=='official_ready_for_turn_in','official readiness enters delivery navigation')
plan=samplePosition(1500)
check(plan.navigation.phase=='turn_in' and plan.navigation.atReference and plan.steps[1].status=='ready_for_turn_in','arrival at turnin point still requires player to actually turn in')
rows[1]=nil;plan=autoPlan()
check(plan.count==0 and plan.navigation.phase=='idle' and plan.navigation.questID==nil,'actually removed quest leaves no stale working or turnin state')
-- Cross-region targets, failures and player skip always override work.
rows={routeRow(201,500),routeRow(202,2000)}
scenario(rows,400);rows[1].map=102;plan=autoPlan()
check(plan.navigation.questID==202 and plan.navigation.phase=='travel','foreign target cannot keep local work state')
rows={routeRow(201,500),routeRow(202,2000)}
scenario(rows,400);rows[1].noPOI=true;plan=autoPlan()
check(plan.navigation.questID==202 and plan.navigation.phase=='travel','lost POI cannot leave an invisible working target')
rows={routeRow(201,500),routeRow(202,2000)}
scenario(rows,400);rows[1].failed=true;plan=autoPlan()
check(plan.navigation.questID==202 and plan.navigation.phase=='travel','failed task cancels work navigation')
rows={routeRow(201,500),routeRow(202,2000)}
scenario(rows,400);api.SetQuestSkip({questID=201});plan=api.GetPlan({})
check(plan.navigation.questID==202 and plan.navigation.phase=='travel','player skip cancels work navigation immediately')
rows={routeRow(201,500),routeRow(202,2000)}
scenario(rows,400);rows[2].x=410;syncPOIs();plan=api.Replan({})
check(plan.navigation.questID==202 and plan.navigation.phase=='working' and plan.stability.reason=='manual_replan','manual replan can select nearby alternative despite former work protection')
-- Invalid location is visible as unavailable; it cannot retain protected work.
rows={routeRow(201,500)}
scenario(rows,400)
Fixture.conversionFail[101]=true;plan=samplePosition(nil)
check(plan.navigation.phase=='unavailable' and not plan.navigation.protected,'temporarily missing world position disables work protection')
Fixture.conversionFail[101]=nil;plan=samplePosition(400)
check(plan.navigation.phase=='working' and plan.navigation.protected,'valid position recovery starts normal local work')
Fixture.playerMapID=102;plan=samplePosition(nil)
check(plan.mapID==102 and plan.navigation.phase=='idle' and plan.navigation.questID==nil,'changing player map discards old work even with small movement')
-- Review regressions: activity is anchored to the original POI, not merely the questID.
rows={routeRow(201,400),routeRow(202,2000)}
scenario(rows,500);rows[1].fulfilled=1;autoPlan()
rows[1].x=750;plan=autoPlan()
check(plan.navigation.phase=='travel' and not plan.navigation.protected and plan.navigation.lastProgressAt==nil,'old progress cannot protect a POI that jumped to another area')
rows[2].x=550;plan=autoPlan()
check(plan.navigation.questID==202,'nearer alternative can replace a moved POI despite old real progress')
rows={routeRow(201,400),routeRow(202,2000)}
scenario(rows,500);rows[1].fulfilled=1;autoPlan();rows[1].x=750;autoPlan()
rows[1].fulfilled=2;plan=autoPlan()
check(plan.navigation.phase=='working' and plan.navigation.protected and plan.navigation.reason=='recent_objective_progress','new real progress can anchor genuine work at new POI')
-- A temporary coordinate loss cannot renew an already expired work session, even through a rebuild.
rows={routeRow(201,500)}
plan=scenario(rows,400);entered=plan.navigation.workStartedAt
Fixture.time=entered+180;plan=samplePosition(nil,0)
check(plan.navigation.stale and not plan.navigation.protected,'precondition stale session before coordinate gap')
Fixture.conversionFail[101]=true;plan=samplePosition(nil)
check(plan.navigation.phase=='unavailable' and plan.navigation.workStartedAt==entered,'coordinate gap preserves original work baseline')
plan=autoPlan()
check(plan.count==0 and plan.navigation.phase=='unavailable' and api.route.workSession.workStartedAt==entered,'temporary missing coordinate rebuild suspends rather than discards expired baseline')
Fixture.conversionFail[101]=nil;plan=samplePosition(400,5)
check(plan.navigation.phase=='working' and plan.navigation.stale and not plan.navigation.protected and plan.navigation.workStartedAt==entered,'coordinate recovery cannot silently rearm stale protection')
-- Temporary missing POIs are distinct from legitimately empty routes and recover without an event.
rows={routeRow(201,500)}
plan=scenario(rows,400);entered=plan.navigation.workStartedAt
Fixture.time=entered+180;samplePosition(nil,0)
rows[1].noPOI=true;plan=autoPlan()
check(plan.count==0 and plan.navigation.phase=='unavailable' and plan.pendingLocationCount==1,'missing native POI advertises waiting state rather than completed work')
check(plan.locationRetrySeconds==5 and api.route.nextLocationCheck~=nil,'temporary native location data schedules a bounded-rate retry')
rows[1].noPOI=false;syncPOIs();plan=samplePosition(nil,5)
check(plan.count==1 and plan.reason=='location_data_refresh' and plan.navigation.stale and not plan.navigation.protected,'native POI recovery without event restores target but not stale protection')
check(plan.pendingLocationCount==0 and api.route.nextLocationCheck==nil,'native location retry stops after recovery')
plan=samplePosition(nil,10)
check(plan.pendingLocationCount==0,'restored native location remains stable')
rows={routeRow(201,500,{map=102})};plan=scenario(rows)
check(plan.navigation.phase=='idle' and plan.pendingLocationCount==0 and api.route.nextLocationCheck==nil,'legitimate foreign-only route has no pointless missing-data retry')
-- Readiness and native POI updates can arrive on separate events: preserve uncertainty explicitly.
rows={routeRow(201,500)}
scenario(rows,400);rows[1].complete=true;plan=autoPlan()
check(plan.navigation.phase=='completion_pending' and plan.steps[1].world.x==500,'completion may precede POI refresh without claiming delivery')
rows[1].ready=true;plan=autoPlan()
check(plan.navigation.phase=='turn_in' and plan.navigation.locationPrecision=='quest_poi' and plan.navigation.deliveryLocationConfirmed==false,'ready with unchanged POI never claims confirmed NPC destination')
rows[1].x=1500;plan=autoPlan()
check(plan.navigation.phase=='turn_in' and plan.navigation.targetWorld.x==1500,'later POI event replaces old area while retaining official delivery state')
-- Navigation emits only semantic changes, not every location sample.
local originalEmit=api.WB.Emit
local phaseEvents={}
api.WB.Emit=function(self,topic,data) if topic=='route.navigation_changed' then phaseEvents[#phaseEvents+1]=data end end
scenario({routeRow(201,500)})
local beforeEvents=#phaseEvents
samplePosition(20);samplePosition(40)
check(#phaseEvents==beforeEvents,'ordinary traveling samples do not spam phase events')
samplePosition(400)
check(#phaseEvents==beforeEvents+1 and phaseEvents[#phaseEvents].phase=='working','entering work emits one phase event')
samplePosition(401)
check(#phaseEvents==beforeEvents+1,'ordinary working samples do not spam phase events')
api.WB.Emit=originalEmit
YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].moveThreshold=100
-- r9 fixture uses full exact localized text and a deliberately shuffled database order.
Fixture.worldScale=1000
local savedQuestObjectives=FixtureDB.Quest.objectives
local savedEntity={Npc=FixtureDB.Npc,Object=FixtureDB.Object,Item=FixtureDB.Item}
QUEST_MONSTERS_KILLED='%2$d/%3$d 消灭%1$s';QUEST_ITEMS_NEEDED='%2$d/%3$d %1$s';QUEST_OBJECTS_FOUND='%2$d/%3$d %1$s'
local targetEntities,targetGroups
local function targetModule(kind)
    return {Exists=function(id) return targetEntities[kind][id]~=nil end,
        name=function(id) return targetEntities[kind][id].name end,
        spawns=function(id)
            local ent=targetEntities[kind][id]
            if ent.readError then error('fixture spawns missing') end
            return ent.spawns or {[ent.area or 17]={{(ent.x or 500)/10,0,ent.phase}}}
        end,
        npcDrops=function(id) return targetEntities[kind][id].npcs or {} end,
        objectDrops=function(id) return targetEntities[kind][id].objects or {} end}
end
FixtureDB.Npc=targetModule('npc');FixtureDB.Object=targetModule('object');FixtureDB.Item=targetModule('item')
FixtureDB.Quest.objectives=function() return targetGroups end
local function goal(kind,name,value,required,finished)
    return {type=kind,text=value..'/'..required..' '..(kind=='monster' and '消灭' or '')..name,
        numFulfilled=value,numRequired=required,finished=finished or false}
end
local function targetsScenario(objectives,groups,entities,extras,player)
    targetEntities=entities or {npc={[11]={name='野猪',x=500},[12]={name='迅猛龙',x=900}},object={},item={}}
    targetGroups=groups or {[1]={{12,nil,0},{11,nil,0}}}
    local row=extras or {};row.objectives=objectives or {goal('monster','野猪',0,6),goal('monster','迅猛龙',0,8)}
    rows={routeRow(201,row.x or 450,row)}
    return scenario(rows,player)
end
local function resolvedTargets(extra)
    local args=extra or {};args.questID=args.questID or 201
    return api.GetQuestTargets(args)
end
plan=targetsScenario()
local targets=resolvedTargets({limit=1})
check(targets.ok and targets.mode=='objective_locations' and targets.remainingCount==2,'exact same-task localized names resolve separate goals')
check(targets.objectives[1].id==11 and targets.objectives[2].id==12,'database array order does not infer official objective identity')
check(targets.targets[1].objectiveKey=='npc:11' and targets.targets[1].source=='QuestieDB' and targets.progressSource=='C_QuestLog.GetQuestObjectives','position and progress provenance remain distinct')
check(targets.count==1 and targets.total==2 and targets.hasMore and targets.nextOffset==1,'target coordinates paginate independently of full small goal list')
local secondPage=resolvedTargets({offset=1,limit=1})
check(secondPage.count==1 and secondPage.targets[1].objectiveKey=='npc:12' and not secondPage.hasMore,'second target page contains actual remaining point')
check(resolvedTargets({offset=500}).count==0,'past-end target page is empty')
check(plan.steps[1].objectiveKey=='npc:11' and plan.steps[1].targetMode=='objective_locations','planner chooses nearest unfinished specific goal')
check(near(plan.steps[1].world.x,500) and plan.steps[1].precision=='static_spawn','planner uses verified static spawn instead of generic native point')
check(plan.objectiveResolution[1].reason=='exact_mapping_complete','plan exposes why finer navigation was enabled')
check(resolvedTargets({allowDatabase=false}).mode=='native_poi' and resolvedTargets({allowDatabase=false}).targets[1].source=='C_QuestLog.GetQuestsOnMap','per-query database opt-out preserves native location')
for _,bad in ipairs({{questID=0},{questID=201,limit=0},{questID=201,offset=-1},{questID=201,mapID=-1},{questID=201,allowDatabase='true'}}) do
    check(not api.GetQuestTargets(bad).ok,'invalid target arguments rejected')
end
check(api.GetQuestTargets({questID=888}).reason=='quest_not_in_log','target lookup does not invent active progress for unknown quest')
-- Individual completion, not aggregate quest state, retires a source region and its work protection.
plan=targetsScenario(nil,nil,nil,nil,400)
check(plan.navigation.phase=='working' and plan.navigation.objectiveKey=='npc:11','working session is keyed to actual target entity')
rows[1].objectives[1]=goal('monster','野猪',6,6,true);plan=autoPlan();targets=resolvedTargets()
check(plan.steps[1].objectiveKey=='npc:12' and plan.navigation.phase=='travel','finished subgoal releases prior work and selects remaining goal while quest still active')
check(targets.total==1 and targets.targets[1].objectiveKey=='npc:12' and targets.objectives[1].finished,'finished subgoal kept in progress list but removed from coordinates')
rows[1].ready=true;rows[1].x=800;plan=autoPlan()
check(plan.steps[1].source=='C_QuestLog.GetQuestsOnMap' and not plan.steps[1].objectiveKey and plan.navigation.phase=='turn_in','official readiness always returns to native delivery handling')
rows[1].ready=false;rows[1].complete=true;plan=autoPlan()
check(plan.navigation.phase=='completion_pending' and plan.steps[1].targetMode=='native_poi','completed-not-ready never navigates to old kill sources')
-- All completed goals but delayed aggregate flag do not fabricate a turn-in status.
plan=targetsScenario({goal('monster','野猪',6,6,true),goal('monster','迅猛龙',8,8,true)})
check(plan.steps[1].targetReason=='objectives_finished_waiting_quest_state' and plan.steps[1].status=='in_progress','finished subgoals wait for official quest state')
-- Equal counters alone do not overrule finished; unknown completion forces native fallback.
plan=targetsScenario({goal('monster','野猪',6,6,false),goal('monster','迅猛龙',0,8)})
check(resolvedTargets().total==2,'finished false with full numeric count is still unfinished')
rows[1].objectives[1].finished=nil;plan=autoPlan()
check(plan.steps[1].targetReason=='objective_state_unavailable' and not plan.steps[1].objectiveKey,'missing finished flag never discards a possibly unfinished goal')
-- Exact matching is not substring matching; ambiguity and partial mappings fall back as a whole.
plan=targetsScenario({goal('monster','野猪',0,6),goal('monster','迅猛龙幼崽',0,8)})
check(plan.steps[1].targetMode=='native_poi' and plan.steps[1].world.x==450,'near-name and one unmatched objective fall back instead of pretending full coverage')
plan=targetsScenario(nil,{[1]={{11,nil,0},{12,nil,0}}},{npc={[11]={name='野猪',x=500},[12]={name='野猪',x=900}},item={},object={}})
check(plan.steps[1].targetReason=='ambiguous_objective','two different entity IDs sharing full name are not guessed')
plan=targetsScenario(nil,{[1]={{11,nil,0},{11,nil,0}}})
check(plan.steps[1].targetReason=='duplicate_reference','duplicate entity references are not assigned by ordinal')
plan=targetsScenario(nil,{[1]={{11,nil,0}}})
check(plan.steps[1].targetReason=='objective_count_mismatch','missing database goal falls back as whole task')
plan=targetsScenario(nil,{[1]={{11,nil,0},{12,nil,0}},[5]={123}})
check(plan.steps[1].targetReason=='special_objective_relation','kill-credit relationship is not assumed to be direct kill target')
plan=targetsScenario(nil,{[1]={{11,nil,3},{12,nil,0}}})
check(plan.steps[1].targetReason=='unsupported_reference','nonzero special objective metadata is not ignored')
plan=targetsScenario();targetGroups[1][1][1]=555;plan=autoPlan()
check(plan.steps[1].targetReason=='entity_not_found','unknown entity data gracefully uses native reference')
plan=targetsScenario();rows[1].objectives[2].type='event';plan=autoPlan()
check(plan.steps[1].targetMode=='native_poi','event objectives are not treated as monster relations')
-- General format syntax supports both client positional strings and ordinary localized order.
plan=targetsScenario()
QUEST_MONSTERS_KILLED='%s slain: %d/%d'
rows[1].objectives[1].text='野猪 slain: 0/6';rows[1].objectives[2].text='迅猛龙 slain: 0/8';plan=autoPlan()
check(plan.steps[1].targetMode=='objective_locations','ordinary sequential localization format is supported')
QUEST_MONSTERS_KILLED=nil;plan=autoPlan()
check(plan.steps[1].targetMode=='native_poi','missing localized client format does not enable guessed text parsing')
QUEST_MONSTERS_KILLED='%2$d/%3$d 消灭%1$s'
-- Raw object targets require exact official wording, not a guessed interaction prefix.
plan=targetsScenario({goal('object','箱子',0,1)},{[2]={{21,nil,0}}},{npc={},object={[21]={name='箱子',x=700}},item={}})
check(plan.steps[1].objectiveKey=='object:21','exact raw-object goal can use object static point')
rows[1].objectives[1].text='0/1 检查箱子';plan=autoPlan()
check(plan.steps[1].targetMode=='native_poi','special object interaction wording is not stripped to force a match')
-- Item -> direct NPC/object drop chains, including already-complete liver example.
local itemEntities={npc={[31]={name='雷鳞蜥蜴',x=650},[32]={name='雷鹰',x=850},[33]={name='科多兽',x=50}},
    object={[41]={name='蝎卵堆',x=750}},item={[101]={name='闪电腺',npcs={31}},[102]={name='唾液腺',npcs={32}},[103]={name='肝脏',npcs={33}}}}
plan=targetsScenario({goal('item','闪电腺',0,5),goal('item','唾液腺',0,1),goal('item','肝脏',1,1,true)},
    {[3]={{103,nil,0},{101,nil,0},{102,nil,0}}},itemEntities)
targets=resolvedTargets()
check(targets.mode=='objective_locations' and targets.total==2 and targets.remainingCount==2,'finished liver does not contribute nearby kodo source locations')
check(plan.steps[1].objectiveKey=='item:101' and plan.steps[1].entityID==31 and plan.steps[1].relation=='direct_drop','item target chooses verified direct drop NPC instead of completed nearest source')
for _,point in ipairs(targets.targets) do check(point.entityID~=33 and not point.objective.finished,'every item target belongs to unfinished objective') end
itemEntities.item[101].npcs={};itemEntities.item[101].objects={41};plan=autoPlan()
check(resolvedTargets().mode=='objective_locations' and plan.steps[1].entityKind=='object','direct object-drop source is supported without requiring NPC source')
itemEntities.item[101].objects={};plan=autoPlan()
check(plan.steps[1].targetReason=='direct_location_source_missing','vendor/container-only or missing direct source does not auto recommend buying materials')
-- Coordinates are expressed in the actual goal map, not filtered through the generic task POI map.
plan=targetsScenario(nil,nil,nil,{map=102})
check(plan.count==2 and plan.questCount==1 and plan.steps[1].targetMapID==101 and plan.steps[2].targetMapID==101,'both verified local objectives survive native POI associated with another map')
plan=targetsScenario();targetEntities.npc[11].area=718;targetEntities.npc[12].area=718
-- Map718 is intentionally unsupported in this fixture, so native fallback is required.
plan=autoPlan();check(plan.steps[1].targetMode=='native_poi','unsupported spawn maps never become fake current-map locations')
plan=targetsScenario();targetEntities.npc[11].spawns={[17]={{-1,-1}}};plan=autoPlan()
check(plan.steps[1].targetReason=='objective_locations_unavailable','instance sentinel does not replace current native point')
plan=targetsScenario();targetEntities.npc[11].phase=7;plan=autoPlan()
check(plan.steps[1].targetMode=='native_poi','unverified phased-only spawn does not become an unconditional destination')
plan=targetsScenario();targetEntities.npc[11].readError=true;plan=autoPlan()
check(plan.steps[1].targetReason=='database_read_error' and plan.ok,'database getter errors are isolated from route')
local liveFixtureDB=LibQuestieDB;LibQuestieDB=nil;plan=autoPlan()
check(plan.steps[1].targetMode=='native_poi' and plan.steps[1].targetReason=='database_unavailable','database absent preserves native route')
LibQuestieDB=liveFixtureDB
-- Progress of B cannot create remote work protection for A, and a completed A loses its lock even if B is adjacent.
plan=targetsScenario(nil,nil,nil,nil,400)
rows[1].objectives[2]=goal('monster','迅猛龙',1,8);targetEntities.npc[12].x=760;Fixture.playerX=.75;plan=autoPlan()
check(plan.steps[1].objectiveKey=='npc:12','progress on another goal cannot pin old goal at250yards')
plan=targetsScenario(nil,nil,nil,nil,400)
rows[1].objectives[1]=goal('monster','野猪',1,6);Fixture.playerX=.75;targetEntities.npc[12].x=760;plan=autoPlan()
check(plan.steps[1].objectiveKey=='npc:11' and plan.navigation.reason=='recent_objective_progress','own actual progress still protects current goal area')
rows[1].objectives[1]=goal('monster','野猪',6,6,true);targetEntities.npc[12].x=550;Fixture.playerX=.4;plan=autoPlan()
check(plan.steps[1].objectiveKey=='npc:12' and plan.navigation.lastProgressAt==nil,'new nearby subgoal cannot inherit completed goal progress or old work session')
plan=targetsScenario();rows[1].objectives={rows[1].objectives[2],rows[1].objectives[1]};plan=autoPlan()
check(plan.steps[1].objectiveKey=='npc:11' and plan.steps[1].objective.index==2,'official objective reorder preserves entity identity without trusting index')
plan=targetsScenario();rows[1].missing=true;plan=autoPlan()
check(plan.steps[1].targetMode=='native_poi' and not plan.steps[1].objectiveKey,'temporary objective cache miss falls back without claiming finished targets')
-- One source region may serve another unfinished goal: do not suppress the whole place.
plan=targetsScenario(nil,nil,nil,nil,400)
targetEntities.npc[12].x=500;rows[1].objectives[1]=goal('monster','野猪',6,6,true);plan=autoPlan()
check(plan.steps[1].objectiveKey=='npc:12' and near(plan.steps[1].world.x,500),'shared source area remains valid for other unfinished goal')
-- Progress anchors only the player's nearby spawn region, not every spawn of that entity in the zone.
plan=targetsScenario({goal('monster','野猪',0,6),goal('monster','迅猛龙',8,8,true)},nil,nil,nil,400)
targetEntities.npc[11].spawns={[17]={{50,0},{90,0}}};rows[1].objectives[1]=goal('monster','野猪',1,6);autoPlan()
Fixture.playerX=.65;plan=autoPlan()
check(plan.navigation.phase=='working' and plan.steps[1].objectiveKey=='npc:11','original nearby spawn remains protected by genuine local work')
Fixture.playerX=.95;targetEntities.npc[12].x=990;plan=autoPlan()
check(plan.steps[1].objectiveKey=='npc:11' and near(plan.steps[1].world.x,900) and plan.navigation.lastProgressAt==nil,'new distant spawn of same goal cannot inherit old region progress')
-- A local finished goal does not pull a task back when all remaining verified locations are on another map.
plan=targetsScenario({goal('monster','野猪',6,6,true),goal('monster','迅猛龙',0,8)})
local baseSupportGet=FixtureDB.Support.Get
FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
targetEntities.npc[12].area=18;plan=autoPlan()
check(plan.count==0 and plan.excluded[1].reason=='outside_current_map','only foreign remaining goals do not reuse native local point or completed local goal')
check(resolvedTargets({mapID=101}).total==0 and resolvedTargets({mapID=102}).total==1,'target API map filter uses actual remaining entity map')
check(not resolvedTargets({mapID=9999}).ok,'unsupported client map ID is rejected')
FixtureDB.Support.Get=baseSupportGet
-- Retry deterministic per-request resolution without mutating preferences or quest progress.
plan=targetsScenario();local beforeTargetQuery=api.GetPlan({}).sequence
resolvedTargets();resolvedTargets()
check(api.GetPlan({}).sequence==beforeTargetQuery,'read-only target queries do not replan or mutate current work')
-- Review regression1: task-level group continuity cannot hide a still-unfinished co-located subgoal.
plan=targetsScenario(nil,nil,nil,nil,400)
targetEntities.npc[12].x=500
rows[#rows+1]=routeRow(202,650)
plan=autoPlan()
check(plan.steps[1].questID==201 and plan.steps[1].objectiveKey=='npc:11','co-located goals start in current task before completion')
rows[1].objectives[1]=goal('monster','野猪',6,6,true);plan=autoPlan()
check(plan.steps[1].questID==201 and plan.steps[1].objectiveKey=='npc:12','remaining100yard goal competes against250yard other task in same group')
-- Review regressions2/3: temporary cache fallback and pure reordering cannot rearm stale work.
plan=targetsScenario(nil,nil,nil,nil,400);entered=plan.navigation.workStartedAt
plan=samplePosition(nil,180)
check(plan.navigation.stale and not plan.navigation.protected,'precise-target work expires without progress')
rows[1].missing=true;plan=autoPlan()
check(plan.steps[1].targetMode=='native_poi' and api.route.suspendedObjectiveSession.workStartedAt==entered,'temporary fallback keeps precise session separately from native reference')
check(plan.navigation.stale and not plan.navigation.protected,'temporary same-area native fallback itself does not rearm expired protection')
rows[1].missing=false;plan=autoPlan()
check(plan.navigation.objectiveKey=='npc:11' and plan.navigation.workStartedAt==entered and plan.navigation.stale and not plan.navigation.protected,'cache recovery does not restart expired precise-target timer')
rows[#rows+1]=routeRow(202,410);plan=autoPlan()
check(plan.steps[1].questID==202,'recovered stale precise target does not block clearly better nearby task')
plan=targetsScenario(nil,nil,nil,nil,400);entered=plan.navigation.workStartedAt
plan=samplePosition(nil,180);local beforeRevision=plan.navigation.objectiveRevision
rows[1].objectives={rows[1].objectives[2],rows[1].objectives[1]};plan=autoPlan()
check(plan.navigation.objectiveKey=='npc:11' and plan.navigation.objectiveRevision==beforeRevision,'pure objective reorder keeps per-entity revision stable')
check(plan.navigation.workStartedAt==entered and plan.navigation.stale and not plan.navigation.protected,'pure reorder cannot rearm no-progress protection')
rows[#rows+1]=routeRow(202,410);plan=autoPlan()
check(plan.steps[1].questID==202,'reordered stale goal does not block clearly better task')
-- Genuine stage and count regression still reset activity proof conservatively.
plan=targetsScenario(nil,nil,nil,nil,400);rows[1].objectives[1]=goal('monster','野猪',2,6);plan=autoPlan()
local trueActivity=plan.navigation.lastProgressAt
rows[1].objectives={rows[1].objectives[2],rows[1].objectives[1]};plan=autoPlan()
check(plan.navigation.lastProgressAt==trueActivity and plan.navigation.objectiveKey=='npc:11','reordering preserves real activity for same identity')
rows[1].objectives[2]=goal('monster','野猪',1,6);plan=autoPlan()
check(plan.navigation.lastProgressAt==nil and plan.navigation.objectiveRevision>0,'count regression clears keyed activity rather than inventing progress')
-- Review regression4: native fallback/DB opt-out must not truncate official progress list.
plan=targetsScenario({goal('monster','野猪',0,6),goal('monster','迅猛龙幼崽',0,8)})
targets=resolvedTargets()
check(targets.mode=='native_poi' and #targets.objectives==2 and not targets.mappingComplete,'partially matched task still returns both official goals with incomplete mapping')
check(targets.objectives[2].text=='0/8 消灭迅猛龙幼崽' and targets.objectives[1].id==nil,'incomplete mapping never attaches a partial identity as though complete')
targets=resolvedTargets({allowDatabase=false})
check(#targets.objectives==2 and targets.objectivesLoaded and not targets.mappingComplete,'DB opt-out retains full official progress')
plan=targetsScenario();targets=resolvedTargets()
check(targets.mappingComplete and #targets.objectives==2 and targets.objectives[1].id==11,'successful full mapping annotates complete official progress snapshot')
targetEntities.npc[11].spawns={[17]={{-1,-1}}};plan=autoPlan();targets=resolvedTargets()
check(targets.mode=='native_poi' and targets.mappingComplete and #targets.objectives==2,'identity coverage can be complete while coordinates are unavailable')
-- Transient official/DB objective data recovers without a movement or new quest event.
plan=targetsScenario(nil,nil,nil,{missing=true})
check(plan.pendingObjectiveCount==1 and api.route.nextObjectiveCheck~=nil,'temporary missing objectives schedule5second retry')
rows[1].missing=false;plan=samplePosition(nil,5)
check(plan.reason=='objective_data_refresh' and plan.steps[1].targetMode=='objective_locations','recovered objective cache re-enables fine navigation without event')
check(plan.pendingObjectiveCount==0 and api.route.nextObjectiveCheck==nil,'recovered fine-target data stops retry')
plan=targetsScenario();targetEntities.npc[11].name=nil;plan=autoPlan()
check(plan.steps[1].targetReason=='entity_name_unavailable' and plan.pendingObjectiveCount==1,'temporarily missing exact entity name does not silently become fixed unmatched state')
targetEntities.npc[11].name='野猪';plan=samplePosition(nil,5)
check(plan.steps[1].objectiveKey=='npc:11' and plan.pendingObjectiveCount==0,'exact name recovery restores fine target')
plan=targetsScenario({goal('monster','野猪',0,6),goal('monster','迅猛龙幼崽',0,8)})
check(plan.pendingObjectiveCount==0 and api.route.nextObjectiveCheck==nil,'permanent textual mismatch does not trigger retry loop')
-- Route-level filtering and player skip remain dominant over database precision.
plan=targetsScenario();api.SetQuestSkip({questID=201});plan=api.GetPlan({})
check(plan.count==0 and plan.navigation.phase=='idle','player skipped task cannot return through fine-target lookup')
-- r11: each unfinished database-verified objective contributes its own map step.
do
    local function findGoal(key)
        for _,step in ipairs(api.GetPlan({}).steps) do if step.questID==201 and step.objectiveKey==key then return step end end
    end
    plan=targetsScenario()
    check(plan.count==2 and plan.questCount==1 and plan.objectiveStepCount==2 and plan.nativeStepCount==0,'two unfinished goals create two steps but only one quest')
    check(plan.stepUnit=='unfinished_objective_or_quest' and plan.steps[1].stepKey~=plan.steps[2].stepKey,'plan explains new step unit and stable per-goal identity')
    check(findGoal('npc:11') and findGoal('npc:12'),'all unfinished goals appear simultaneously instead of only first selected goal')
    check(findGoal('npc:11').displayTitle:find('野猪',1,true) and findGoal('npc:12').displayTitle:find('迅猛龙',1,true),'separate step labels identify the monster rather than repeat only quest title')
    check(findGoal('npc:11').questStepCount==2 and findGoal('npc:12').questStepCount==2,'each goal exposes same-task step coverage')
    targetEntities.npc[11].spawns={[17]={{50,0},{55,0},{60,0}}};plan=autoPlan()
    check(plan.count==2 and resolvedTargets().total==4,'multiple spawns remain alternatives and do not multiply goal route steps')
    rows[1].objectives[1]=goal('monster','野猪',6,6,true);plan=autoPlan()
    check(plan.count==1 and not findGoal('npc:11') and findGoal('npc:12'),'completing A removes just A while B remains visible')
    rows[1].ready=true;plan=autoPlan()
    check(plan.count==1 and plan.questCount==1 and plan.objectiveStepCount==0 and plan.nativeStepCount==1 and plan.steps[1].action=='turn_in','whole task completion collapses old goals into one native delivery step')
    -- Concrete user case: three monster goals, one finished, two remaining with independently chosen DB locations.
    local entities={npc={[3260]={name='刺背寻水者',x=500},[3261]={name='刺背织棘者',x=200},[3263]={name='刺背地卜师',x=800}},item={},object={}}
    plan=targetsScenario({goal('monster','刺背寻水者',5,6),goal('monster','刺背织棘者',12,12,true),goal('monster','刺背地卜师',0,12)},
        {[1]={{3263,nil,0},{3261,nil,0},{3260,nil,0}}},entities)
    check(plan.count==2 and findGoal('npc:3260') and findGoal('npc:3263') and not findGoal('npc:3261'),'Quilboar case displays water seeker5/6 and geomancer0/12 without completed thornweaver')
    check(findGoal('npc:3260').world.x==500 and findGoal('npc:3263').world.x==800,'each remaining monster uses its own database spawn coordinate')
    rows[1].objectives={rows[1].objectives[3],rows[1].objectives[2],rows[1].objectives[1]};plan=autoPlan()
    check(plan.count==2 and plan.steps[1].objectiveKey=='npc:3260','official objective reorder cannot lose or duplicate per-goal steps')
    -- Map ownership and temporary avoidances operate per goal, not all remaining goals of the task.
    plan=targetsScenario();local support=FixtureDB.Support.Get
    FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
    targetEntities.npc[12].area=18;plan=autoPlan()
    check(plan.count==1 and findGoal('npc:11') and not findGoal('npc:12'),'foreign goal does not hide current-map unfinished sibling or appear as projected local goal')
    FixtureDB.Support.Get=support
    plan=targetsScenario();api.route.spotAvoidances={{questID=201,objectiveKey='npc:11',mapID=101,world={continentID=1,x=500,y=0},expiresAt=GetTime()+600}}
    plan=autoPlan()
    check(plan.count==1 and findGoal('npc:12') and not findGoal('npc:11'),'temporarily avoided A does not suppress different remaining goal B')
    -- Reward reference still counts quests once after splitting tasks into several navigation steps.
    plan=targetsScenario();rows[1].xp=100
    rows[#rows+1]=routeRow(202,800,{xp=1000});rows[#rows+1]=routeRow(203,1000,{xp=3000})
    plan=autoPlan()
    check(plan.questCount==3 and plan.count==4 and plan.levelingPriority.reference.sampleCount==3 and plan.levelingPriority.reference.value==1000,'multi-goal task cannot duplicate its reward or bias the difficulty/XP reference')
    check(findGoal('npc:11').priorityWeight==findGoal('npc:12').priorityWeight,'same quest goals share the same native difficulty and reward calibration')
    -- Distinct goals can share exact spawn coordinates; show both pins with visual-only displacement and leader lines.
    plan=targetsScenario(nil,nil,nil,nil,400);targetEntities.npc[12].x=500;plan=autoPlan()
    check(plan.count==2 and plan.groups[1].count==2 and plan.groups[1].questCount==1 and #plan.groups[1].questIDs==1,'same quest contributes two nearby goals while group quest IDs remain unique')
    local originalProjection=C_Map.GetMapPosFromWorldPos
    C_Map.GetMapPosFromWorldPos=function(continent,point,mapID) return mapID,{x=point.x/1000,y=point.y/1000} end
    local canvas=CreateFrame('Frame');canvas:SetSize(1000,600);canvas:SetScale(2)
    WorldMapFrame=CreateFrame('Frame');WorldMapFrame.GetCanvas=function() return canvas end;WorldMapFrame.GetMapID=function() return 101 end
    Minimap=CreateFrame('Minimap');Minimap:Show();Fixture.radius=1000;Fixture.rotate=false
    samplePosition(nil)
    local worldView=api.route.views[#api.route.views];local mini=api.route.minimapView
    check(worldView.pins[1]:IsVisible() and worldView.pins[2]:IsVisible() and mini.pins[1]:IsVisible() and mini.pins[2]:IsVisible(),'both maps show both coincident target pins')
    local wp1,wp2=worldView.pins[1].point,worldView.pins[2].point
    local mp1,mp2=mini.pins[1].point,mini.pins[2].point
    check(math.abs(wp1[4]-wp2[4])>=23 or math.abs(wp1[5]-wp2[5])>=23,'world-map target numbers do not cover each other at identical coordinates')
    check(math.abs(mp1[4]-mp2[4])>=23 or math.abs(mp1[5]-mp2[5])>=23,'minimap target numbers remain separately clickable at identical coordinates')
    check(worldView.leaders[2]:IsVisible() and mini.leaders[2]:IsVisible() and worldView.pins[2].shifted,'moved numbers retain connector to the true map position')
    check(plan.steps[1].world.x==plan.steps[2].world.x and plan.steps[1].world.y==plan.steps[2].world.y,'visual separation never modifies navigation coordinates or distance')
    GameTooltip={lines={},SetOwner=function() end,SetText=function(self,text) self.title=text end,AddLine=function(self,text) self.lines[#self.lines+1]=text end,Show=function() end,Hide=function() end}
    worldView.pins[1]:GetScript('OnEnter')(worldView.pins[1])
    local siblingTip=false
    for _,line in ipairs(GameTooltip.lines) do if line:find('迅猛龙',1,true) then siblingTip=true end end
    check(siblingTip,'nearby tooltip includes another objective from the same quest')
    worldView.pins[1]:GetScript('OnLeave')(worldView.pins[1])
    -- Shift-click the second goal: its own objectiveKey must reach ChangeQuestSpot, not first goal of the quest.
    targetEntities.npc[12].spawns={[17]={{50,0},{90,0}}};autoPlan();samplePosition(nil)
    local secondPin
    for _,pin in pairs(worldView.pins) do if pin:IsVisible() and pin.step and pin.step.objectiveKey=='npc:12' then secondPin=pin end end
    Fixture.shift=true;secondPin:GetScript('OnClick')(secondPin,'RightButton');Fixture.shift=false
    plan=api.GetPlan({})
    check(plan.steps[1].objectiveKey=='npc:12' and plan.steps[1].world.x==900,'modified click on sibling goal changes that goal location and promotes the intended step')
    check(#plan.avoidedSpots==1 and plan.avoidedSpots[1].objectiveKey=='npc:12' and findGoal('npc:11').world.x==500,'other goal of same task remains untouched by clicked goal avoidance')
    samplePosition(nil)
    local hiddenLeader=worldView.leaders[2]
    api.OnUnload()
    check(not hiddenLeader:IsVisible(),'hot unload hides separation connector lines')
    api.OnReload()
    samplePosition(nil)
    local skipPin=worldView.pins[1]
    skipPin:GetScript('OnClick')(skipPin,'RightButton');plan=api.GetPlan({})
    check(plan.count==0 and YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped[201],'plain right click on any goal still skips the entire quest and all sibling goals')
    WorldMapFrame=nil;Minimap=nil;C_Map.GetMapPosFromWorldPos=originalProjection
    plan=targetsScenario();local before=plan.sequence
    for _,args in ipairs({{objectiveKey='npc:11'},{questID=201,objectiveKey=false},{questID=201,objectiveKey='invalid'}}) do
        check(not api.ChangeQuestSpot(args).ok,'invalid explicit goal key rejected without changing task selection')
    end
    check(not api.ChangeQuestSpot({questID=201,objectiveKey='npc:999'}).ok and api.GetPlan({}).sequence==before,'unknown goal key cannot fall back to first goal or mutate the route')
    -- Original-group continuation must not import a formerly remote sibling solely because questID matches.
    plan=targetsScenario(nil,nil,nil,nil,400);rows[#rows+1]=routeRow(202,680);plan=autoPlan()
    local oldSiblingGroup=findGoal('npc:12').groupIndex
    check(oldSiblingGroup~=plan.steps[1].groupIndex,'remote sibling starts outside current200yard group')
    rows[1].objectives[1]=goal('monster','野猪',6,6,true);targetEntities.npc[12].x=650;plan=autoPlan()
    check(plan.steps[1].questID==202 and plan.stability.reason=='continue_nearby_group','old group members retain continuity without importing a newly moved sibling')
    plan=api.Replan({})
    check(plan.steps[1].objectiveKey=='npc:12','manual replan can choose newly closer sibling outside prior group policy')
    -- Two exact goals -> one native fallback -> two exact goals must preserve identity and stale timers.
    plan=targetsScenario(nil,nil,nil,nil,400);local entered=plan.navigation.workStartedAt
    plan=samplePosition(nil,180)
    check(plan.count==2 and plan.navigation.stale,'two-goal route has expired A work timer before cache gap')
    rows[1].missing=true;plan=autoPlan()
    check(plan.count==1 and plan.nativeStepCount==1 and plan.objectiveStepCount==0 and not plan.steps[1].objectiveKey,'missing shared objective cache produces only one native fallback for the whole task')
    rows[1].missing=false;rows[1].objectives={rows[1].objectives[2],rows[1].objectives[1]};plan=autoPlan()
    check(plan.count==2 and plan.objectiveStepCount==2 and findGoal('npc:11') and findGoal('npc:12'),'reordered recovery restores each unfinished key exactly once')
    check(plan.navigation.workStartedAt==entered and plan.navigation.stale and not plan.navigation.protected,'multi-step recovery cannot renew the expired first-goal work timer')
    check(findGoal('npc:12').navigation.phase=='queued','sibling does not inherit recovered A active navigation')
    targetEntities.npc[11].readError=true;plan=autoPlan()
    check(plan.count==1 and plan.steps[1].targetMode=='native_poi','database coordinate exception creates one fallback rather than duplicate native steps')
    targetEntities.npc[11].readError=false;plan=autoPlan()
    check(plan.count==2 and plan.count==plan.objectiveStepCount+plan.nativeStepCount,'source recovery preserves full unique step accounting')
    rows[1].missing=true;autoPlan();api.SetQuestSkip({questID=201});rows[1].missing=false;plan=autoPlan()
    check(plan.count==0 and plan.questCount==0,'cache recovery cannot resurrect skipped sibling objectives')
    plan=targetsScenario();rows[1].rewardMissing=true;plan=api.Replan({})
    check(plan.count==2 and plan.levelingPriority.pendingRewardCount==1,'unknown reward is retried once per quest rather than once per goal')
    rows[1].rewardMissing=false
    local normalReward=GetQuestLogRewardXP;local reads=0
    GetQuestLogRewardXP=function(id) reads=reads+1;return normalReward(id) end
    plan=api.Replan({})
    check(reads==1 and plan.count==2,'native quest reward queried once when generating several goal steps')
    GetQuestLogRewardXP=normalReward
    local seenKeys={}
    for _,step in ipairs(plan.steps) do
        check(not seenKeys[step.stepKey],'every planned step has unique task-and-goal key')
        seenKeys[step.stepKey]=true
    end
end
-- r13: completion changes a filtered quest into one local delivery stop.
do
    local getType,getElite,getTag,requiredSkill=C_QuestLog.GetQuestType,C_QuestLog.IsEliteQuest,C_QuestLog.GetQuestTagInfo,FixtureDB.Quest.requiredSkill
    C_QuestLog.GetQuestType=function(id) return rowFor(id).instance and 81 or 0 end
    C_QuestLog.IsEliteQuest=function(id) return rowFor(id).elite or false end
    C_QuestLog.GetQuestTagInfo=function(id) if rowFor(id).profession then return {tradeskillLineID=356} end end
    FixtureDB.Quest.requiredSkill=function(id) if rowFor(id).dbProfession then return {356,1} end end
    rows={routeRow(201,100,{ready=true,instance=true}),routeRow(202,200,{ready=true,elite=true}),
        routeRow(203,300,{ready=true,profession=true}),routeRow(204,400,{ready=true,dbProfession=true,otherX={410,420}}),
        routeRow(205,500,{instance=true}),routeRow(206,600,{elite=true}),routeRow(207,700,{profession=true}),
        routeRow(208,800,{dbProfession=true}),routeRow(209,50,{ready=true,map=102}),
        routeRow(210,50,{ready=true,noPOI=true}),routeRow(211,50,{ready=true,failed=true}),
        routeRow(212,450,{complete=true,instance=true}),routeRow(213,900)}
    plan=scenario(rows)
    local byID,excluded={},{}
    for _,s in ipairs(plan.steps) do byID[s.questID]=s end
    for _,e in ipairs(plan.excluded) do excluded[e.questID]=e.reason end
    check(plan.turnInCount==4 and plan.completionPendingCount==1 and plan.count==6,'completed dungeon elite and profession tasks join one delivery route while ordinary work remains')
    for id=201,204 do
        local s=byID[id]
        check(s and s.action=='turn_in' and s.questStepCount==1 and not s.objectiveKey and #s.hotspots==0,'each completed type has one delivery stop rather than old combat hotspots')
        check(s.displayTitle:find('交任务',1,true)~=nil and s.priorityWeight==1,'delivery stop is labelled and has no dungeon or combat difficulty penalty')
    end
    check(plan.steps[1].questID==201 and byID[204].segmentDistance<=100,'delivery tasks participate in existing straight distance ordering')
    check(excluded[205]=='instance' and excluded[206]=='elite' and excluded[207]=='profession' and excluded[208]=='profession','unfinished difficult activity types remain filtered')
    check(excluded[209]=='outside_current_map','completed foreign delivery remains excluded rather than inserted at its old objective area')
    check(excluded[210]=='no_native_poi' and not byID[210],'no official point means no invented delivery location')
    check(excluded[211]=='failed','failed flag wins even if completion cache says ready')
    check(byID[212].action=='completion_pending' and byID[212].displayTitle:find('等待确认交付',1,true)~=nil,'complete but not ready is a pending stop rather than confirmed turn-in')
    -- Two map renderers share the same delivery suffix and avoid overstating pending confirmation.
    local originalProjection=C_Map.GetMapPosFromWorldPos
    C_Map.GetMapPosFromWorldPos=function(continent,point,mapID) return mapID,{x=point.x/1000,y=point.y/1000} end
    local canvas=CreateFrame('Frame');canvas:SetSize(1000,600)
    WorldMapFrame=CreateFrame('Frame');WorldMapFrame.GetCanvas=function() return canvas end;WorldMapFrame.GetMapID=function() return 101 end
    Minimap=CreateFrame('Minimap');Minimap:Show();Fixture.radius=2000;Fixture.rotate=false
    samplePosition(nil)
    local view=api.route.views[#api.route.views];local mini=api.route.minimapView
    for _,s in ipairs(plan.steps) do
        local suffix=s.action=='turn_in' and '?' or s.action=='completion_pending' and '~' or ''
        check(view.pins[s.index].text.text==s.index..suffix and mini.pins[s.index].text.text==s.index..suffix,'both map labels distinguish delivery question mark and pending tilde from combat points')
    end
    WorldMapFrame=nil;Minimap=nil;C_Map.GetMapPosFromWorldPos=originalProjection
    api.SetQuestSkip({questID=201});plan=api.GetPlan({})
    check(plan.turnInCount==3 and YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped[201],'manual task skip remains authoritative even when task is ready')
    rows={routeRow(201,500,{instance=true})};scenario(rows)
    check(api.GetPlan({}).count==0,'unfinished dungeon baseline remains excluded')
    rows[1].ready=true;plan=autoPlan()
    check(plan.count==1 and plan.turnInCount==1 and plan.navigation.phase=='turn_in','official completion event inserts previously filtered delivery immediately')
    local sequence=plan.sequence;plan=samplePosition(500)
    check(plan.count==1 and plan.steps[1].questID==201 and plan.navigation.phase=='turn_in','reaching delivery reference never counts as actually handing in quest')
    rows[1].ready=false;rows[1].complete=true;plan=autoPlan()
    check(plan.turnInCount==0 and plan.completionPendingCount==1 and plan.navigation.phase=='completion_pending','temporary ready flag loss retains only pending confirmation semantics')
    rows[1].complete=false;plan=autoPlan()
    check(plan.count==0,'reverted official completion reapplies unfinished activity filter')
    rows[1].ready=true;autoPlan();table.remove(rows,1);plan=autoPlan()
    check(plan.turnInCount==0 and plan.count==0 and plan.completionPendingCount==0,'actual quest log removal clears delivery step and counts')
    C_QuestLog.GetQuestType,C_QuestLog.IsEliteQuest,C_QuestLog.GetQuestTagInfo,FixtureDB.Quest.requiredSkill=getType,getElite,getTag,requiredSkill
end
-- r12: bounded density hotspots, one routed main plus two visible alternatives.
do
    local triple={{8,20},{10,20},{12,20},{48,50},{50,50},{52,50},{88,20},{90,20},{92,20}}
    local function hotScenario(spawns)
        return targetsScenario({goal('monster','野猪',0,6)},{[1]={{11,nil,0}}},
            {npc={[11]={name='野猪',spawns={[17]=spawns}}},item={},object={}},nil,0)
    end
    local function hotByX(x)
        for _,h in ipairs(api.GetPlan({}).steps[1].hotspots) do if near(h.world.x,x) then return h end end
    end
    plan=hotScenario(triple)
    check(plan.count==1 and plan.questCount==1 and #plan.steps[1].hotspots==3,'three regions show one main plus two backups without adding route steps')
    check(plan.steps[1].world.x==100 and plan.steps[1].world.y==200,'representative is an actual centrally placed spawn in the nearest density patch')
    check(plan.hotspotRules.radius==150 and plan.hotspotRules.separation==300 and not plan.hotspotRules.alternativesJoinRoute,'hotspot geometry and optional backup policy are explicit')
    check(hotByX(100).selected and not hotByX(500).selected and not hotByX(900).selected,'main and alternate hotspots carry selection flags')
    for _,h in ipairs(plan.steps[1].hotspots) do check(h.pointCount==3,'fixed radius reports distinct recorded locations within each patch') end
    for i,h in ipairs(plan.steps[1].hotspots) do
        for j=i+1,#plan.steps[1].hotspots do
            local other=plan.steps[1].hotspots[j]
            check((h.world.x-other.world.x)^2+(h.world.y-other.world.y)^2>=300^2,'visible hotspot centres have real world separation rather than near duplicates')
        end
    end
    local cachedID=plan.steps[1].hotspots[1].id;local builds=api.route.hotspotCacheMisses;local hits=api.route.hotspotCacheHits
    plan=autoPlan()
    check(api.route.hotspotCacheMisses==builds and api.route.hotspotCacheHits>hits,'unchanged static geometry is cached across route rebuilds')
    rows[1].objectives[1]=goal('monster','野猪',2,6);plan=autoPlan()
    check(plan.steps[1].objective.numFulfilled==2 and plan.steps[1].hotspots[1].id==cachedID,'geometry cache returns current progress instead of stale quest objects')
    local reversed={};for i=#triple,1,-1 do reversed[#reversed+1]=triple[i] end
    targetEntities.npc[11].spawns={[17]=reversed};plan=autoPlan()
    check(plan.steps[1].hotspots[1].id==cachedID and api.route.hotspotCacheMisses==builds,'input ordering cannot move representative or invalidate identical geometry')
    plan=hotScenario({{10,20},{10,20},{10.1,20.1},{12,20}})
    check(#plan.steps[1].hotspots==1 and plan.steps[1].hotspots[1].pointCount==2,'duplicate rows and locations within3yards cannot inflate hotspot density')
    local entities={npc={[31]={name='掉落怪',spawns={[17]={{10,20}}}}},object={[41]={name='宝箱',spawns={[17]={{10,20}}}}},item={[101]={name='材料',npcs={31},objects={41}}}}
    plan=targetsScenario({goal('item','材料',0,5)},{[3]={{101,nil,0}}},entities,nil,0)
    check(plan.steps[1].hotspots[1].pointCount==1,'overlapping NPC and object item sources count one physical location rather than double density')
    plan=hotScenario({{10,0},{90,0}})
    check(#plan.steps[1].hotspots==2 and plan.steps[1].hotspots[1].sparseFallback,'sparse unique creature locations remain usable without fabricating a third region')
    plan=hotScenario({{10,0},{12,0},{14,0},{90,0}})
    check(#plan.steps[1].hotspots==1 and near(plan.steps[1].world.x,120),'isolated outlier is not preferred over a genuinely dense patch')
    local chain={};for x=0,90,10 do chain[#chain+1]={x,0} end
    plan=hotScenario(chain)
    check(#plan.steps[1].hotspots==3 and plan.steps[1].hotspots[1].pointCount<=3,'chain-shaped spawns cannot turn into one unbounded density-connected region')
    local ring={};for i=0,7 do local angle=i*math.pi/4;ring[#ring+1]={50+17*math.cos(angle),50+17*math.sin(angle)} end
    plan=hotScenario(ring)
    local actual=false;for _,point in ipairs(ring) do if near(plan.steps[1].x,point[1]/100) and near(plan.steps[1].y,point[2]/100) then actual=true end end
    check(actual,'ring distribution never chooses empty arithmetic centre as a navigation destination')
    -- Legacy150yard avoidance remains an inclusive world circle, independent of hotspot membership.
    plan=hotScenario({{65,0},{95,0}})
    api.route.spotAvoidances={{questID=201,objectiveKey='npc:11',mapID=101,world={continentID=1,x=500,y=0},expiresAt=GetTime()+600}};plan=autoPlan()
    check(near(plan.steps[1].world.x,950),'hotspot centre exactly150yards from avoided point is blocked')
    plan=hotScenario({{65.0001,0},{95.1,0}})
    api.route.spotAvoidances={{questID=201,objectiveKey='npc:11',mapID=101,world={continentID=1,x=500,y=0},expiresAt=GetTime()+600}};plan=autoPlan()
    check(near(plan.steps[1].world.x,650.001),'hotspot centre just beyond150yard circle remains eligible')
    -- A fully avoided region cannot bias reward reference through surviving scattered edge spawns.
    plan=hotScenario({{40,0},{50,0},{60,0},{65,0},{70,0}});rows[1].xp=100
    rows[#rows+1]=routeRow(202,100,{xp=1000});rows[#rows+1]=routeRow(203,200,{xp=2000});rows[#rows+1]=routeRow(204,300,{xp=3000})
    api.route.spotAvoidances={{questID=201,objectiveKey='npc:11',mapID=101,world={continentID=1,x=600,y=0},expiresAt=GetTime()+600}};plan=autoPlan()
    check(plan.questCount==3 and plan.levelingPriority.reference.sampleCount==3 and plan.levelingPriority.reference.value==2000,'no eligible hotspot means task is absent from native XP median')
    -- Maps draw backups without adding route lines; choosing c selects c even when b is closer.
    plan=hotScenario(triple)
    local normalProjection=C_Map.GetMapPosFromWorldPos
    C_Map.GetMapPosFromWorldPos=function(continent,point,mapID) return mapID,{x=point.x/1000,y=point.y/1000} end
    local canvas=CreateFrame('Frame');canvas:SetSize(1000,600)
    WorldMapFrame=CreateFrame('Frame');WorldMapFrame.GetCanvas=function() return canvas end;WorldMapFrame.GetMapID=function() return 101 end
    Minimap=CreateFrame('Minimap');Minimap:Show();Fixture.radius=2000;Fixture.rotate=false
    samplePosition(nil)
    local view=api.route.views[#api.route.views];local mini=api.route.minimapView
    check(view.alternatives[1]:IsVisible() and view.alternatives[2]:IsVisible() and mini.alternatives[1]:IsVisible() and mini.alternatives[2]:IsVisible(),'world map and nearby minimap both show b and c backups')
    local lineCount=0;for _,line in pairs(view.lines) do if line:IsVisible() then lineCount=lineCount+1 end end
    check(lineCount==1 and plan.count==1 and near(plan.totalStraightDistance,math.sqrt(100^2+200^2)),'backup markers create no extra routed segments or mileage')
    check(view.alternatives[1].text.text=='1b' and view.alternatives[2].text.text=='1c','backup pin labels are distinguishable from mandatory numeric steps')
    local farID=hotByX(900).id;local clicked
    for _,pin in pairs(view.alternatives) do if pin.hotspot and pin.hotspot.id==farID then clicked=pin end end
    GameTooltip={lines={},SetOwner=function() end,SetText=function(self,text) self.title=text end,AddLine=function(self,text) self.lines[#self.lines+1]=text end,Show=function() end,Hide=function() end}
    clicked:GetScript('OnEnter')(clicked)
    check(GameTooltip.title:find('备选热点',1,true)~=nil,'backup hover explains optional hotspot rather than current working state')
    clicked:GetScript('OnLeave')(clicked)
    Fixture.shift=true;clicked:GetScript('OnClick')(clicked,'RightButton');Fixture.shift=false;plan=api.GetPlan({})
    check(near(plan.steps[1].world.x,900) and plan.steps[1].hotspots[1].id==farID,'Shift right click c chooses exact displayed hotspot instead of nearer b')
    check(plan.count==1 and #plan.steps[1].hotspots==2 and #plan.avoidedSpots==1,'selected backup replaces main and old150yard area is hidden rather than queued as another required step')
    samplePosition(nil)
    local retainedID=plan.steps[1].hotspots[1].id
    rows[1].objectives[1]=goal('monster','野猪',3,6);plan=autoPlan()
    check(plan.steps[1].hotspots[1].id==retainedID,'real goal progress does not bounce selected hotspot to another cluster')
    local oldBackup=view.alternatives[1]
    api.OnUnload()
    check(not oldBackup:IsVisible() and oldBackup.step==nil and oldBackup.hotspot==nil,'unload hides backup pins and releases old progress references')
    api.OnReload();samplePosition(nil)
    rows[1].objectives[1]=goal('monster','野猪',6,6,true);plan=autoPlan();samplePosition(nil)
    local visible=false;for _,pin in pairs(view.alternatives) do if pin:IsVisible() then visible=true end end
    check(not visible and plan.objectiveStepCount==0,'completed goal removes its main hotspot and all backup pins together')
    WorldMapFrame=nil;Minimap=nil;C_Map.GetMapPosFromWorldPos=normalProjection
    -- Stale/invalid selections and failure on second read leave route, timers, avoidances and events untouched.
    plan=hotScenario(triple);local before,oldProgress,oldAvoid,oldWork=plan,api.route.progress,api.route.spotAvoidances,api.route.workSession
    for _,args in ipairs({{hotspotID='x'},{questID=201,hotspotID='x'},{questID=201,objectiveKey='npc:11',hotspotID=false}}) do
        check(not api.ChangeQuestSpot(args).ok,'invalid hotspot selector cannot fall back to arbitrary region')
    end
    check(not api.ChangeQuestSpot({questID=201,objectiveKey='npc:11',hotspotID='stale'}).ok and api.GetPlan({})==before,'unknown hotspotID leaves selected region unchanged')
    local normalObjectives=C_QuestLog.GetQuestObjectives;local reads=0
    C_QuestLog.GetQuestObjectives=function(id) if id==201 then reads=reads+1;if reads>=2 then return nil end end;return normalObjectives(id) end
    local normalEmit=api.WB.Emit;local events=0;api.WB.Emit=function() events=events+1 end
    local result=api.ChangeQuestSpot({questID=201,objectiveKey='npc:11',hotspotID=hotByX(900).id})
    C_QuestLog.GetQuestObjectives=normalObjectives;api.WB.Emit=normalEmit
    check(not result.ok and api.GetPlan({})==before and api.route.progress==oldProgress and api.route.workSession==oldWork,'second-read cache failure rolls back draft plan and progress/timer identities')
    check(api.route.spotAvoidances==oldAvoid and #oldAvoid==0 and api.GetPlan({}).sequence==before.sequence and events==0,'failed draft cannot leave avoidance, increment sequence or emit route-changed events')
    -- Full allowed2400-point item-source union: geometry is cached, and rendering never rebuilds it.
    local one,two={},{}
    for row=0,47 do for column=0,49 do
        local target=row<24 and one or two;target[#target+1]={10+column*.31,10+row*.4}
    end end
    local large={npc={[31]={name='来源甲',spawns={[17]=one}},[32]={name='来源乙',spawns={[17]=two}}},object={},item={[101]={name='材料',npcs={31,32}}}}
    plan=targetsScenario({goal('item','材料',0,60)},{[3]={{101,nil,0}}},large,nil,0)
    check(plan.count==1 and #plan.steps[1].hotspots<=3 and plan.steps[1].hotspots[1].pointCount>1000,'maximum supported2400-point source set yields bounded real density hotspots')
    local cold=api.route.hotspotCacheMisses;local warm=api.route.hotspotCacheHits
    plan=autoPlan()
    check(api.route.hotspotCacheMisses==cold and api.route.hotspotCacheHits>warm,'large region replan reuses cached geometry rather than quadratic re-scan')
    for i=1,70 do rows[1].id=300+i;targetEntities.npc[31].spawns={[17]={{10+i*.1,10}}};targetEntities.npc[32].spawns={[17]={{90,90}}};autoPlan() end
    check(#api.route.hotspotCacheOrder==64,'seventy distinct quest goals enforce the static geometry cache entry bound')
    check(api.route.hotspotCache['201:item:101:101']==nil,'old geometry entries are actually evicted rather than retained outside the bounded key queue')
end
-- r10: a spot change is an atomic, same-goal local choice, not a task skip or generic replan.
do
    local function singleSpotScenario()
        local entities={npc={[11]={name='野猪',spawns={[17]={{50,0},{80,0}}}}},item={},object={}}
        return targetsScenario({goal('monster','野猪',0,6)},{[1]={{11,nil,0}}},entities,nil,400)
    end
    plan=targetsScenario(nil,nil,nil,nil,400)
    targetEntities.npc[11].spawns={[17]={{50,0},{60,0},{65,0},{66,0},{90,0},{95,0}}}
    targetEntities.npc[12].x=410
    rows[#rows+1]=routeRow(202,405)
    local changed=api.ChangeQuestSpot({})
    plan=api.GetPlan({})
    check(changed.ok and plan.steps[1].questID==201 and plan.steps[1].objectiveKey=='npc:11','explicit change chooses same quest and subgoal despite nearer goals/tasks')
    check(near(plan.steps[1].world.x,900),'r12 change selects a distinct density hotspot instead of another scattered point of the same area')
    check(not YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped[201] and #plan.avoidedSpots==1,'changing a spot never skips the task')
    check(plan.stability.reason=='manual_spot_change' and plan.navigation.workStartedAt==nil,'spot change releases old work-area protection')
    check(plan.spotRules.duration==600 and plan.spotRules.radius==150,'spot rules are visible in read-only plan')
    plan=targetsScenario()
    local oldPlan,oldProgress,oldSequence=plan,api.route.progress,plan.sequence
    changed=api.ChangeQuestSpot({})
    check(not changed.ok and changed.error.code=='no_alternative_spot','another goal location is not a same-goal alternative')
    check(api.GetPlan({})==oldPlan and api.route.progress==oldProgress and api.GetPlan({}).sequence==oldSequence and #api.route.spotAvoidances==0,'failed change leaves plan/timers/progress/avoidances untouched')
    rows[1].missing=true;changed=api.ChangeQuestSpot({})
    check(not changed.ok and api.GetPlan({})==oldPlan,'fresh missing progress fails without changing last valid route')
    rows[1].missing=false;rows[1].readError=true
    local called,readFailure=pcall(api.ChangeQuestSpot,{})
    check(called and not readFailure.ok and api.GetPlan({})==oldPlan,'fresh official objective read errors are contained on a player click')
    rows[1].readError=false;rows[1].objectives[1]=goal('monster','野猪',6,6,true)
    check(not api.ChangeQuestSpot({}).ok and api.GetPlan({})==oldPlan,'a freshly completed old subgoal cannot be replaced by a different subgoal')
    singleSpotScenario();changed=api.ChangeQuestSpot({questID=201})
    check(changed.ok and near(changed.selected.world.x,800),'explicit quest ID selects its other local point')
    local expiry=changed.expiresAt
    plan=samplePosition(nil,599.99)
    check(#plan.avoidedSpots==1 and near(plan.steps[1].world.x,800),'temporary avoidance remains active just before600seconds')
    plan=samplePosition(nil,.01)
    check(#plan.avoidedSpots==0 and near(plan.steps[1].world.x,500),'avoidance expires exactly at600seconds without needing movement')
    check(api.route.nextSpotCheck==nil and GetTime()>=expiry,'expiry retry stops after all avoidances expire')
    singleSpotScenario();api.ChangeQuestSpot({})
    rows[1].missing=true;plan=autoPlan()
    check(plan.count==0 and plan.excluded[1].reason=='spot_data_unavailable','temporary precise-data loss cannot bypass an avoidance through native old POI')
    check(plan.pendingLocationCount==1,'avoided task waits and retries when detailed positions temporarily disappear')
    rows[1].missing=false;plan=autoPlan()
    check(plan.count==1 and near(plan.steps[1].world.x,800),'precise data recovery respects the original avoided area')
    targetEntities.npc[11].readError=true;plan=autoPlan()
    check(plan.count==0 and plan.excluded[1].reason=='spot_data_unavailable','database spawn exceptions also cannot route back through old native point')
    targetEntities.npc[11].readError=false;rows[1].ready=true;plan=autoPlan()
    check(plan.navigation.phase=='turn_in' and #plan.avoidedSpots==0,'official completion retires avoidance and allows native delivery point')
    singleSpotScenario();api.ChangeQuestSpot({});plan=samplePosition(700)
    local changedWorkStart=plan.navigation.workStartedAt
    plan=samplePosition(nil,180)
    check(plan.navigation.stale and not plan.navigation.protected,'changed area can expire its own no-progress protection')
    rows[1].missing=true;plan=autoPlan()
    check(plan.navigation.phase=='unavailable' and api.route.workSession.workStartedAt==changedWorkStart,'avoided-area cache wait suspends rather than discards old work timer')
    rows[1].missing=false;plan=autoPlan()
    check(plan.navigation.workStartedAt==changedWorkStart and plan.navigation.stale and not plan.navigation.protected,'recovered changed area cannot renew expired protection')
    singleSpotScenario();api.ChangeQuestSpot({})
    api.route.spotAvoidances[#api.route.spotAvoidances+1]={questID=202,objectiveKey='npc:99',mapID=101,world={continentID=1,x=50,y=0},expiresAt=GetTime()+600}
    rows[#rows+1]=routeRow(202,1200)
    plan=api.ClearSpotAvoidances({questID=201})
    check(#plan.avoidedSpots==1 and plan.avoidedSpots[1].questID==202,'clearing one task avoids changing other task avoidances')
    YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped[202]=true
    plan=api.ClearSpotAvoidances({})
    check(#plan.avoidedSpots==0 and YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped[202],'clear all locations preserves player task skips')
    check(YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].spotAvoidances==nil,'uptime-based temporary avoidances never enter SavedVariables')
    singleSpotScenario();Fixture.playerMapID=102;changed=api.ChangeQuestSpot({})
    check(not changed.ok and #api.route.spotAvoidances==0,'a stale map pin cannot switch a point after the player changes map')
    singleSpotScenario();rows[1].ready=true;plan=autoPlan()
    check(not api.ChangeQuestSpot({}).ok,'turn-in references cannot be cycled as monster locations')
    for _,bad in ipairs({{questID=0},{questID=false},{questID='201'}}) do
        check(not api.ChangeQuestSpot(bad).ok and not api.ClearSpotAvoidances(bad).ok,'invalid location change/reset IDs rejected')
    end
    -- Both map pin callbacks keep original right-click behavior and expose the new modified click.
    singleSpotScenario()
    local pinView={overlay=CreateFrame('Frame'),pins={},lines={}}
    Minimap=CreateFrame('Minimap');Minimap:Show();Fixture.radius=100;Fixture.rotate=false
    samplePosition(nil)
    local routePin=api.route.minimapView.pins[1]
    Fixture.shift=true;routePin:GetScript('OnClick')(routePin,'RightButton');Fixture.shift=false
    check(near(api.GetPlan({}).steps[1].world.x,800) and not YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped[201],'Shift right click switches place without taking skip branch')
    routePin:GetScript('OnClick')(routePin,'RightButton')
    check(YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped[201],'plain right click still skips task')
    Minimap=nil
    singleSpotScenario();api.ChangeQuestSpot({})
    local invalidCommandSequence=api.GetPlan({}).sequence
    SlashCmdList.YYQROUTE('nextspot not_an_id');SlashCmdList.YYQROUTE('resetspots not_an_id')
    check(api.GetPlan({}).sequence==invalidCommandSequence and #api.route.spotAvoidances==1,'invalid slash IDs cannot accidentally change current spot or clear all avoidances')
    -- NPC identity classification combines all eligible tasks and each exact subgoal, not route locations.
    Fixture.units={target={id=11},nameplate1={id=11},nameplate2={id=12}}
    local plate1,plate2=CreateFrame('Frame'),CreateFrame('Frame')
    plate1.UnitFrame={unit='nameplate1'};plate2.namePlateUnitToken='nameplate2'
    Fixture.plates={plate1,plate2}
    plan=targetsScenario()
    local unit=api.GetUnitTasks({unit='target'})
    check(unit.needed and unit.npcID==11 and unit.label=='击杀 0/6' and unit.currentTarget,'readable monster ID resolves exact kill progress and current target')
    local seq=plan.sequence
    api.GetUnitTasks({unit='target'})
    check(api.GetPlan({}).sequence==seq,'unit task lookup is read-only and does not replan')
    check(not api.GetUnitTasks({unit=false}).ok,'explicit false unit is invalid rather than silently targeting current target')
    samplePosition(nil)
    local marker=api.route.nameplateView.markers[plate1]
    check(marker and marker:IsVisible() and marker.mouse==false and marker.info.npcID==11,'existing visible plate gets its own noninteractive task label')
    check(marker.text.text:find('击杀 0/6',1,true)~=nil,'visible label names kill requirement rather than a generic quest relation')
    rows[1].objectives[1]=goal('monster','野猪',6,6,true);plan=autoPlan()
    check(not api.GetUnitTasks({unit='target'}).needed and not marker:IsVisible(),'finished subgoal removes its label while another goal remains active')
    Fixture.units.nameplate1.id=12;samplePosition(nil)
    check(marker:IsVisible() and marker.info.npcID==12 and marker.text.text:find('0/8',1,true),'same frame/token reused for another NPC receives new identity and counter')
    Fixture.units.nameplate1.id=999;samplePosition(nil)
    check(not marker:IsVisible() and marker.info==nil,'frame reused for an unmatched NPC clears previous task data')
    -- Real secret-like sentinel is blocked before numeric conversion, lookup or retention.
    local normalAccess=canaccessvalue
    local sentinel=setmetatable({}, {__tostring=function() error('must never stringify identity secret') end})
    canaccessvalue=function(value) return value~=sentinel end
    Fixture.units.nameplate1.id=sentinel;samplePosition(nil)
    unit=api.GetUnitTasks({unit='nameplate1'})
    check(unit.state=='unknown' and unit.reason=='restricted_identity' and unit.npcID==nil and not marker:IsVisible(),'restricted identity never reuses last readable ID or appears as finished/unrelated')
    canaccessvalue=normalAccess;Fixture.units.nameplate1.id=11
    Fixture.units.nameplate1.readError=true;samplePosition(nil)
    check(not marker:IsVisible() and api.GetUnitTasks({unit='nameplate1'}).state=='unknown','unit identity exceptions hide labels without throwing')
    Fixture.units.nameplate1.readError=false;Fixture.units.nameplate1.dead=true
    check(api.GetUnitTasks({unit='nameplate1'}).state=='not_eligible','dead units do not claim to be live kill targets')
    Fixture.units.nameplate1.dead=false;Fixture.units.nameplate1.player=true
    check(not api.GetUnitTasks({unit='nameplate1'}).needed,'players never get monster task markers')
    Fixture.units.nameplate1.player=false;Fixture.units.nameplate1.attack=false
    check(not api.GetUnitTasks({unit='nameplate1'}).needed,'non-attackable NPCs never get kill markers')
    Fixture.units.nameplate1.attack=true
    check(api.GetUnitTasks({unit='mouseover'}).state=='unknown' and not api.GetUnitTasks({unit='party1'}).ok,'missing unit is unknown and unsupported tokens are rejected')
    -- Killing enough is not enough if the same NPC still provides a missing material.
    local mixed={npc={[11]={name='野猪',readError=true}},object={},item={[101]={name='獠牙',npcs={11,11}}}}
    targetsScenario({goal('monster','野猪',2,6),goal('item','獠牙',1,5)},{[1]={{11,nil,0}},[3]={{101,nil,0}}},mixed)
    unit=api.GetUnitTasks({unit='target'})
    check(unit.neededCount==2 and unit.label=='击杀 2/6 · 材料 1/5','one NPC reports kill and material progress independently without duplicate drop relations')
    check(api.GetPlan({}).steps[1].targetMode=='native_poi' and unit.needed,'spawn getter errors do not erase independently verified NPC identity')
    rows[1].objectives[1]=goal('monster','野猪',6,6,true);autoPlan();unit=api.GetUnitTasks({unit='target'})
    check(unit.neededCount==1 and unit.label=='材料 1/5','completed kill requirement does not hide NPC still supplying needed material')
    rows[1].objectives[2]=goal('item','獠牙',5,5,true);autoPlan();unit=api.GetUnitTasks({unit='target'})
    check(not unit.needed and unit.state=='no_remaining_known_goals','all known goals complete removes needed flag without promising global irrelevance')
    rows[1].objectives[2]=goal('item','獠牙',5,5,false);autoPlan()
    check(api.GetUnitTasks({unit='target'}).needed,'official finished false remains authoritative even with full numeric count')
    local originalObjects,originalDrops=FixtureDB.Item.objectDrops,FixtureDB.Item.npcDrops
    FixtureDB.Item.objectDrops=function() error('object drops unavailable') end;autoPlan()
    check(api.GetUnitTasks({unit='target'}).needed,'unrelated object-drop getter failure cannot break valid NPC material classification')
    FixtureDB.Item.npcDrops=function() error('NPC drop data missing') end;autoPlan()
    check(api.GetUnitTasks({unit='target'}).state=='unknown','unknown direct NPC source relations cannot become fake negative match')
    FixtureDB.Item.npcDrops=function() return nil end;autoPlan()
    check(api.GetUnitTasks({unit='target'}).state=='unknown','nil drop relations are unknown instead of an authoritative empty source list')
    FixtureDB.Item.objectDrops=originalObjects;FixtureDB.Item.npcDrops=originalDrops
    targetsScenario()
    rows[1].objectives[1]=goal('monster','野猪',6,6,true)
    rows[#rows+1]=routeRow(202,1000,{objectives={goal('monster','野猪',3,6),goal('monster','迅猛龙',0,8)}})
    autoPlan();unit=api.GetUnitTasks({unit='target'})
    check(unit.needed and unit.neededCount==1 and unit.label=='击杀 3/6' and #unit.tasks==2,'completion in one task cannot hide same NPC still needed by another task')
    targetsScenario();targetEntities.npc[11].spawns={[17]={{-1,-1}}};autoPlan()
    check(api.GetUnitTasks({unit='target'}).needed,'missing valid static coordinates do not prevent known monster identification')
    rows[1].missing=true;autoPlan()
    check(api.GetUnitTasks({unit='target'}).state=='unknown','missing official progress is not fabricated as zero or completed')
    rows[1].missing=false;autoPlan()
    check(api.GetUnitTasks({unit='target'}).needed,'official progress recovery restores accurate unit classification')
    local event=api.route.driver:GetScript('OnEvent')
    event(api.route.driver,'QUEST_LOG_UPDATE')
    check(not marker:IsVisible() and api.GetUnitTasks({unit='target'}).reason=='quest_data_updating','pending quest event clears stale labels until merged data refresh')
    samplePosition(nil,1)
    api.SetQuestSkip({questID=201})
    check(not api.GetUnitTasks({unit='target'}).needed,'player task skip dominates marker relationship')
    api.SetQuestSkip({questID=201,skipped=false});rows[1].failed=true;autoPlan()
    check(not api.GetUnitTasks({unit='target'}).needed,'failed task cannot keep wanted monster labels')
    rows[1].failed=false;rows[1].ready=true;autoPlan()
    check(not api.GetUnitTasks({unit='target'}).needed,'official ready task does not keep old kill labels')
    targetsScenario();local getType,getElite,getTag=C_QuestLog.GetQuestType,C_QuestLog.IsEliteQuest,C_QuestLog.GetQuestTagInfo
    C_QuestLog.GetQuestType=function() return 81 end;autoPlan()
    check(not api.GetUnitTasks({unit='target'}).needed,'dungeon task exclusion applies to nameplates')
    C_QuestLog.GetQuestType=getType;C_QuestLog.IsEliteQuest=function() return true end;autoPlan()
    check(not api.GetUnitTasks({unit='target'}).needed,'elite task exclusion applies to nameplates')
    C_QuestLog.IsEliteQuest=getElite;C_QuestLog.GetQuestTagInfo=function() return {tradeskillLineID=356} end;autoPlan()
    check(not api.GetUnitTasks({unit='target'}).needed,'profession task exclusion applies to nameplates')
    C_QuestLog.GetQuestTagInfo=getTag;autoPlan();samplePosition(nil)
    check(marker:IsVisible(),'restoring eligible progress redraws pooled marker')
    local pool=api.route.nameplateView
    event(api.route.driver,'NAME_PLATE_UNIT_REMOVED','nameplate1')
    check(not marker:IsVisible() and marker.unit==nil,'plate removal clears own marker unit and goal references')
    event(api.route.driver,'NAME_PLATE_UNIT_ADDED','nameplate1')
    check(marker:IsVisible() and api.route.nameplateView==pool,'re-added plate reuses one marker pool')
    plate1.forbidden=true;samplePosition(nil)
    check(not marker:IsVisible(),'forbidden plate never receives markers')
    plate1.forbidden=false
    api.SetRouteOptions({nameplatesEnabled=false});samplePosition(nil)
    check(not marker:IsVisible() and api.GetPlan({}).enabled,'nameplate switch leaves route display option enabled')
    api.SetRouteOptions({nameplatesEnabled=true});samplePosition(nil)
    check(marker:IsVisible(),'nameplate option can restore the existing pooled label')
    api.OnUnload()
    check(not marker:IsVisible() and marker.info==nil and marker.unit==nil,'hot unload clears nameplate target references')
    api.OnReload()
    check(marker:IsVisible() and api.route.nameplateView==pool,'hot reload immediately reuses marker for already-visible plate')
    Fixture.plates={};Fixture.units={};samplePosition(nil)
    check(not marker:IsVisible(),'disappearing plate without explicit removal cannot leave stale label')
    check(not api.SetRouteOptions({nameplatesEnabled='yes'}).ok,'invalid marker option rejected')
end
FixtureDB.Quest.objectives=savedQuestObjectives
FixtureDB.Npc=savedEntity.Npc;FixtureDB.Object=savedEntity.Object;FixtureDB.Item=savedEntity.Item
QUEST_MONSTERS_KILLED=nil;QUEST_ITEMS_NEEDED=nil;QUEST_OBJECTS_FOUND=nil
-- Prepare real two-map frame pools for the Python harness to re-execute source on same namespace.
Fixture.worldScale=1000
scenario({routeRow(201,500),routeRow(202,680)},500)
Minimap=CreateFrame('Minimap');Minimap:Show();Fixture.radius=100;Fixture.rotate=false
local hotCanvas=CreateFrame('Frame');hotCanvas:SetSize(1002,668)
WorldMapFrame=CreateFrame('Frame');WorldMapFrame.GetCanvas=function() return hotCanvas end
WorldMapFrame.GetMapID=function() return 101 end;WorldMapFrame:Show()
C_Map.GetMapPosFromWorldPos=function(continent,point,mapID) return mapID,{x=point.x/1000,y=point.y/1000} end
Fixture.time=Fixture.time+1;activeTick(driver,.2)
FixtureHotload={driver=api.route.driver,mini=api.route.minimapView,world=api.route.views[#api.route.views]}
FixtureHotload.oldEnter=FixtureHotload.mini.pins[1]:GetScript('OnEnter')
return passed
'''


RELOAD_CHECKS = r'''
local api=WoWBridgeNS.YYQQuestAPI
local passed=0
local function check(value,label)
    if not value then error('FAIL: '..label) end
    passed=passed+1
end
local h=FixtureHotload
check(api.route.driver==h.driver and api.route.driver:GetScript('OnUpdate')~=nil,'source re-execution reuses one live driver')
check(api.route.minimapView==h.mini,'source re-execution reuses small-map pool')
check(api.route.views[#api.route.views]==h.world,'source re-execution reuses world-map pool')
check(h.mini.pins[1]:GetScript('OnEnter')~=h.oldEnter,'source re-execution replaces old tooltip closure')
check(h.mini.pins[1].step==h.world.pins[1].step,'both maps share same current step')
check(h.mini.pins[1].step.navigation==api.route.plan.navigation and api.route.plan.navigation.phase=='working','both map pins share current live work phase')
check(api.route.plan.groups[1].count==2,'source reload keeps grouped route valid')
GameTooltip={lines={},SetOwner=function() end,SetText=function(self,text) self.title=text end,
    AddLine=function(self,text) self.lines[#self.lines+1]=text end,Show=function() end,Hide=function() end}
h.mini.pins[1]:GetScript('OnEnter')(h.mini.pins[1])
local nearby,experienceTip,phaseTip=false,false,false
for _,line in ipairs(GameTooltip.lines) do
    if line:find('附近还有',1,true) then nearby=true end
    if line:find('客户端奖励经验',1,true) then experienceTip=true end
    if line:find('在这一带完成任务目标',1,true) then phaseTip=true end
end
check(nearby,'reused map pin exposes updated group tooltip after source reload')
check(experienceTip,'reused pin shows new native reward explanation after source reload')
check(phaseTip,'reused map pin exposes new work state in tooltip')
Fixture.playerX=.3;Fixture.time=Fixture.time+1
api.route.driver:GetScript('OnUpdate')(api.route.driver,.2)
local travelTip=false
for _,line in ipairs(GameTooltip.lines) do if line:find('赶路中',1,true) then travelTip=true end end
check(travelTip,'stationary hovered tooltip refreshes when phase changes without new mouse entry')
h.mini.pins[1]:GetScript('OnLeave')(h.mini.pins[1])
check(api.route.hoveredPin==nil,'leaving pin releases live tooltip ownership')
local sequence=api.route.plan.sequence
api.OnReload()
check(api.route.plan.sequence==sequence,'reload hook does not duplicate file-load initialization')
return passed
'''

LEGACY_RELOAD_CHECKS = r'''
local api=WoWBridgeNS.YYQQuestAPI
assert(api.apiRevision==13 and api.route.plan.stability and api.route.plan.navigation,'legacy namespace gains new policy fields')
assert(api.route.progress and api.route.plan.groups,'legacy namespace without progress and groups upgrades')
assert(api.route.plan.steps[1].questID==202,'skipped legacy first never resurrected on source reload')
assert(api.route.driver==FixtureHotload.driver,'legacy upgrade still reuses driver')
return 4
'''

FRESH_RELOAD_CHECKS = r'''
local api=WoWBridgeNS.YYQQuestAPI
assert(api.route.driver~=FixtureHotload.driver,'new namespace creates own driver')
assert(FixtureHotload.driver:GetScript('OnUpdate')==nil and next(FixtureHotload.driver.events)==nil,'old driver is inactive after namespace replacement')
assert(api.route.plan.steps[1].questID==202,'fresh login preserves saved skip preferences')
assert(api.route.plan.stability.retained==false,'fresh session does not restore uptime-based target hold')
assert(api.route.plan.navigation.phase=='travel' and api.route.plan.navigation.workStartedAt==nil,'fresh namespace does not inherit prior work timers')
assert(api.route.minimapView.pins[1].step==api.route.views[1].pins[1].step,'fresh namespace maps share same steps')
return 6
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--addon", type=Path, default=DEFAULT_ADDON)
    args = parser.parse_args()
    runtime = LuaRuntime(unpack_returned_tuples=True)
    runtime.execute(SETUP)
    source = args.addon.read_text(encoding="utf-8-sig")
    namespace = runtime.table()
    runtime.execute(source, "YYQQuestAPI", namespace)
    passed = runtime.execute(CHECKS)
    namespace.OnUnload()
    runtime.execute(source, "YYQQuestAPI", namespace)
    passed += runtime.execute(RELOAD_CHECKS)
    runtime.execute("""
        local api=WoWBridgeNS.YYQQuestAPI
        api.OnUnload()
        api.route.progress=nil;api.route.plan.groups=nil;api.route.plan.stability=nil;api.route.plan.navigation=nil
        for _,step in ipairs(api.route.plan.steps) do step.groupIndex=nil;step.groupSize=nil;step.navigation=nil end
        YYQQuestAPIDB.routes['FixtureRealm:FixturePlayer'].skipped[201]=true
    """)
    runtime.execute(source, "YYQQuestAPI", namespace)
    passed += runtime.execute(LEGACY_RELOAD_CHECKS)
    namespace.OnUnload()
    runtime.execute(source, "YYQQuestAPI", runtime.table())
    passed += runtime.execute(FRESH_RELOAD_CHECKS)
    print(f"PASS: {passed} isolated Lua 5.1 checks; addon={args.addon}")


if __name__ == "__main__":
    main()
