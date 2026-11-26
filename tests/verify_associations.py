"""Deterministic, offline association/lookahead checks in isolated Lua 5.1 runtimes.

Requires the existing lupa dependency; never connects to the game.
Run: python tests/verify_associations.py
Uses the same --addon directory/.toc/.lua resolution as verify_quest_data.py.
"""
import argparse
from pathlib import Path

from lupa.lua51 import LuaRuntime
from verify_quest_data import DEFAULT_ADDON, SETUP, execute_addon, read_addon_sources


FIXTURE = r'''
Fixture.worldScale=10000
Fixture.mapOrder={101}
Fixture.quests={}; Fixture.log={}; Fixture.status={}; Fixture.official={}
Fixture.completed={}; Fixture.historyUnknown={}; Fixture.bags={}; Fixture.items={}
Fixture.locations={npc={},object={}}; Fixture.offered={}; Fixture.units={}
QUEST_MONSTERS_KILLED='%s: %d/%d'
QUEST_OBJECTS_FOUND='%s: %d/%d'
QUEST_ITEMS_NEEDED='%s: %d/%d'
function UnitClass() return 'Warrior','WARRIOR',1 end
function UnitRace() return 'Orc','Orc',2 end
C_QuestLog.GetNumQuestLogEntries=function() return #Fixture.log,#Fixture.log end
C_QuestLog.IsOnQuest=function(id)
    for _,activeID in ipairs(Fixture.log) do if activeID==id then return true end end
    return false
end
C_QuestLog.GetInfo=function(i)
    local id=Fixture.log[i]
    return {questID=id,title='Quest '..id,level=19,questLogIndex=i,isHeader=false}
end
C_QuestLog.GetQuestTagInfo=function() return nil end
C_QuestLog.GetQuestType=function() return 0 end
C_QuestLog.IsEliteQuest=function(id) return Fixture.quests[id] and Fixture.quests[id].elite==true or false end
C_QuestLog.IsRepeatableQuest=function(id) return Fixture.quests[id] and Fixture.quests[id].repeatable==true or false end
C_QuestLog.IsFailed=function(id) return Fixture.status[id]=='failed' end
C_QuestLog.IsComplete=function(id)
    return Fixture.status[id]=='complete' or Fixture.status[id]=='ready_for_turn_in'
end
C_QuestLog.ReadyForTurnIn=function(id) return Fixture.status[id]=='ready_for_turn_in' end
C_QuestLog.IsQuestFlaggedCompleted=function(id)
    if Fixture.historyUnknown[id] then return nil end
    return Fixture.completed[id]==true
end
C_QuestLog.GetQuestObjectives=function(id)
    if Fixture.official[id] then return Fixture.official[id] end
    local out={}
    local groups=(Fixture.quests[id] or {}).objectives or {}
    for group,kind in ipairs({'npc','object','item'}) do
        for _,row in ipairs(groups[group] or {}) do
            out[#out+1]={text=kind..row[1]..': 0/1',type=group==1 and 'monster' or kind,
                finished=false,numFulfilled=0,numRequired=1}
        end
    end
    return out
end
C_GossipInfo={GetAvailableQuests=function() return Fixture.offered end,
    GetNumAvailableQuests=function() return #Fixture.offered end}
C_Container={
    GetContainerNumSlots=function(bag) return bag==0 and #Fixture.bags or 0 end,
    GetContainerItemID=function(bag,slot) return bag==0 and Fixture.bags[slot] or nil end,
    GetContainerItemQuestInfo=function() return nil end,
}
FixtureDB.Quest={
    Exists=function(id) return Fixture.quests[id]~=nil end,
    Get=function(id,field) return (Fixture.quests[id] or {})[field] end,
    GetAllIds=function()
        local ids={}; for id in pairs(Fixture.quests) do ids[#ids+1]=id end
        table.sort(ids); return ids
    end,
}
for _,field in ipairs({'name','questLevel','requiredLevel','requiredSkill','objectivesText','objectives',
    'startedBy','finishedBy','preQuestSingle','preQuestGroup','childQuests','nextQuestInChain','exclusiveTo'}) do
    FixtureDB.Quest[field]=function(id) return FixtureDB.Quest.Get(id,field) end
end
for _,kind in ipairs({'npc','object'}) do
    local entityKind=kind
    local entity={
        Exists=function(id) return Fixture.locations[entityKind][id]~=nil end,
        name=function(id) return entityKind..id end,
        spawns=function(id) return Fixture.locations[entityKind][id] or {} end,
    }
    FixtureDB[kind=='npc' and 'Npc' or 'Object']=entity
end
FixtureDB.Item={
    Exists=function(id) return Fixture.items[id]~=nil end,
    name=function(id) return 'item'..id end,
    startQuest=function(id) return (Fixture.items[id] or {}).quest or 0 end,
}
for _,field in ipairs({'npcDrops','objectDrops','itemDrops','vendors'}) do
    FixtureDB.Item[field]=function(id) return (Fixture.items[id] or {})[field] or {} end
end
-- The association switch ships off; these scenarios exercise the feature itself, so every character record
-- the addon creates through QuestRouteDB.routes starts with it on (the fixture only pre-fills the save table;
-- production RouteOptions is untouched).
QuestRouteDB={routes=setmetatable({},{__index=function(routes,key)
    local settings={skipped={},moveThreshold=100,enabled=true,associationEnabled=true}
    rawset(routes,key,settings)
    return settings
end})}
'''

HELPERS = r'''
local ns=...
local checks=0
local function check(value,label)
    assert(value,'FAIL: '..label)
    checks=checks+1
end
local function has(values,value)
    for _,item in ipairs(values or {}) do if item==value then return true end end
    return false
end
local function action(actions,id,kind)
    for index,item in ipairs(actions or {}) do
        if item.questID==id and item.action==kind then return item,index end
    end
end
local function point(id,x,y,key)
    return {key=key or 'npc:'..id,objectiveKey=key or 'npc:'..id,
        world={continentID=1,x=x,y=y or 0},coordinateMapID=101,reportedMapID=101,
        x=x/10000,y=(y or 0)/10000,entityKind='npc',entityID=id,shareable=true}
end
local function model(id,active,x,key)
    return {questID=id,title='Quest '..id,active=active==true,
        status=active and 'in_progress' or 'not_accepted',eligibility='eligible',rewardWeight=1,
        targets={point(501,x or 1000,0,key)},targetsComplete=true,
        starters={point(10000+id,100)},finishers={point(20000+id,x or 1000)}}
end
local function evaluate(quests,baselineID,completed)
    local data={available=true,quests=quests,completed=completed or {},opportunities={}}
    local candidates={}
    for id,quest in pairs(quests) do
        if quest.active then candidates[#candidates+1]={quest=quest}
        else data.opportunities[#data.opportunities+1]={questID=id,action='pick_up'} end
    end
    local baseline
    if baselineID then
        local quest=quests[baselineID]
        local delivery=quest.status=='ready_for_turn_in'
        baseline={questID=baselineID,action=delivery and 'turn_in' or 'quest_area',
            point=delivery and quest.finishers[1] or quest.targets[1],
            objectiveKey=not delivery and quest.targets[1].key or nil}
    end
    return ns.Decision.Evaluate(data,candidates,point(1,0).world,baseline)
end
local function place(kind,id,x,y)
    Fixture.locations[kind][id]={[17]={{x/100,(y or 0)/100}}}
end
local function record(id,x,fields)
    local row={name='任务 '..id,questLevel=19,requiredLevel=1,
        startedBy={[1]={10000+id}},finishedBy={[1]={20000+id}},
        objectives={[1]={{501,nil,0}}},preQuestSingle={},preQuestGroup={},exclusiveTo={},childQuests={}}
    for key,value in pairs(fields or {}) do row[key]=value end
    Fixture.quests[id]=row
    place('npc',10000+id,x or 100); place('npc',20000+id,1000)
    if not Fixture.locations.npc[501] then place('npc',501,1000) end
    return row
end
local function candidates()
    local out={}
    for id,entry in pairs(ns.QuestData.ActiveQuestIndex()) do
        local quest=ns.QuestData.ReadQuest(entry.info,entry.category,false)
        quest.objectives=C_QuestLog.GetQuestObjectives(id); quest.objectivesLoaded=true
        local resolution=ns.Objectives.ReadLocations(FixtureDB,{version='fixture',contract=4},quest)
        out[#out+1]={quest=quest,points=resolution.points,resolution=resolution,priorityWeight=1}
    end
    return out
end
local function gossip(npcID, quests)
    Fixture.units.npc={id=npcID}; Fixture.offered=quests or {}
    ns.Discovery.ObserveInteraction('GOSSIP_SHOW')
end
local function finishIndex()
    for _=1,10000 do if ns.Discovery.Pump() then return end end
    error('fixture index failed to finish')
end
local function setupMaps()
    C_Map.GetMapPosFromWorldPos=function(_,p,id) return id,CreateVector2D(p.x/10000,p.y/10000) end
    WorldMapFrame=CreateFrame('Frame'); WorldMapFrame.canvas=CreateFrame('Frame')
    WorldMapFrame.canvas:SetSize(600,400)
    function WorldMapFrame:GetMapID() return Fixture.playerMapID or 101 end
    function WorldMapFrame:GetCanvas() return self.canvas end
    Minimap=CreateFrame('Frame'); Minimap:SetSize(200,200)
    C_Minimap={GetViewRadius=function() return 100 end,IsRotateMinimapIgnored=function() return false end}
    C_CVar={GetCVarBool=function() return false end}
    GameTooltip={lines={}}
    function GameTooltip:SetOwner() end
    function GameTooltip:SetText(text) self.lines={text} end
    function GameTooltip:AddLine(text) self.lines[#self.lines+1]=text end
    function GameTooltip:Show() end
    function GameTooltip:Hide() end
end
local function collect(items)
    local context,active=ns.GetPlayerContext({}),ns.QuestData.ActiveQuestIndex()
    local data=ns.Discovery.Collect(context,active,items or candidates(),ns.RouteOptions.Get())
    check(data.available,'fixture database is available')
    if data.building then finishIndex() end
    data=ns.Discovery.Collect(context,active,items or candidates(),ns.RouteOptions.Get())
    check(not data.building and data.scanned==data.total,'bounded local index build completes')
    return data
end
local function plan()
    ns.RouteOptions.Get().switchNotice=false
    local first=ns.Replan({})
    check(first.ok,'initial plan succeeds')
    if first.discovery.building then finishIndex() end
    local result=ns.Replan({})
    check(result.ok,'indexed plan succeeds')
    return result
end
-- assoc-switch scenarios call this to get the shipped default (off) instead of the fixture's pre-filled on.
local function useShippedAssociationDefault() QuestRouteDB.routes={} end
local function stepKeys(result)
    local out={}
    for _,step in ipairs(result.steps) do out[#out+1]=step.questID..':'..step.action end
    return table.concat(out,',')
end
local function visibleOpportunityPins()
    local views,count={},0
    for _,view in ipairs(ns.route.views or {}) do views[#views+1]=view end
    if ns.route.minimapView then views[#views+1]=ns.route.minimapView end
    for _,view in ipairs(views) do
        for _,pin in pairs(view.opportunities or {}) do if pin:IsVisible() then count=count+1 end end
    end
    return count
end
local function watchEmits()
    local seen,real={},ns.WB.Emit
    ns.WB.Emit=function(self,topic,...) seen[#seen+1]=topic; return real(self,topic,...) end
    return seen
end
local function countOf(list,value)
    local count=0
    for _,item in ipairs(list) do if item==value then count=count+1 end end
    return count
end
'''

CASES = (
    ("Decision: deliver prerequisite before collecting shared work", r'''
local a,b,c=model(101,true),model(201,true),model(301,false)
a.status='ready_for_turn_in'; a.targets={}; a.finishers={point(601,100)}
c.eligibility='blocked'; c.conditionReason='prerequisite'; c.preAll={101}
local result=evaluate({[101]=a,[201]=b,[301]=c},201)
check(result.recommendation and result.recommendation.questID==101
    and result.recommendation.action=='turn_in','deliver prerequisite first')
local _,delivery=action(result.predicted,101,'turn_in')
local _,pickup=action(result.predicted,301,'pick_up')
local _,work=action(result.predicted,201,'quest_area')
check(delivery and pickup and work and delivery<pickup and pickup<work,'delivery then pickup then shared work')
check(c.active==false and c.eligibility=='blocked' and a.status=='ready_for_turn_in','simulation leaves source state unchanged')
'''),
    ("Decision: profitable pickup precedes clearing the same monster", r'''
local a,b=model(201,true),model(301,false)
local result=evaluate({[201]=a,[301]=b},201)
check(result.recommendation and result.recommendation.action=='pick_up'
    and result.recommendation.questID==301,'collect before clearing')
check(result.baselineScore and result.bestScore-result.baselineScore>=80,'beats a separately searched baseline')
local workCount=0
for index,step in ipairs(result.predicted) do
    if step.action=='quest_area' then workCount=workCount+1; check(step.sharedGoalCount==2,'same key completes both accepted goals') end
    check(step.predicted and step.executable==(index==1),'all simulation is predicted and only first action is currently executable')
end
check(workCount==1,'same key pays work once')
check(not b.active and b.status=='not_accepted','predicted acceptance is not written back')
'''),
    ("Decision: distant pickup does not replace a better original route", r'''
local a,b=model(201,true),model(301,false)
b.starters={point(603,5000)}
local result=evaluate({[201]=a,[301]=b},201)
check(not result.recommendation and result.reason=='keep_current_route','unprofitable pickup keeps baseline')
check(result.baselineScore==result.bestScore,'baseline branch remains competitive')
'''),
    ("Decision: AND requires all delivered prerequisites, OR requires one", r'''
local a,b=model(201,true),model(301,false)
b.eligibility='blocked'; b.conditionReason='prerequisite'; b.preAll={401,402}
local all=evaluate({[201]=a,[301]=b},201,{[401]=true,[402]=false})
check(not action(all.predicted,301,'pick_up'),'one delivered prerequisite cannot satisfy AND')
b.preAll={}; b.preAny={401,402}
local any=evaluate({[201]=a,[301]=b},201,{[401]=true,[402]=false})
check(action(any.predicted,301,'pick_up'),'one delivered prerequisite satisfies OR')
b.preAny={401,402}
local none=evaluate({[201]=a,[301]=b},201,{[401]=false,[402]=false})
check(not action(none.predicted,301,'pick_up'),'no delivered prerequisite cannot satisfy OR')
b.preAll={403}
check(not action(evaluate({[201]=a,[301]=b},201,{[401]=true}).predicted,301,'pick_up'),
    'satisfied OR cannot bypass a missing AND prerequisite')
check(not action(evaluate({[201]=a,[301]=b},201,{[403]=true}).predicted,301,'pick_up'),
    'satisfied AND cannot bypass a missing OR prerequisite')
check(action(evaluate({[201]=a,[301]=b},201,{[401]=true,[403]=true}).predicted,301,'pick_up'),
    'combined AND and OR require both expressions')
'''),
    ("Decision: complete or accepted is not delivered", r'''
local a,b,c=model(101,true),model(201,true),model(301,false)
a.status='complete'; a.targets={}; a.finishers={point(601,0)}
c.eligibility='blocked'; c.conditionReason='prerequisite'; c.preAny={101}
local result=evaluate({[101]=a,[201]=b,[301]=c},201)
check(not action(result.predicted,101,'turn_in'),'complete without ready does not fabricate delivery')
check(not action(result.predicted,301,'pick_up'),'accepted or complete prerequisite does not unlock followup')
'''),
    ("Decision: different item keys on one NPC do not complete each other", r'''
local a,b=model(201,true),model(202,false,1000,'item:601')
local result=evaluate({[201]=a,[202]=b},201)
local _,first=action(result.predicted,201,'quest_area')
local _,second=action(result.predicted,202,'quest_area')
check(first and second,'both distinct goals still need work')
for _,id in ipairs({201,202}) do
    local _,work=action(result.predicted,id,'quest_area')
    local _,delivery=action(result.predicted,id,'turn_in')
    check(delivery and work<delivery,'partial same-NPC synergy cannot fabricate completed material')
end
'''),
    ("Decision: uncertain target coverage cannot unlock a followup", r'''
local a,b=model(201,true),model(301,false)
a.targetsComplete=false; a.targets[1].shareable=false
b.preAll={201}; b.eligibility='blocked'; b.conditionReason='prerequisite'
local result=evaluate({[201]=a,[301]=b},201)
check(action(result.predicted,201,'quest_area'),'known area remains usable')
check(not action(result.predicted,201,'turn_in') and not action(result.predicted,301,'pick_up'),
    'incomplete or special target coverage cannot simulate delivery')
'''),
    ("Decision: hard restrictions and exclusivity survive prediction", r'''
local a,b=model(201,true),model(301,false)
for _,reason in ipairs({'level_too_low','class_restricted','profession','conditions_unavailable'}) do
    b.eligibility=reason=='conditions_unavailable' and 'unknown' or 'blocked'; b.conditionReason=reason
    check(not action(evaluate({[201]=a,[301]=b},201).predicted,301,'pick_up'),'cannot bypass '..reason)
end
b.eligibility='eligible'; b.conditionReason=nil; b.exclusiveTo={201}
check(not action(evaluate({[201]=a,[301]=b},201).predicted,301,'pick_up'),'active exclusive quest blocks pickup')
b.exclusiveTo={401}
check(not action(evaluate({[201]=a,[301]=b},201,{[401]=true}).predicted,301,'pick_up'),
    'delivered exclusive quest blocks pickup')
local c=model(302,false)
b.exclusiveTo={302}; c.exclusiveTo={301}
local result=evaluate({[201]=a,[301]=b,[302]=c},201)
check(action(result.predicted,301,'pick_up') or action(result.predicted,302,'pick_up'),'one exclusive branch can be accepted')
check(not (action(result.predicted,301,'pick_up') and action(result.predicted,302,'pick_up')),
    'simulated acceptance cannot take both exclusive branches')
'''),
    ("Decision: unavailable data and unresolved baseline preserve fallback", r'''
local result=ns.Decision.Evaluate({available=false,reason='not_loaded'},{},point(1,0).world,nil)
check(not result.recommendation and #result.predicted==0 and result.reason=='not_loaded','missing data is explicit')
local a=model(201,true)
result=ns.Decision.Evaluate({available=true,quests={[201]=a},completed={},opportunities={}},
    {{quest=a}},point(1,0).world,{questID=999,action='quest_area',point=point(501,1000)})
check(not result.recommendation and result.reason=='baseline_target_unresolved','cannot replace an unresolved baseline')
'''),
    ("Decision: bounded first-action search always retains baseline", r'''
local quests={[201]=model(201,true)}
for id=301,314 do quests[id]=model(id,false); quests[id].starters={point(10000+id,id-300)} end
local result=evaluate(quests,201)
check(result.baselineScore~=nil and result.considered<=10,'baseline survives first-action cap')
check(#result.predicted<=6,'lookahead remains bounded')
'''),
    ("Discovery: incremental 64-quest index and no premature offers", r'''
for id=1001,1129 do record(id,100,{objectives={}}) end
local context=ns.GetPlayerContext({})
local function read() return ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get()) end
local data=read()
check(data.available and data.building and data.scanned==0 and data.total==129,'index starts without synchronous full scan')
check(#data.opportunities==0,'building index emits no premature opportunities')
ns.Discovery.Pump(); data=read()
check(data.building and data.scanned<=64 and #data.opportunities==0,'first pump respects task and inner work caps')
local first=data.scanned
ns.Discovery.Pump(); data=read()
check(data.building and data.scanned>=first and data.scanned-first<=64,'second pump remains bounded')
finishIndex(); data=read()
check(not data.building and data.scanned==129 and #data.opportunities==129,'final batch publishes complete offers')
'''),
    ("Discovery: nearby starters include the 400-yard boundary", r'''
record(301,400,{objectives={}}); record(302,401,{objectives={}})
local data=collect()
local offer=action(data.opportunities,301,'pick_up')
check(offer and offer.distance==400 and has(offer.reasons,'nearby'),'nearby boundary is included')
check(offer.certainty=='estimated','static starter does not claim observed availability')
check(not action(data.opportunities,302,'pick_up'),'outside nearby radius stays excluded without a destination')
'''),
    ("Discovery: on-way and destination starters catch missed pickups", r'''
record(201); Fixture.log={201}
record(301,600,{objectives={}}); record(302,1200,{objectives={}})
record(303,500,{objectives={}}); place('npc',10303,500,280)
record(304,500,{objectives={}}); place('npc',10304,500,300)
local data=collect()
local onWay=action(data.opportunities,301,'pick_up')
local destination=action(data.opportunities,302,'pick_up')
local detour=action(data.opportunities,303,'pick_up')
check(onWay and onWay.distance>400 and onWay.extraDistance==0 and has(onWay.reasons,'on_way'),'starter midway along route is found')
check(destination and has(destination.reasons,'same_area'),'destination 200-yard boundary is included')
check(detour and detour.extraDistance<=150 and has(detour.reasons,'on_way'),'short detour is admitted')
check(not action(data.opportunities,304,'pick_up'),'detour over 150 yards is excluded')
'''),
    ("Discovery: level class race profession and exclusive filters", r'''
record(201); Fixture.log={201}
record(301,100,{requiredLevel=20}); record(302,100,{requiredClasses=128})
record(303,100,{exclusiveTo={201}}); record(304,100,{requiredClasses=1})
record(305,100,{requiredMaxLevel=18}); record(306,100); Fixture.completed[306]=true
record(307,100,{requiredRaces=1}); record(308,100,{requiredSkill={356,1}})
local data=collect()
for id,reason in pairs({[301]='level_too_low',[302]='class_restricted',[303]='exclusive_quest',
    [305]='level_too_high',[306]='already_completed',[307]='race_restricted',[308]='profession'}) do
    check(data.quests[id] and data.quests[id].eligibility=='blocked'
        and data.quests[id].conditionReason==reason,'blocked with reason '..reason)
    check(not action(data.opportunities,id,'pick_up'),'filtered quest is never offered')
end
check(action(data.opportunities,304,'pick_up'),'matching player class remains eligible')
'''),
    ("Discovery: repeatable pickups are filtered without hiding accepted work or delivery", r'''
record(201,100,{specialFlags=1,repeatable=true}); record(202,100,{specialFlags=1,repeatable=true})
Fixture.log={201,202}; Fixture.status[202]='ready_for_turn_in'
record(301,100,{specialFlags=1,preQuestGroup={202}})
record(302,100,{specialFlags=3}); record(303,100,{specialFlags=2})
record(304,100,{specialFlags=0,repeatable=true}); record(305,100)
record(306,100,{specialFlags='1'}); record(307,100,{specialFlags=-1})
local native=C_QuestLog.IsRepeatableQuest
C_QuestLog.IsRepeatableQuest=function(id)
    if id==302 then error('fixture native flag unavailable') end
    return native(id)
end
local data=collect()
for _,id in ipairs({301,302,304}) do
    check(data.quests[id].eligibility=='blocked' and data.quests[id].conditionReason=='repeatable',
        'positive native or DB repeat flag blocks unaccepted quest '..id)
    check(not action(data.opportunities,id,'pick_up'),'repeatable quest has no pickup opportunity '..id)
end
for _,id in ipairs({303,305,306,307}) do
    check(action(data.opportunities,id,'pick_up'),'unrelated missing or invalid DB flags do not suppress ordinary quest '..id)
end
check(data.quests[201].eligibility=='eligible' and #data.quests[201].targets>0,'accepted repeatable work remains eligible')
check(data.quests[202].eligibility=='eligible' and #data.quests[202].finishers>0,'accepted repeatable delivery remains eligible')
local result=ns.Decision.Evaluate(data,candidates(),point(1,0).world,nil)
for _,step in ipairs(result.predicted) do
    check(step.questID~=301 and step.questID~=302 and step.questID~=304,'lookahead cannot revive repeatable pickups through prerequisites')
end
'''),
    ("Map pins: old repeatable announcements clear both pooled map markers", r'''
record(301,100,{specialFlags=1,objectives={}})
local result=plan(); setupMaps()
local old={questID=301,title='Old repeatable pickup',action='pick_up',point=point(10301,100),reasons={'nearby'}}
result.discovery.opportunities={old}
ns.WorldMap.Render(); ns.Minimap.Render()
local worldPin,miniPin=ns.route.views[1].opportunities[1],ns.route.minimapView.opportunities[1]
check(worldPin:IsVisible() and miniPin:IsVisible(),'fixture reproduces markers drawn before repeatable filtering')
ns.route.announcedOpportunities={mapID=101,items={['301:pick_up:0']=old}}
Fixture.playerX=.5
result=ns.Replan({}); ns.WorldMap.Render(); ns.Minimap.Render()
check(#result.discovery.opportunities==0 and #result.discovery.announcedOpportunities==0,'old repeatable pickup is removed outside the discovery radius')
check(not ns.route.announcedOpportunities.items['301:pick_up:0'],'repeatable announcement is retired from session history')
check(not worldPin:IsVisible() and not miniPin:IsVisible() and not worldPin.step and not miniPin.step,'both pooled markers hide and release the old quest')
check(not ns.RouteOptions.Get().skipped[301],'filtering never writes a manual skip')
'''),
    ("Discovery: unwanted pickup categories share one filter and preserve accepted quests", r'''
record(201,100,{name='Mirrorscale',questLevel=10,specialFlags=1,zoneOrSort=3358})
record(202,100,{zoneOrSort=-366}); Fixture.log={201,202}; Fixture.status[202]='ready_for_turn_in'
record(301,100,{pvp=true,preQuestGroup={202}}); record(302,100,{zoneOrSort=3277})
record(303,100,{zoneOrSort=-366}); record(304,100,{zoneOrSort=-22})
record(305,100,{name='捐献毛料',questLevel=60}); record(306,100,{name='Mirrorscale',questLevel=50})
record(307,100,{questLevel=14}); record(308,100,{name='NPC的委托',questLevel=15})
record(309,100,{questLevel=0}); record(310,100,{questLevel=-1})
record(311,100,{zoneOrSort=-367}); record(312,100,{zoneOrSort=-365})
C_QuestLog.GetQuestType=function(id) return Fixture.quests[id] and Fixture.quests[id].pvp and 41 or 0 end
local data=collect()
local blocked={[301]='battleground',[302]='battleground',[303]='holiday',[304]='holiday',
    [305]='donation',[306]='unlocalized',[307]='quest_below_minimum',[312]='holiday'}
for id,reason in pairs(blocked) do
    check(data.quests[id].conditionReason==reason and data.quests[id].eligibility=='blocked','shared category reason '..reason)
    check(not action(data.opportunities,id,'pick_up'),'filtered category cannot create a pickup '..id)
end
for _,id in ipairs({308,309,310,311}) do
    check(action(data.opportunities,id,'pick_up'),'Chinese mixed title, threshold boundary, unknown level or reputation stays eligible '..id)
end
check(data.quests[201].eligibility=='eligible' and #data.quests[201].targets>0,'accepted English low-level repeatable battleground work remains eligible')
check(data.quests[202].eligibility=='eligible' and #data.quests[202].finishers>0,'accepted holiday turn-in remains eligible')
local decision=ns.Decision.Evaluate(data,candidates(),point(1,0).world,nil)
for _,step in ipairs(decision.predicted) do check(not blocked[step.questID],'lookahead cannot unlock any filtered category') end
'''),
    ("Map pins: all filtered pickup categories retire remembered markers", r'''
record(301,100,{zoneOrSort=3358,objectives={}}); record(302,100,{zoneOrSort=-366,objectives={}})
record(303,100,{name='Mirrorscale',objectives={}}); record(304,100,{name='捐献毛料',objectives={}})
record(305,100,{questLevel=14,objectives={}}); record(306,100,{objectives={}})
local result=plan(); setupMaps(); local old={}
ns.route.announcedOpportunities={mapID=101,items={}}
for id=301,306 do
    local item={questID=id,title=Fixture.quests[id].name,action='pick_up',point=point(10000+id,100),reasons={'nearby'}}
    old[#old+1]=item; ns.route.announcedOpportunities.items[id..':pick_up:0']=item
end
result.discovery.opportunities=old; ns.WorldMap.Render(); ns.Minimap.Render()
Fixture.playerX=.5; result=ns.Replan({}); ns.WorldMap.Render(); ns.Minimap.Render()
check(#result.discovery.announcedOpportunities==1 and result.discovery.announcedOpportunities[1].questID==306,'only the ordinary remembered pickup survives outside the search radius')
for _,view in ipairs({ns.route.views[1],ns.route.minimapView}) do
    local shown=0
    for _,pin in ipairs(view.opportunities) do
        if pin:IsVisible() then shown=shown+1; check(pin.step.questID==306,'neither map retains a filtered quest') end
    end
    check(shown==1,'pooled map markers shrink to the one ordinary pickup')
end
for id=301,305 do check(not ns.route.announcedOpportunities.items[id..':pick_up:0'] and not ns.RouteOptions.Get().skipped[id],'retired history never writes a manual skip') end
'''),
    ("Pickup level: saved minimum validates atomically and changes recommendations immediately", r'''
record(301,100,{questLevel=14,objectives={}}); record(302,100,{questLevel=15,objectives={}})
record(303,100,{questLevel=60,objectives={}}); record(304,100,{questLevel=0,objectives={}})
local result=plan()
check(result.minPickupLevel==15 and not action(result.discovery.opportunities,301,'pick_up') and action(result.discovery.opportunities,302,'pick_up'),'default15 excludes only strictly lower known levels')
result=ns.SetRouteOptions({minPickupLevel=0})
check(result.minPickupLevel==0 and action(result.discovery.opportunities,301,'pick_up'),'zero turns off only the minimum-level filter')
result=ns.SetRouteOptions({minPickupLevel=60})
check(not action(result.discovery.opportunities,302,'pick_up') and action(result.discovery.opportunities,303,'pick_up') and action(result.discovery.opportunities,304,'pick_up'),'maximum60 keeps its boundary and unknown levels')
local before=ns.GetPlan({}); local enabled=ns.RouteOptions.Get().enabled
for _,value in ipairs({-1,61,1.5,'1',false,math.huge,0/0,{}}) do
    local rejected=ns.SetRouteOptions({minPickupLevel=value,enabled=not enabled,maxMonsterLevelOffset=0})
    check(not rejected.ok and ns.GetPlan({}).sequence==before.sequence and ns.RouteOptions.Get().minPickupLevel==60
        and ns.RouteOptions.Get().maxMonsterLevelOffset==2 and ns.RouteOptions.Get().enabled==enabled,'invalid minimum has no partial settings or plan changes')
end
local oldName=UnitName; UnitName=function() return 'OtherCharacter' end
check(ns.RouteOptions.Get().minPickupLevel==15,'minimum default belongs to each character')
ns.SetRouteOptions({minPickupLevel=20}); UnitName=oldName
check(ns.RouteOptions.Get().minPickupLevel==60,'other character does not change original minimum')
SlashCmdList.QUESTROUTE('minlevel 15')
check(ns.GetPlan({}).minPickupLevel==15 and action(ns.GetPlan({}).discovery.opportunities,302,'pick_up'),'slash command shares validation and immediate replan')
local settings=ns.RouteOptions.Get(); settings.minPickupLevel=nil
check(ns.RouteOptions.Get().minPickupLevel==15,'old saves receive a valid minimum')
settings.minPickupLevel='bad'; check(ns.RouteOptions.Get().minPickupLevel==15,'malformed saved minimum recovers')
'''),
    ("Discovery: AND OR and official delivery history", r'''
record(401,100,{objectives={}}); record(402,100,{objectives={}}); Fixture.log={401,402}
Fixture.status[401]='ready_for_turn_in'; Fixture.status[402]='complete'
record(301,100,{preQuestGroup={401,402}}); record(302,100,{preQuestSingle={401,402}})
local data=collect()
check(data.completed[401]==false and data.completed[402]==false,'ready and complete do not become delivery history')
check(not action(data.opportunities,301,'pick_up') and not action(data.opportunities,302,'pick_up'),'neither prerequisite expression is satisfied')
Fixture.completed[401]=true; Fixture.log={402}; data=collect()
check(not action(data.opportunities,301,'pick_up'),'AND still needs the second delivery')
check(action(data.opportunities,302,'pick_up'),'OR accepts one official historical delivery')
Fixture.completed[402]=true; Fixture.log={}; data=collect()
check(action(data.opportunities,301,'pick_up'),'AND accepts both historical deliveries')
'''),
    ("Discovery: unknown completion and malformed conditions do not offer pickups", r'''
record(301,100,{preQuestGroup={401}}); Fixture.historyUnknown[401]=true
record(302,100,{requiredLevel='nineteen'})
local data=collect()
for _,id in ipairs({301,302}) do
    check(data.quests[id].eligibility=='unknown','uncertain condition remains unknown')
    check(not action(data.opportunities,id,'pick_up'),'uncertain condition cannot become an executable offer')
end
'''),
    ("Discovery: bag item is executable, an unheld drop is only a relation", r'''
record(301,100,{startedBy={[3]={601}}})
Fixture.items[601]={quest=301,npcDrops={502}}; place('npc',502,200)
Fixture.items[602]={quest=0}; Fixture.bags={602}
local data=collect()
local drop=action(data.opportunities,301,'possible_item_drop')
check(drop and drop.itemID==601 and drop.certainty=='possible','unheld item records a possible source')
check(not data.quests[301].startItemID and not action(data.opportunities,301,'start_item'),'drop relation cannot claim inventory ownership')
local result=ns.Decision.Evaluate(data,{},point(1,0).world,nil)
check(not action(result.predicted,301,'start_item'),'unheld starting item cannot execute')
Fixture.bags={601,602}; data=collect()
local start=action(data.opportunities,301,'start_item')
check(start and start.itemID==601 and start.certainty=='confirmed','held bag item creates a confirmed start')
check(data.quests[301].startItemID==601,'Decision model carries actual held item ID')
check(not action(data.opportunities,301,'possible_item_drop'),'held item no longer needs a speculative drop')
check(data.quests[0]==nil,'Item.startQuest zero does not create quest zero')
result=ns.Decision.Evaluate(data,{},point(1,0).world,nil)
check(result.recommendation and result.recommendation.action=='start_item'
    and result.recommendation.itemID==601,'held item is executable by Decision')
'''),
    ("Discovery: simple shared targets retain completion and identity", r'''
record(201); record(301); Fixture.log={201}
local items=candidates(); local data=collect(items)
for _,id in ipairs({201,301}) do
    local quest=data.quests[id]
    check(quest.targetsComplete==true,'fully resolved ordinary goals allow simulated delivery')
    check(#quest.targets==1 and quest.targets[1].key=='npc:501' and quest.targets[1].shareable,
        'active and unaccepted ordinary goals preserve the same shareable identity')
end
local result=ns.Decision.Evaluate(data,items,point(1,0).world,
    {questID=201,action='quest_area',objectiveKey='npc:501',point=point(501,1000)})
local workCount=0
for _,step in ipairs(result.predicted) do if step.action=='quest_area' then workCount=workCount+1 end end
check(result.recommendation and result.recommendation.action=='pick_up' and workCount==1,
    'real Discovery data lets Decision share work after pickup')
'''),
    ("Discovery: special objectives never become ordinary shared kills", r'''
record(301,100,{objectives={[1]={{501,nil,1}}}})
record(302,100,{objectives={[1]={{501,nil,0}},[4]={{72,100}}}})
record(303,100,{objectives={[1]={{501,nil,0}},[5]={{{501},501}}}})
record(304,100,{objectives={[1]={{501,nil,0}},[6]={{501,123}}}})
record(305,100,{extraObjectives={{nil,nil,nil,nil,{{'monster',501}}}}})
local data=collect()
for id=301,305 do
    local quest=data.quests[id]
    check(quest and quest.targetsComplete~=true,'special objective cannot certify full simulated completion')
    for _,target in ipairs(quest.targets) do check(not target.shareable,'special relation is not an ordinary shared kill') end
end
'''),
    ("Discovery to Decision: delivered prerequisite unlocks a shared followup", r'''
record(101,100,{objectives={}}); Fixture.status[101]='ready_for_turn_in'
place('npc',20101,100)
record(201); record(301,100,{preQuestGroup={101}}); Fixture.log={101,201}
local items=candidates(); local data=collect(items)
local first=point(501,1000)
local result=ns.Decision.Evaluate(data,items,point(1,0).world,
    {questID=201,action='quest_area',objectiveKey='npc:501',point=first})
local _,delivery=action(result.predicted,101,'turn_in')
local _,pickup=action(result.predicted,301,'pick_up')
check(result.recommendation and result.recommendation.action=='turn_in'
    and delivery and pickup and delivery<pickup,'Discovery prerequisite state is searchable after simulated delivery')
check(data.completed[101]==false,'predicted delivery never changes official history')
'''),
    ("Planner: pickup navigation and predicted work stay separate", r'''
record(201); record(301,100); Fixture.log={201}
local result=plan()
check(result.decision.applied and result.steps[1].questID==301 and result.steps[1].action=='pick_up','related pickup is first formal step')
check(result.pickupCount==1 and result.activeQuestCount==1 and result.questCount==2 and result.count==2,'plan distinguishes active quests and pickup count')
check(result.navigation.phase=='pick_up' and not result.navigation.protected,'pickup navigation never enters working')
local forecast=false
for _,step in ipairs(result.decision.predicted) do
    for _,goal in ipairs(step.contributions or {}) do if goal.questID==301 then forecast=true end end
end
check(forecast,'unaccepted work is represented in predicted shared contributions')
check(not action(result.steps,301,'quest_area') and action(result.steps,201,'quest_area'),'only active work enters formal steps')
check(ns.GetPlan({})==result and result.discovery.available,'existing get_plan exposes discovery and decision')
Fixture.playerX=.01; Fixture.time=1
result=ns.Planner.Rebuild('moved')
check(result.navigation.phase=='pick_up' and not result.navigation.protected,'arrival at starter still awaits actual acceptance')
Fixture.log={201,301}; result=ns.Replan({})
check(not action(result.steps,301,'pick_up') and action(result.steps,301,'quest_area'),'actual acceptance promotes work into formal steps')
check(result.activeQuestCount==2 and result.pickupCount==0,'counts follow official log acceptance')
'''),
    ("Planner: held starting item uses start_item navigation", r'''
record(201); record(301,100,{startedBy={[3]={601}}}); Fixture.log={201}
Fixture.items[601]={quest=301}; Fixture.bags={601}
local result=plan()
check(result.decision.applied and result.steps[1].action=='start_item'
    and result.steps[1].questID==301 and result.steps[1].itemID==601,'Planner applies a held starting item')
check(result.navigation.phase=='start_item' and not result.navigation.protected,'item start awaits actual acceptance at player position')
check(result.pickupCount==1 and not action(result.steps,301,'quest_area'),'item pickup never adds predicted work to formal route')
'''),
    ("Planner: protected working target defers a real recommendation", r'''
record(201); record(301,50); place('npc',501,100); Fixture.log={201}
ns.RouteOptions.Get().switchNotice=false
local original=ns.Replan({})
check(original.navigation.phase=='working' and original.navigation.protected,'work is protected before index becomes ready')
if original.discovery.building then finishIndex() end
local result=ns.Planner.Rebuild('quest_update')
check(result.decision.recommendation~=nil,'fixture supplies a profitable competing pickup')
check(result.navigation.phase=='working' and result.navigation.protected,'active nearby work remains protected')
check(not result.decision.applied and result.decision.deferred=='working_target_protected','association explicitly defers to work protection')
check(result.steps[1].questID==201 and result.pickupCount==0,'protected work is not overwritten')
'''),
    ("Planner: manual spot change defers a real recommendation", r'''
record(201); record(301,100); Fixture.log={201}; ns.RouteOptions.Get().skipped[301]=true
Fixture.locations.npc[501]={[17]={{10,0},{40,0}}}
local original=plan()
check(original.steps[1].questID==201 and original.steps[1].world.x==1000,'initial exact objective uses nearer hotspot')
ns.RouteOptions.Get().skipped[301]=nil
local changed=ns.ChangeQuestSpot({questID=201,objectiveKey='npc:501'})
check(changed.ok and changed.selected.questID==201 and changed.selected.world.x==4000,'manual change commits the other hotspot')
local result=ns.GetPlan({})
check(result.decision.recommendation~=nil,'fixture still offers a competing association')
check(not result.decision.applied and result.decision.deferred=='manual_spot_change','association explicitly defers to manual selection')
check(result.steps[1].world.x==4000 and not ns.route.pendingSpotChange,'manual result survives route rebuild and request is consumed')
'''),
    ("Planner: missing database preserves native route", r'''
record(201); Fixture.log={201}; Fixture.pois={[101]={NewPOI(101,.1,201)}}
local original=plan(); LibQuestieDB=nil
local result=ns.Replan({})
check(result.ok and result.count==1 and result.steps[1].questID==original.steps[1].questID
    and result.steps[1].world.x==original.steps[1].world.x,'native POI keeps the original quest and destination usable')
check(not result.discovery.available and not result.decision.recommendation,'missing database disables association only')
check(result.steps[1].targetMode=='native_poi','fallback actually uses native data')
'''),
    ("Planner: unready or missing ID index preserves native route and recovers", r'''
record(201); Fixture.log={201}; Fixture.pois={[101]={NewPOI(101,.1,201)}}
local getter=FixtureDB.Quest.GetAllIds
FixtureDB.Quest.GetAllIds=function() return nil end
local result=ns.Replan({})
check(result.ok and result.count==1 and not result.discovery.available
    and result.discovery.reason=='id_index_not_ready','unready IDs preserve active route')
FixtureDB.Quest.GetAllIds=nil; result=ns.Replan({})
check(result.ok and result.count==1 and result.discovery.reason=='id_index_unavailable','missing ID method is isolated')
FixtureDB.Quest.GetAllIds=getter; result=plan()
check(result.discovery.available and not result.discovery.building and result.count==1,'late-ready ID index recovers')
'''),
    ("Discovery: material identity survives NPC source expansion", r'''
record(201,100,{objectives={[3]={{601,nil,0}}}})
record(301,100,{objectives={[3]={{602,nil,0}}}}); Fixture.log={201}
Fixture.items[601]={npcDrops={501}}; Fixture.items[602]={npcDrops={501}}
local data=collect()
check(data.quests[201].targets[1].key=='item:601' and data.quests[301].targets[1].key=='item:602',
    'different materials retain distinct goal identities on one NPC')
check(data.quests[201].targets[1].entityID==501 and data.quests[301].targets[1].entityID==501,
    'source entity remains available for partial synergy')
check(data.quests[201].targetsComplete and data.quests[301].targetsComplete,'ordinary material coverage is complete')
'''),
    ("Discovery: foreign unfinished goals prevent simulated delivery", r'''
FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
record(201,100,{objectives={[1]={{501,nil,0},{502,nil,0}}}})
record(301,100,{objectives={[1]={{501,nil,0},{502,nil,0}}}}); Fixture.log={201}
Fixture.locations.npc[502]={[18]={{10,0}}}
local data=collect()
check(not data.quests[201].targetsComplete and not data.quests[301].targetsComplete,
    'one local goal cannot hide another unfinished goal on a different map')
check(#data.quests[201].targets==1 and #data.quests[301].targets==1,'search stays on the current map')
'''),
    ("Discovery: ready delivery uses the actual native point", r'''
record(201); Fixture.log={201}; Fixture.status[201]='ready_for_turn_in'
local entry=ns.QuestData.ActiveQuestIndex()[201]
local quest=ns.QuestData.ReadQuest(entry.info,entry.category,false)
local actual=point(501,2300)
local data=collect({{quest=quest,points={actual},priorityWeight=1}})
check(#data.quests[201].targets==0,'ready quest never adds work targets')
check(data.quests[201].finishers[1].world.x==2300,'delivery simulation matches the native baseline point')
'''),
    ("Planner: uncached quest metadata waits and candidate events recover", r'''
record(201); record(301,100); Fixture.log={201}
local loaded,requests=false,0
HaveQuestData=function(id) return id~=301 or loaded end
C_QuestLog.RequestLoadQuestByID=function(id) if id==301 then requests=requests+1 end end
C_QuestLog.GetQuestType=function(id) return id==301 and loaded and 81 or 0 end
local result=plan()
check(requests==1 and result.discovery.pendingCount==1,'uncached candidate is requested once')
check(not action(result.discovery.opportunities,301,'pick_up') and result.pickupCount==0,
    'uncached ordinary default cannot create a pickup')
Fixture.loggedIn=true; ns.StartRoute()
local sequence=ns.GetPlan({}).sequence
loaded=true
ns.route.driver:GetScript('OnEvent')(ns.route.driver,'QUEST_DATA_LOAD_RESULT',301,true)
Fixture.time=1; ns.route.driver:GetScript('OnUpdate')(ns.route.driver,.2)
result=ns.GetPlan({})
check(result.sequence>sequence and result.discovery.pendingCount==0,'candidate metadata event replans and stops retry')
local excluded=false
for _,item in ipairs(result.discovery.blocked) do if item.questID==301 and item.reason=='instance' then excluded=true end end
check(excluded and result.pickupCount==0,'loaded dungeon classification is filtered')
'''),
    ("Decision: no unlock opportunity does not run a search", r'''
local quests={[201]=model(201,true)}
for id=202,220 do quests[id]=model(id,true,id*10,'npc:'..id) end
local result=evaluate(quests,201)
check(result.considered==0 and not result.recommendation,'active-only route does not waste beam expansion')
check(result.predicted[1].questID==201,'current executable action remains visible')
'''),
    ("Discovery: index pump respects the per-frame work budget", r'''
for id=301,430 do record(id,100) end
local data=ns.Discovery.Collect(ns.GetPlayerContext({}),{}, {},ns.RouteOptions.Get())
local clock=0
debugprofilestop=function() clock=clock+2; return clock end
ns.Discovery.Pump()
data=ns.Discovery.Collect(ns.GetPlayerContext({}),{}, {},ns.RouteOptions.Get())
check(data.building and data.scanned<64,'time budget yields before the fixed task cap')
debugprofilestop=nil
finishIndex()
check(not ns.Discovery.Collect(ns.GetPlayerContext({}),{}, {},ns.RouteOptions.Get()).building,'yielded build resumes without losing records')
'''),
    ("Discovery: log membership and breadcrumb constraints stay authoritative", r'''
record(301,100); record(302,100,{breadcrumbForQuestId=401})
C_QuestLog.IsOnQuest=function(id) return id==301 end
Fixture.completed[401]=true
local data=collect()
check(data.quests[301].conditionReason=='already_accepted','incomplete enumeration cannot recommend an already accepted quest')
check(data.quests[302].eligibility=='blocked','completed breadcrumb destination suppresses its breadcrumb')
C_QuestLog.IsOnQuest=function() return nil end; data=collect()
check(data.quests[301].eligibility=='unknown' and not action(data.opportunities,301,'pick_up'),'unknown membership is not treated as unaccepted')
'''),
    ("Discovery and Decision: one-sided exclusivity still blocks both orders", r'''
record(301,100,{exclusiveTo={302}}); record(302,100); Fixture.completed[301]=true
local data=collect()
check(data.quests[302].eligibility=='blocked' and data.quests[302].conditionReason=='exclusive_quest',
    'reverse exclusive relation respects delivered history')
local a,b,c=model(201,true),model(301,false),model(302,false)
b.exclusiveTo={302}
local result=evaluate({[201]=a,[301]=b,[302]=c},201)
check(not (action(result.predicted,301,'pick_up') and action(result.predicted,302,'pick_up')),
    'one-sided exclusive relation cannot be bypassed by changing order')
'''),
    ("Decision: partial delivery preserves an active parent", r'''
local a,b,c=model(101,true),model(201,true),model(301,false)
a.status='ready_for_turn_in'; a.targets={}; a.finishers={point(601,1100)}
c.preAll={101}; c.parentQuest=201; c.eligibility='blocked'; c.conditionReason='prerequisite'
c.starters={point(603,1000)}
local result=evaluate({[101]=a,[201]=b,[301]=c},201)
check(result.considered>0 and result.recommendation and result.recommendation.questID==101,
    'search keeps legal plan that delivers prerequisite but keeps parent active')
local _,delivery=action(result.predicted,101,'turn_in')
local _,pickup=action(result.predicted,301,'pick_up')
local _,parentDelivery=action(result.predicted,201,'turn_in')
check(delivery and pickup and delivery<pickup and (not parentDelivery or pickup<parentDelivery),
    'parent visibility is checked in each branch instead of a hypothetical all-delivered state')
'''),
    ("Planner: small motion does not flip a valid pickup", r'''
record(201); record(301); record(302); Fixture.log={201}
place('npc',10301,100,90); place('npc',10302,100,110)
Fixture.playerY=.0099
local first=plan()
check(first.steps[1].action=='pick_up','fixture selected a pickup')
local selected=first.steps[1].questID
Fixture.playerY=.0101
local nextPlan=ns.Planner.Rebuild('BAG_UPDATE_DELAYED')
check(nextPlan.steps[1].questID==selected and nextPlan.steps[1].action=='pick_up',
    'two-yard change cannot replace an equally valuable pickup')
check(nextPlan.decision.retainedPickup and nextPlan.decision.baselineScore,
    'pickup is evaluated as its own stable baseline')
Fixture.completed[selected]=true
nextPlan=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(nextPlan.steps[1].questID~=selected,'invalidated pickup is immediately released')
'''),
    ("Discovery: one large spawn list can yield and resume", r'''
record(301,100,{objectives={}})
local points={}
for i=1,10000 do points[i]={i/200,0} end
Fixture.locations.npc[10301]={[17]=points}
local converted=0
local convert=C_Map.GetWorldPosFromMapPos
C_Map.GetWorldPosFromMapPos=function(...) converted=converted+1; return convert(...) end
local context=ns.GetPlayerContext({})
ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
converted=0
ns.Discovery.Pump()
check(converted>0 and converted<=128,'single record yields inside its coordinate conversion loop')
finishIndex()
local result=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(not result.building and result.quests[301] and #result.quests[301].starters==10000,
    'resuming the single-record cursor preserves every location')
'''),
    ("Planner: large discovery summaries remain bounded", r'''
for id=1001,1750 do record(id,100,{objectives={}}) end
local result=plan()
check(result.discovery.opportunityTotal==750 and #result.discovery.opportunities<=26,
    'public summary keeps totals without returning the entire opportunity index')
check(result.discovery.summaryLimit==25,'public summary publishes its limit')
check(result.count==0,'unknown goal benefit does not invent a forced pickup route')
'''),
    ("Map pins: pickups use exclamation labels and compact status", r'''
record(201); record(301,100); Fixture.log={201}
local result=plan()
local pin=ns.MapPins.New({overlay=CreateFrame('Frame')})
pin.step=result.steps[1]
ns.MapPins.Appearance(pin,pin.step,1)
check(pin.text.text=='1~!','unconfirmed pickup has a provisional exclamation label')
GameTooltip={lines={}}
function GameTooltip:SetOwner() end
function GameTooltip:SetText(text) self.lines={text} end
function GameTooltip:AddLine(text) self.lines[#self.lines+1]=text end
function GameTooltip:Show() end
function GameTooltip:Hide() end
pin:GetScript('OnEnter')(pin)
check(#GameTooltip.lines<=4 and GameTooltip.lines[3]:find('接取待确认',1,true),
    'pickup hover preserves the compact unconfirmed status')
check(GameTooltip.lines[2]:find('NPC：npc10301',1,true) and GameTooltip.lines[2]:find('1.0, 0.0',1,true),
    'formal pickup identifies the giver and coordinates')
check(GameTooltip.lines[3]:find('静态接取位置',1,true),'pickup does not claim a monster work area')
gossip(10301,{{questID=301}})
result=ns.Replan({}); pin.step=result.steps[1]
check(pin.step.questID==301 and pin.step.world.x==0 and pin.step.source=='client'
    and pin.step.precision=='interaction_position','formal pickup preserves the observed interaction point and provenance')
pin:GetScript('OnEnter')(pin)
check(#GameTooltip.lines<=4 and GameTooltip.lines[3]:find('当前接取位置',1,true),
    'official starter hover does not claim a static location')
'''),
    ("Map pins: unselected pickup remains locatable without an active route", r'''
record(301,300,{objectives={}})
local result=plan(); setupMaps()
check(result.count==0 and action(result.discovery.opportunities,301,'pick_up'),'nearby pickup is advisory without invented work')
ns.WorldMap.Render(); ns.Minimap.Render()
local mapView,miniView=ns.route.views[1],ns.route.minimapView
local worldPin,miniPin=mapView.opportunities[1],miniView.opportunities[1]
check(worldPin:IsVisible() and miniPin:IsVisible() and worldPin.text.text=='~!' and miniPin.text.text=='~!',
    'unselected static pickup has provisional markers on both maps with zero steps')
check(miniPin.onEdge,'pickup outside the minimap radius keeps a direction marker')
worldPin:GetScript('OnEnter')(worldPin)
check(#GameTooltip.lines<=4 and GameTooltip.lines[2]:find('Map 101 3.0, 0.0',1,true)
    and GameTooltip.lines[2]:find('NPC',1,true),'hover gives map coordinates and giver type within four lines')
check(GameTooltip.lines[3]:find('就在附近',1,true) and GameTooltip.lines[3]:find('接取待确认',1,true),
    'advisory hover explains discovery without claiming confirmed acceptance')
local notices={}; ns.Util.Notify=function(text) notices[#notices+1]=text end
ns.RouteOptions.Get().switchNotice=true; result.reason='player_moved'
ns.Decision.Notify(result,nil,ns.RouteOptions.Get(),30)
check(#notices==1 and notices[1]:find('就在附近',1,true) and notices[1]:find('Map 101 3.0, 0.0',1,true),
    'one-line hint includes its reason and coordinates')
check(not notices[1]:find('建议先接',1,true),'advisory cannot claim it won first-step priority')
Fixture.time=100; ns.Planner.Rebuild('BAG_UPDATE_DELAYED'); ns.WorldMap.Render(); ns.Minimap.Render()
check(worldPin:IsVisible() and miniPin:IsVisible() and #notices==1,'markers survive toast expiration and unrelated rebuild without repeating the hint')
local printed={}; local realPrint=print; print=function(text) printed[#printed+1]=text end
SlashCmdList.QUESTROUTE('why'); print=realPrint
check(table.concat(printed,'\n'):find('Map 101 3.0, 0.0',1,true),'why retains a queryable pickup location')
Fixture.shift=true; worldPin:GetScript('OnClick')(worldPin); Fixture.shift=false
check(not ns.RouteOptions.Get().skipped[301],'unadvertised Shift click cannot change or skip an advisory')
worldPin:GetScript('OnClick')(worldPin); ns.WorldMap.Render(); ns.Minimap.Render()
check(ns.RouteOptions.Get().skipped[301] and not worldPin:IsVisible() and not miniPin:IsVisible(),
    'existing right-click skip clears both advisory markers')
ns.SetQuestSkip({questID=301,skipped=false}); ns.WorldMap.Render(); ns.Minimap.Render()
check(worldPin:IsVisible() and miniPin:IsVisible(),'restoring the task reuses pooled markers')
ns.OnUnload()
check(not worldPin:IsVisible() and not miniPin:IsVisible() and not worldPin.step and not miniPin.step,'unload clears every advisory target')
Fixture.loggedIn=true; ns.StartRoute()
check(ns.route.views[1].opportunities[1]==worldPin and ns.route.minimapView.opportunities[1]==miniPin
    and worldPin:IsVisible() and miniPin:IsVisible(),'startup reuses advisory pools and callbacks')
ns.SetRouteOptions({enabled=false}); ns.WorldMap.Render(); ns.Minimap.Render()
check(not worldPin:IsVisible() and not miniPin:IsVisible(),'global display switch hides advisory markers')
ns.SetRouteOptions({enabled=true}); Fixture.log={301}
ns.Planner.Rebuild('QUEST_LOG_UPDATE'); ns.WorldMap.Render(); ns.Minimap.Render()
check(not worldPin:IsVisible() and not miniPin:IsVisible() and not worldPin.step and not miniPin.step,
    'actual acceptance removes the unaccepted marker')
'''),
    ("Map pins: announced pickup survives leaving the discovery radius without changing the route", r'''
record(301,100,{objectives={}}); record(302,200,{objectives={}})
local result=plan(); setupMaps()
local notices={}; ns.Util.Notify=function(text) notices[#notices+1]=text end
ns.RouteOptions.Get().switchNotice=true; result.reason='player_moved'
ns.Decision.Notify(result,nil,ns.RouteOptions.Get(),30)
check(#notices==1 and ns.route.announcedOpportunities.items['301:pick_up:0'],
    'only a displayed toast remembers its actionable location')
Fixture.playerX=.5; Fixture.time=100
result=ns.Planner.Rebuild('player_moved'); ns.WorldMap.Render(); ns.Minimap.Render()
check(#result.discovery.opportunities==0 and #result.discovery.announcedOpportunities==1,
    'leaving the radius retains the advertised pickup separately from live candidates')
check(result.discovery.announcedOpportunities[1].questID==301 and result.count==0
    and result.decision.considered==0 and not result.decision.applied,
    'unannounced nearby tasks are not retained and display history cannot start a route search')
local worldPin,miniPin=ns.route.views[1].opportunities[1],ns.route.minimapView.opportunities[1]
check(worldPin:IsVisible() and miniPin:IsVisible() and miniPin.onEdge and miniPin.step.questID==301,
    'both maps keep the original pickup after moving far away')
worldPin:GetScript('OnEnter')(worldPin)
check(#GameTooltip.lines<=4 and GameTooltip.lines[3]:find('先前提示的地点',1,true)
    and not GameTooltip.lines[3]:find('就在附近',1,true),'retained location cannot claim it is still nearby')
local printed={}; local realPrint=print; print=function(text) printed[#printed+1]=text end
SlashCmdList.QUESTROUTE('why'); print=realPrint
check(table.concat(printed,'\n'):find('先前提示的地点',1,true),'why retains the same location and historical reason')
Fixture.playerX=0; Fixture.time=110; result=ns.Planner.Rebuild('player_moved'); ns.WorldMap.Render(); ns.Minimap.Render()
check(#result.discovery.announcedOpportunities==0 and action(result.discovery.opportunities,301,'pick_up'),
    'returning near the giver uses its current opportunity rather than a duplicate remembered point')
local shown=0
for _,pin in ipairs(ns.route.minimapView.opportunities) do if pin:IsVisible() and pin.step.questID==301 then shown=shown+1 end end
check(shown==1 and #notices==1,'fresh and remembered versions never duplicate markers or repeat the toast')
Fixture.playerX=.5; result=ns.Planner.Rebuild('player_moved')
ns.OnUnload(); Fixture.loggedIn=true; ns.StartRoute()
check(#ns.GetPlan({}).discovery.announcedOpportunities==1,'same-map UI restart retains a validated remembered point')
ns.SetQuestSkip({questID=301}); ns.WorldMap.Render(); ns.Minimap.Render()
check(#ns.GetPlan({}).discovery.announcedOpportunities==0 and not worldPin:IsVisible() and not miniPin:IsVisible(),
    'skipping removes the retained location from both maps')
ns.SetQuestSkip({questID=301,skipped=false})
check(#ns.GetPlan({}).discovery.announcedOpportunities==0,'restoring a far-away task cannot revive a discarded announcement')
'''),
    ("Discovery: retained announcements revalidate unknown metadata and official acceptance", r'''
record(301,100,{objectives={}})
local result=plan(); ns.RouteOptions.Get().switchNotice=true; result.reason='player_moved'
ns.Util.Notify=function() end
ns.Decision.Notify(result,nil,ns.RouteOptions.Get(),30)
Fixture.playerX=.5; Fixture.time=100
local haveData=HaveQuestData; HaveQuestData=function(id) return id~=301 end
result=ns.Planner.Rebuild('QUEST_DATA_LOAD_RESULT')
check(#result.discovery.announcedOpportunities==0 and result.discovery.pendingCount==1,
    'temporarily unknown eligibility hides a remembered point and requests metadata')
check(ns.route.announcedOpportunities.items['301:pick_up:0'],
    'temporary metadata loss preserves the announcement for recovery')
HaveQuestData=haveData; result=ns.Planner.Rebuild('QUEST_DATA_LOAD_RESULT')
check(#result.discovery.announcedOpportunities==1,'eligibility recovery restores the point outside the search radius')
Fixture.log={301}; result=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(#result.discovery.announcedOpportunities==0 and not ns.route.announcedOpportunities.items['301:pick_up:0'],
    'official acceptance removes historical pickup guidance')
'''),
    ("Discovery: retained announcements clear after collection, completion and a real map change", r'''
record(301,100,{startedBy={[3]={601}},objectives={}})
Fixture.items[601]={quest=301,objectDrops={701}}; place('object',701,100)
local result=plan(); ns.RouteOptions.Get().switchNotice=true; result.reason='player_moved'
ns.Util.Notify=function() end
ns.Decision.Notify(result,nil,ns.RouteOptions.Get(),30)
Fixture.playerX=.5; Fixture.time=100; result=ns.Planner.Rebuild('player_moved')
check(action(result.discovery.announcedOpportunities,301,'possible_item_drop'),
    'uncollected item source also survives leaving its radius')
Fixture.bags={601}; result=ns.Planner.Rebuild('BAG_UPDATE_DELAYED')
check(#result.discovery.announcedOpportunities==0 and not ns.route.announcedOpportunities.items['301:possible_item_drop:601'],
    'actual item possession invalidates the remembered collection point')
Fixture.bags={}; Fixture.playerX=0; result=ns.Replan({}); result.reason='player_moved'
ns.route.associationNotice=nil; ns.route.lastNotice=nil; ns.Decision.Notify(result,nil,ns.RouteOptions.Get(),200)
Fixture.playerX=.5; Fixture.completed[301]=true; result=ns.Planner.Rebuild('QUEST_TURNED_IN')
check(#result.discovery.announcedOpportunities==0 and not ns.route.announcedOpportunities.items['301:possible_item_drop:601'],
    'completed history removes a remembered source')
Fixture.completed[301]=false; Fixture.playerX=0; result=ns.Replan({}); result.reason='player_moved'
ns.route.associationNotice=nil; ns.route.lastNotice=nil; ns.Decision.Notify(result,nil,ns.RouteOptions.Get(),300)
Fixture.playerX=.5; Fixture.playerMapID=102; ns.Planner.Rebuild('player_map_changed')
check(not ns.route.announcedOpportunities,'a confirmed map change clears the map-scoped announcement history')
Fixture.playerMapID=101; result=ns.Replan({}); if result.discovery.building then finishIndex() end
result=ns.Replan({})
check(#result.discovery.announcedOpportunities==0,'returning far away does not resurrect previous-map-session markers')
'''),
    ("Hints: reasons and source types describe an opportunity without inventing priority", r'''
local p=point(701,7440,8570); p.entityKind='object'; p.entityName='Scrolls'
local item={questID=301,title='Book',itemName='Book',action='possible_item_drop',questItem=true,
    point=p,reasons={'nearby'}}
local text=ns.Decision.Describe(item,false)
check(text:find('顺路取物',1,true) and text:find('就在附近',1,true) and text:find('74.4, 85.7',1,true)
    and text:find('物件：Scrolls',1,true),'book source is pickup of an object with reason, coordinates and entity name')
check(not text:find('启动',1,true) and not text:find('可接',1,true),'objective book cannot be advertised as a quest starter')
item.action='pick_up'; item.itemName=nil; item.questItem=nil; item.reasons={'same_target','nearby'}
text=ns.Decision.Describe(item,true)
check(text:find('建议先确认接取',1,true) and text:find('可合做目标',1,true),'unconfirmed pickup gives its shared-work reason without claiming availability')
item.certainty='confirmed'
check(ns.Decision.Describe(item,true):find('建议先接',1,true),'observed offer can recommend acceptance')
item.action=nil; item.point=point(702,7340,3300); item.point.coordinateMapID=102
item.point.entityName='Librarian'; item.reasons={'item_in_bags'}
text=ns.Decision.Describe(item,false)
check(text:find('已取得',1,true) and text:find('确认接取/交付',1,true) and text:find('NPC：Librarian',1,true)
    and text:find('Map 102 73.4, 33.0',1,true),'carried item points to its actual NPC without asserting quest acceptance')
item.itemName={}
check(ns.Decision.Describe(item,false):find('Book',1,true),'malformed optional item name falls back to the validated quest title')
check(ns.Util.FormatLocation(nil)==nil and ns.Util.FormatLocation({coordinateMapID=101,x=-.1,y=0})==nil,
    'unavailable or invalid coordinates are never fabricated')
local mapInfo=C_Map.GetMapInfo; C_Map.GetMapInfo=function() error('temporary map lookup error') end
check(ns.Util.FormatLocation(item.point):find('地图102',1,true),'map-name lookup failure preserves valid coordinate information')
C_Map.GetMapInfo=mapInfo
'''),
    ("Book pickup: loot changes the hint to its NPC without inventing an accepted quest", r'''
FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
Fixture.mapOrder={101,102}
record(301,100,{name='书籍任务',startedBy={[1]={501},[2]={701}},finishedBy={[1]={501}},objectives={[3]={{601,nil,0}}}})
Fixture.items[601]={quest=0,objectDrops={701}}
Fixture.locations.npc[501]={[18]={{73.4,33}}}; place('object',701,300)
local result=plan(); setupMaps()
local source=action(result.discovery.opportunities,301,'possible_item_drop')
check(source and source.questItem and source.itemID==601 and source.point.entityKind=='object',
    'objective book is a collection source, not a quest-acceptance point')
check(not action(result.discovery.opportunities,301,'pick_up') and result.count==0,
    'unaccepted collection work cannot become a formal pickup step')
ns.WorldMap.Render(); ns.Minimap.Render()
local worldPin=ns.route.views[1].opportunities[1]
check(worldPin:IsVisible() and worldPin.text.text=='~!','book source remains visible after its toast')
worldPin:GetScript('OnEnter')(worldPin)
check(GameTooltip.lines[3]:find('拾取任务物品',1,true) and not GameTooltip.lines[3]:find('启动物品',1,true),
    'book tooltip distinguishes collecting an objective from using a quest starter')
Fixture.loggedIn=true; ns.StartRoute(); ns.RouteOptions.Get().switchNotice=true
local notices={}; ns.Util.Notify=function(text) notices[#notices+1]=text end
ns.route.associationNotice={key='301:possible_item_drop:601',at=30}; ns.route.lastNotice={key='301:possible_item_drop:601',at=30}
Fixture.time=31; Fixture.bags={601}
local driver=ns.route.driver; driver:GetScript('OnEvent')(driver,'BAG_UPDATE_DELAYED')
Fixture.time=31.5; driver:GetScript('OnUpdate')(driver,.2)
result=ns.GetPlan({})
check(result.reason=='BAG_UPDATE_DELAYED' and not action(result.discovery.opportunities,301,'possible_item_drop'),
    'normal bag event removes the already collected book source')
check(#result.discovery.carriedItems==1 and result.discovery.carriedItems[1].itemID==601,
    'carried book exposes its new stage to the plan')
local destination=result.discovery.carriedItems[1].point
check(destination.coordinateMapID==102 and destination.entityKind=='npc' and destination.entityID==501
    and math.abs(destination.x-.734)<1e-10 and math.abs(destination.y-.33)<1e-10,'carried book points at the actual foreign-map NPC')
check(result.count==0 and not action(result.decision.predicted,301,'turn_in') and #Fixture.log==0,
    'owning the book does not fabricate acceptance or official completion')
check(#notices==1 and notices[1]:find('已取得',1,true) and notices[1]:find('确认接取/交付',1,true)
    and notices[1]:find('Map 102 73.4, 33.0',1,true),'acquisition immediately explains the next NPC even inside the earlier hint interval')
check(not worldPin:IsVisible() and not worldPin.step,'old collection marker is cleared rather than pointing back at the looted source')
Fixture.time=32; driver:GetScript('OnEvent')(driver,'BAG_UPDATE_DELAYED')
Fixture.time=32.5; driver:GetScript('OnUpdate')(driver,.2)
check(#notices==1,'unchanged inventory does not repeat the acquired-book notice')
Fixture.playerMapID=102
result=ns.Planner.Rebuild('player_map_changed'); if result.discovery.building then finishIndex() end
result=ns.Planner.Rebuild('association_index_ready'); ns.WorldMap.Render(); ns.Minimap.Render()
check(result.discovery.carriedItems[1] and ns.route.views[1].opportunities[1]:IsVisible()
    and ns.route.views[1].opportunities[1].carried,'NPC guidance survives the map change without reacquiring the book')
ns.RouteOptions.Get().skipped[301]=true
check(#ns.Planner.Rebuild('quest_skipped').discovery.carriedItems==0,'explicitly skipped book suppresses NPC guidance even when owned')
ns.RouteOptions.Get().skipped[301]=nil
Fixture.log={301}; Fixture.status[301]='ready_for_turn_in'; Fixture.pois={[102]={NewPOI(102,.734,301)}}
result=ns.Planner.Rebuild('QUEST_LOG_UPDATE'); ns.WorldMap.Render(); ns.Minimap.Render()
check(#result.discovery.carriedItems==0 and result.steps[1] and result.steps[1].action=='turn_in',
    'actual official acceptance/completion replaces advisory guidance with the normal delivery route')
'''),
    ("Book pickup: ordinary object quest givers and ambiguous drops keep their meaning", r'''
record(301,100,{startedBy={[2]={701}},objectives={[1]={{501,nil,0}}}}); place('object',701,50)
record(302,100,{startedBy={[2]={702}},objectives={[3]={{602,nil,0}}}}); place('object',702,60)
Fixture.items[602]={quest=0,objectDrops={702,703}}; place('object',703,70)
record(303,100,{startedBy={[2]={704}},objectives={[3]={{603,nil,0}}}}); place('object',704,80)
Fixture.items[603]={quest=303,objectDrops={704}}
local data=collect({})
check(action(data.opportunities,301,'pick_up'),'ordinary object quest giver is still a real pickup')
check(action(data.opportunities,302,'pick_up') and not action(data.opportunities,302,'possible_item_drop'),
    'ambiguous item sources cannot reclassify a quest giver')
Fixture.bags={603}; data=collect({})
check(action(data.opportunities,303,'start_item') and #data.carriedItems==0,
    'a real use-to-start item remains a start-item action rather than a carried objective')
ns.RouteOptions.Get().skipped[301]=true; data=collect({})
check(not action(data.opportunities,301,'pick_up'),'skipped unaccepted quest cannot leave a source marker')
'''),
    ("Level comfort: creature level controls work and chains regardless of quest level", r'''
ns.RouteOptions.Get().minPickupLevel=0
local playerLevel=23; UnitLevel=function() return playerLevel end
local readInfo=C_QuestLog.GetInfo
C_QuestLog.GetInfo=function(i) local row=readInfo(i); row.level=Fixture.quests[row.questID].questLevel; return row end
record(201,10,{questLevel=10}); record(202,200,{questLevel=60,objectives={[1]={{502,nil,0}}}})
record(301,10,{questLevel=10,preQuestSingle={201}}); place('npc',502,300)
FixtureDB.Npc.maxLevel=function(id) return id==501 and 26 or 24 end
Fixture.log={201,202}; Fixture.pois={[101]={NewPOI(101,.001,201)}}
local result=plan()
check(not action(result.steps,201,'quest_area') and result.steps[1].questID==202,
    'level10 quest with a level26 monster cannot override level60 quest with suitable monsters')
local why; for _,q in ipairs(result.excluded) do if q.questID==201 then why=q.reason end end
check(why=='target_above_level','why explains the actual creature limit rather than the quest-level label')
check(not ns.RouteOptions.Get().skipped[201] and result.levelingPriority.maxLevelOffset==2,'deferral is automatic and exposes the two-level margin')
for _,step in ipairs(result.decision.predicted) do check(step.questID~=201 and step.questID~=301,'chain gain cannot simulate blocked high-level work or unlock its child') end
local data=collect(); check(data.quests[301].eligibility=='blocked' and data.quests[301].conditionReason=='target_above_level',
    'unaccepted chain candidates share the creature limit despite their low quest labels')
Fixture.loggedIn=true; ns.StartRoute(); local driver=ns.route.driver
playerLevel=24; Fixture.time=10; driver:GetScript('OnUpdate')(driver,.6); result=ns.GetPlan({})
check(result.reason=='player_level_changed' and action(result.steps,201,'quest_area'),
    'level-up while stationary restores level-26 work without changing skip preferences')
playerLevel=23; Fixture.status[201]='ready_for_turn_in'; result=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(action(result.steps,201,'turn_in'),'officially completed high-level quest remains eligible for delivery')
Fixture.status[201]='complete'; result=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(action(result.steps,201,'completion_pending'),'completed quest waiting for official turn-in confirmation also bypasses work limits')
'''),
    ("Monster-level options: limits are configurable, character-scoped and independent of quest labels", r'''
UnitLevel=function() return 23 end
record(201,10,{questLevel=10}); record(202,100,{questLevel=60,objectives={[1]={{502,nil,0}}}})
record(301,20,{questLevel=99}); place('npc',502,200)
FixtureDB.Npc.maxLevel=function(id) return id==501 and 26 or 23 end
Fixture.log={201,202}; local result=plan()
check(result.maxMonsterLevelOffset==2 and not action(result.steps,201,'quest_area') and action(result.steps,202,'quest_area'),
    'defaults restrict monsters, not low/high quest labels')
result=ns.SetRouteOptions({maxMonsterLevelOffset=3})
check(result.ok and result.maxMonsterLevelOffset==3 and action(result.steps,201,'quest_area')
    and ns.RouteOptions.Get().maxMonsterLevelOffset==3,'raising the allowed monster gap restores work immediately')
local data=collect()
check(data.quests[301].eligibility=='eligible','high quest label cannot hide a now-allowed creature goal from lookahead')
result=ns.SetRouteOptions({maxMonsterLevelOffset=0})
check(result.ok and result.maxMonsterLevelOffset==0 and action(result.steps,202,'quest_area') and not action(result.steps,201,'quest_area'),
    'zero permits same-level monsters and excludes higher monsters')
data=collect()
check(data.quests[301].conditionReason=='target_above_level' and not action(data.opportunities,301,'pick_up'),
    'discovery and future chains immediately use the configured creature gap')
local before=ns.GetPlan({}); local enabled=ns.RouteOptions.Get().enabled
for _,value in ipairs({-1,6,1.5,'1',false,math.huge,0/0,{}}) do
    local rejected=ns.SetRouteOptions({maxMonsterLevelOffset=value,enabled=not enabled})
    check(not rejected.ok and ns.GetPlan({}).sequence==before.sequence and ns.RouteOptions.Get().maxMonsterLevelOffset==0
        and ns.RouteOptions.Get().enabled==enabled,'invalid numeric option has no partial settings or route side effects')
end
local oldName=UnitName; UnitName=function() return 'OtherCharacter' end
check(ns.RouteOptions.Get().maxMonsterLevelOffset==2,'another character starts with the default')
ns.SetRouteOptions({maxMonsterLevelOffset=1}); UnitName=oldName
check(ns.RouteOptions.Get().maxMonsterLevelOffset==0,'character-specific changes do not leak to the previous character')
SlashCmdList.QUESTROUTE('monsterlevel 1')
check(ns.GetPlan({}).maxMonsterLevelOffset==1,'slash command updates the same saved monster setting')
local settings=ns.RouteOptions.Get(); settings.maxMonsterLevelOffset=nil
check(ns.RouteOptions.Get().maxMonsterLevelOffset==2,'old saved settings receive the default without migration')
settings.maxMonsterLevelOffset='bad'
check(ns.RouteOptions.Get().maxMonsterLevelOffset==2,'malformed saved value recovers to a valid default')
'''),
    ("Monster-level settings: late native slider registers once and reloads callbacks", r'''
record(201,100); plan()
local sliderOptions,slider=Settings.CreateSliderOptions,Settings.CreateSlider
Settings.CreateSliderOptions,Settings.CreateSlider=nil,nil
Fixture.loggedIn=true; ns.StartRoute()
local ui=ns.settingsUI
check(ui.category.registered and not ui.monsterLevelSetting,'old native category can exist before the new slider is available')
Settings.CreateSliderOptions,Settings.CreateSlider=sliderOptions,slider
ns.RegisterSettings(); ns.RegisterSettings()
check(ui.monsterLevelSetting and Settings.sliderCount==2 and #ui.monsterLevelSetting.callbacks==1,
    'new slider registers independently of an already registered category without duplicate callbacks')
local before=ns.GetPlan({}).sequence; ui.monsterLevelSetting:SetValue(1)
check(ns.GetPlan({}).maxMonsterLevelOffset==1 and ns.GetPlan({}).sequence==before+1,'native slider performs exactly one immediate rebuild')
ui.monsterLevelSetting.callbacks[1](ui.monsterLevelSetting,1)
check(ns.GetPlan({}).sequence==before+1,'duplicate native value notification cannot rebuild the route twice')
ns.OnUnload(); before=ns.GetPlan({}).sequence; ui.monsterLevelSetting:SetValue(0)
check(ns.GetPlan({}).sequence==before,'unloaded namespace has no live settings callback')
ns.OnReload(); before=ns.GetPlan({}).sequence; ui.monsterLevelSetting:SetValue(2)
check(ns.GetPlan({}).maxMonsterLevelOffset==2 and ns.GetPlan({}).sequence==before+1 and Settings.sliderCount==2
    and #ui.monsterLevelSetting.callbacks==1,'reload redirects one existing callback to the current namespace')
check(ui.pickupLevelSetting and #ui.pickupLevelSetting.callbacks==1,'minimum-level slider also registers once after the category exists')
before=ns.GetPlan({}).sequence; ui.pickupLevelSetting:SetValue(20)
check(ns.GetPlan({}).minPickupLevel==20 and ns.GetPlan({}).sequence==before+1,'minimum-level slider applies exactly once')
ui.pickupLevelSetting.callbacks[1](ui.pickupLevelSetting,20)
check(ns.GetPlan({}).sequence==before+1,'duplicate minimum-level notification cannot replan twice')
ns.OnUnload(); before=ns.GetPlan({}).sequence; ui.pickupLevelSetting:SetValue(0)
check(ns.GetPlan({}).sequence==before,'unloaded minimum-level dispatcher stays inactive')
ns.OnReload(); before=ns.GetPlan({}).sequence; ui.pickupLevelSetting:SetValue(15)
check(ns.GetPlan({}).minPickupLevel==15 and ns.GetPlan({}).sequence==before+1
    and #ui.pickupLevelSetting.callbacks==1 and Settings.sliderCount==2,'minimum-level callback returns to the current namespace after reload')
'''),
    ("Level comfort: material routes and hotspot changes choose suitable NPC sources", r'''
UnitLevel=function() return 23 end
record(201,100,{questLevel=23,objectives={[3]={{601,nil,0}}}})
record(202,100,{questLevel=23,objectives={[1]={{503,nil,0}}}})
Fixture.items[601]={npcDrops={501,502}}; place('npc',501,500); place('npc',503,10)
Fixture.locations.npc[502]={[17]={{3,0},{8,0}}}
FixtureDB.Npc.maxLevel=function(id) return id==502 and 24 or 27 end
Fixture.log={201,202}; local result=plan()
check(result.steps[1] and result.steps[1].questID==201 and result.steps[1].entityID==502,
    'a lower-level material source wins even when an unsafe source is closer')
for _,step in ipairs(result.steps) do
    check(step.entityID~=501 and step.entityID~=503,'unsafe NPCs cannot enter formal work steps')
    for _,spot in ipairs(step.hotspots) do check(spot.world.x~=500,'unsafe sources cannot enter visible hotspot alternatives') end
end
local reason; for _,q in ipairs(result.excluded) do if q.questID==202 then reason=q.reason end end
check(reason=='target_above_level','low quest labels cannot hide a required high-level monster')
local changed=ns.ChangeQuestSpot({questID=201})
check(changed.ok and ns.GetPlan({}).steps[1].entityID==502 and ns.GetPlan({}).steps[1].world.x==800,
    'manual next hotspot uses the same combat limit instead of switching to the closer unsafe source')
'''),
    ("Level comfort: lookahead cannot complete a goal whose only monster sources are too high", r'''
UnitLevel=function() return 23 end
record(201,100,{questLevel=23,objectives={[1]={{502,nil,0}}}}); Fixture.log={201}
record(301,20,{questLevel=23,objectives={[1]={{501,nil,0}}}})
record(302,30,{questLevel=23,objectives={[3]={{601,nil,0}}}})
record(303,40,{questLevel=23,objectives={[3]={{602,nil,0}}}})
Fixture.items[601]={npcDrops={501,502}}; Fixture.items[602]={npcDrops={501}}
place('npc',501,100); place('npc',502,200)
FixtureDB.Npc.maxLevel=function(id) return id==501 and 27 or 24 end
local data=collect()
check(data.quests[301].eligibility=='blocked' and data.quests[301].conditionReason=='target_above_level',
    'a tempting pickup cannot bypass its required combat level')
check(data.quests[303].eligibility=='blocked' and not data.quests[303].targetsComplete,
    'removing the only unsafe item source cannot imply a complete objective')
check(data.quests[302].eligibility=='eligible' and data.quests[302].targetsComplete and #data.quests[302].targets==1
    and data.quests[302].targets[1].entityID==502,'a material with a safe alternative remains fully supported')
check(not action(data.opportunities,301,'pick_up') and not action(data.opportunities,303,'pick_up'),
    'nearby hints do not advertise combat that cannot be recommended')
local result=plan()
for _,step in ipairs(result.decision.predicted) do
    check(step.questID~=301 and step.questID~=303 and (step.action~='quest_area' or step.point.entityID~=501),
        'predicted shared work, rewards and unlocks cannot use blocked monsters')
end
'''),
    ("Level comfort: completed goals, NPC interactions and unknown levels keep their meaning", r'''
UnitLevel=function() return 23 end
record(201,10,{questLevel=23,objectives={[1]={{501,nil,0},{502,nil,0}}}}); Fixture.log={201}
record(301,100,{questLevel=23,objectives={}})
Fixture.official[201]={{text='npc501: 1/1',type='monster',finished=true,numFulfilled=1,numRequired=1},
    {text='npc502: 0/1',type='monster',finished=false,numFulfilled=0,numRequired=1}}
place('npc',502,200); FixtureDB.Npc.maxLevel=function(id) return id==501 and 27 or 24 end
local result=plan()
check(result.steps[1] and result.steps[1].entityID==502,'an already-finished high-level objective cannot block the remaining suitable goal')
FixtureDB.Npc.maxLevel=function(id) return id>10000 and 60 or id==501 and 27 or 24 end
local data=collect()
check(action(data.opportunities,301,'pick_up'),'high-level friendly quest givers are not mistaken for combat targets')
local point=point(501,100); local levels={}
check(ns.RouteOptions.TargetAboveLevel(FixtureDB,point,23,levels)==true
    and ns.RouteOptions.TargetAboveLevel(FixtureDB,point,25,{})==false,'NPC threshold changes precisely at the two-level boundary')
point.entityKind='object'
check(not ns.RouteOptions.TargetAboveLevel(FixtureDB,point,23,{}),'object interactions have no NPC combat level')
point.entityKind='npc'; FixtureDB.Npc.maxLevel=function() error('missing level') end
check(not ns.RouteOptions.TargetAboveLevel(FixtureDB,point,23,{}),'unavailable level is unknown rather than fabricated high or zero')
FixtureDB.Npc.minLevel=function() return 26 end
check(ns.RouteOptions.TargetAboveLevel(FixtureDB,point,23,{})==true,'known minimum above the limit remains sufficient when maximum is missing')
check(not ns.RouteOptions.TargetAboveLevel({Npc=42},point,23,{}) and not ns.RouteOptions.TargetAboveLevel(FixtureDB,42,23,{}),
    'malformed optional level data cannot crash route planning')
UnitLevel=function() return nil end
check(not ns.RouteOptions.Exclusion({questID=301,level=26,status='in_progress'},FixtureDB,ns.RouteOptions.Get()),
    'unknown player level does not create a guessed level restriction')
'''),
    ("Level comfort: missing unsafe coordinates cannot bypass the limit through native POI", r'''
UnitLevel=function() return 23 end
record(201,100,{questLevel=25}); Fixture.log={201}
FixtureDB.Npc.maxLevel=function() return 27 end
Fixture.locations.npc[501]={}; Fixture.pois={[101]={NewPOI(101,.6,201)}}
local result=plan()
check(result.count==0 and result.excluded[1].reason=='target_above_level',
    'known unsafe required NPC is deferred before reading its missing coordinates')
check(result.objectiveResolution[1].reason=='target_above_level','native POI cannot erase the rejected NPC identity')
local raw=ns.GetQuestTargets({questID=201,mapID=101})
check(raw.mode=='native_poi' and raw.targets[1] and raw.targets[1].x==.6,
    'read-only target query retains the raw native fallback independent of route comfort limits')
'''),
    ("Level comfort: unsafe source conversion cannot mask a safe alternative or create a fallback", r'''
UnitLevel=function() return 23 end
record(201,100,{questLevel=25,objectives={[3]={{601,nil,0}}}}); Fixture.log={201}
Fixture.items[601]={npcDrops={501,502}}; place('npc',501,500); place('npc',502,800)
FixtureDB.Npc.maxLevel=function(id) return id==501 and 27 or 24 end
Fixture.pois={[101]={NewPOI(101,.6,201)}}
local convert=C_Map.GetWorldPosFromMapPos
C_Map.GetWorldPosFromMapPos=function(map,p) if math.abs(p.x-.05)<1e-8 then return nil end; return convert(map,p) end
local result=plan()
check(result.steps[1] and result.steps[1].entityID==502 and result.steps[1].targetMode=='objective_locations',
    'unsafe source is removed before its bad world conversion could erase the safe source')
C_Map.GetWorldPosFromMapPos=function(map,p) if math.abs(p.x-.08)<1e-8 then return nil end; return convert(map,p) end
result=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(result.count==0 and result.excluded[1].reason=='world_position_unavailable' and result.pendingObjectiveCount==1,
    'missing safe coordinates cannot redirect work toward an unidentified POI when a dangerous alternative was excluded')
C_Map.GetWorldPosFromMapPos=convert; Fixture.time=10
result=ns.Planner.Rebuild('objective_data_refresh')
check(result.steps[1] and result.steps[1].entityID==502 and result.pendingObjectiveCount==0,
    'safe coordinate recovery restores the allowed source')
local raw=ns.GetQuestTargets({questID=201,mapID=101})
local dangerous=false; for _,p in ipairs(raw.targets) do if p.entityID==501 then dangerous=true end end
check(dangerous and raw.mode=='objective_locations','raw target data still reports unsafe sources when explicitly queried')
'''),
    ("Planner: temporary objective fallback preserves work protection and its timer", r'''
record(201); record(301,50); place('npc',501,100); Fixture.log={201}
Fixture.pois={[101]={NewPOI(101,.01,201)}}
ns.RouteOptions.Get().switchNotice=false
local original=ns.Replan({})
check(original.navigation.protected and original.steps[1].objectiveKey=='npc:501','precise work is initially protected')
if original.discovery.building then finishIndex() end
local read=C_QuestLog.GetQuestObjectives
C_QuestLog.GetQuestObjectives=function(id) if id==201 then return nil end return read(id) end
Fixture.time=1
local result=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(result.decision.recommendation~=nil,'fallback still has a competing association')
check(result.steps[1].questID==201 and result.navigation.phase=='working' and result.navigation.protected,
    'temporary identity loss cannot replace current work')
check(result.decision.deferred=='working_target_protected' and not result.decision.applied,'association respects fallback work protection')
check(result.navigation.workStartedAt==original.navigation.workStartedAt,'fallback does not renew the work timer')
Fixture.time=180; result=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(not result.navigation.protected and (result.steps[1].questID~=201 or result.navigation.stale),
    'repeated fallback still releases protection at the original idle timeout')
C_QuestLog.GetQuestObjectives=read
Fixture.time=181; result=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(result.decision.applied and result.steps[1].questID==301,'restored identity does not revive expired protection')
'''),
    ("Planner: skipped active quests cannot occupy the recommendation", r'''
record(201); record(301,100)
record(101,100,{preQuestSingle={201,401}}); place('npc',20101,50)
Fixture.pois={[101]={NewPOI(101,.005,101)}}
Fixture.completed[401]=true; Fixture.log={101,201}; Fixture.status[101]='ready_for_turn_in'
ns.RouteOptions.Get().skipped[101]=true
local result=plan()
check(result.decision.applied and result.steps[1].questID==301 and result.steps[1].action=='pick_up',
    'blocked delivery cannot crowd out an executable shared pickup')
check(not action(result.decision.predicted,101,'turn_in'),'skipped active quest has no predicted delivery')
check(not action(result.steps,101,'turn_in') and C_QuestLog.IsOnQuest(101),'skip preserves official membership while excluding route work')
local a,b,c=model(201,true),model(301,false),model(101,true)
c.eligibility='blocked'; c.conditionReason='skipped'; c.exclusiveTo={301}
local blocked=evaluate({[201]=a,[301]=b,[101]=c},201)
check(not action(blocked.predicted,301,'pick_up'),'skipped active quests still enforce official exclusivity')
'''),
    ("Planner: manual hotspot survives events until explicit replan", r'''
record(201); record(301,100); Fixture.log={201}; ns.RouteOptions.Get().skipped[301]=true
Fixture.locations.npc[501]={[17]={{10,0},{40,0}}}
plan(); ns.RouteOptions.Get().skipped[301]=nil
local changed=ns.ChangeQuestSpot({questID=201,objectiveKey='npc:501'})
check(changed.ok and changed.selected.world.x==4000,'manual hotspot was committed')
local result=ns.Planner.Rebuild('BAG_UPDATE_DELAYED')
check(result.steps[1].questID==201 and result.steps[1].world.x==4000,'unrelated event preserves the selected hotspot')
check(not result.decision.applied and result.decision.deferred=='manual_spot_retained','automatic association explains the retained manual target')
check(ns.route.manualSpot and ns.route.manualSpot.expiresAt==changed.expiresAt,'selection shares the existing avoidance lifetime')
result=ns.Replan({})
check(not ns.route.manualSpot and result.steps[1].questID==301,'explicit replan releases the manual selection')
'''),
    ("Planner: completed manual goal releases its priority", r'''
record(201); record(301,100); Fixture.log={201}; ns.RouteOptions.Get().skipped[301]=true
Fixture.locations.npc[501]={[17]={{10,0},{40,0}}}
plan(); ns.RouteOptions.Get().skipped[301]=nil
check(ns.ChangeQuestSpot({questID=201,objectiveKey='npc:501'}).ok,'manual goal is selected')
Fixture.status[201]='ready_for_turn_in'; Fixture.pois={[101]={NewPOI(101,.1,201)}}
local result=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(not ns.route.manualSpot,'official completion releases the stored manual goal')
check(not result.decision.deferred or result.decision.deferred~='manual_spot_retained','completed work cannot block a new association')
'''),
    ("Planner: map-finished notice precedes a new item-source hint", r'''
FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
record(201); record(202,100,{objectives={[1]={{502,nil,0}}}})
Fixture.locations.npc[502]={[18]={{10,0}}}
record(301,100,{startedBy={[3]={601}}})
Fixture.items[601]={quest=301,npcDrops={503}}; place('npc',503,50)
Fixture.log={201,202}; local loaded=false
HaveQuestData=function(id) return id~=301 or loaded end
local before=plan(); check(before.count==1,'initial route has local work')
local notices={}; ns.Util.Notify=function(text) notices[#notices+1]=text end
ns.RouteOptions.Get().switchNotice=true
ns.route.lastNotice=nil; ns.route.associationNotice=nil
loaded=true; Fixture.completed[201]=true; Fixture.log={202}; Fixture.time=50
local result=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(result.count==0 and result.nextMapHint and result.nextMapHint.mapID==102,'finishing the map yields the foreign map hint')
check(action(result.discovery.opportunities,301,'possible_item_drop'),'newly loaded item source is a competing hint')
check(#notices==1 and notices[1]:find('当前地图已无可做任务',1,true),'map-finished transition receives the one-line notification')
Fixture.time=100; ns.Planner.Rebuild('QUEST_LOG_UPDATE')
local finished=0
for _,text in ipairs(notices) do if text:find('当前地图已无可做任务',1,true) then finished=finished+1 end end
check(finished==1,'later item hints do not duplicate the map-finished notification')
'''),
    ("Planner: throttled map-finished notice is delivered once by the normal driver", r'''
FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
record(201); record(202,100,{objectives={[1]={{502,nil,0}}}})
Fixture.locations.npc[502]={[18]={{10,0}}}; Fixture.log={201,202}
plan(); Fixture.loggedIn=true; ns.StartRoute()
ns.RouteOptions.Get().switchNotice=true
local notices={}; ns.Util.Notify=function(text) notices[#notices+1]=text end
ns.route.lastNotice={key='association:recent',at=49}
Fixture.completed[201]=true; Fixture.log={202}; Fixture.time=50
local result=ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(result.nextMapHint and #notices==0 and ns.route.nextMapNoticeAt==57,'throttled transition is kept until the existing interval ends')
Fixture.time=56.99; ns.route.driver:GetScript('OnUpdate')(ns.route.driver,.2)
check(#notices==0,'pending map notice respects the eight-second interval')
Fixture.time=57; ns.route.driver:GetScript('OnUpdate')(ns.route.driver,.2)
check(#notices==1 and notices[1]:find('当前地图已无可做任务',1,true),'normal driver delivers the deferred map notice')
check(not ns.route.nextMapNoticeAt,'sent map notice clears its retry')
Fixture.time=70; ns.route.driver:GetScript('OnUpdate')(ns.route.driver,.2)
check(#notices==1,'sent map notice is never repeated')
'''),
    ("Discovery: triggerEnd blocks inferred delivery while ordinary goals survive", r'''
for id=301,306 do record(id,100) end
place('npc',501,200)
Fixture.quests[301].triggerEnd={'Scout the event',{[17]={{70,0}}}}
Fixture.quests[302].triggerEnd={'Unknown event'}
Fixture.quests[303].triggerEnd=true
Fixture.quests[304].triggerEnd=0
Fixture.quests[305].triggerEnd={}
local data=collect({})
for id=301,306 do
    local quest=data.quests[id]
    check(#quest.targets==1 and quest.targets[1].shareable,'ordinary goal survives event metadata '..id)
    local ordinary=id>=305
    check(quest.targetsComplete==ordinary,'only known empty triggerEnd certifies coverage '..id)
    local result=ns.Decision.Evaluate({available=true,quests={[id]=quest},completed={[id]=false},
        opportunities={{questID=id,action='pick_up'}}},{},point(1,0).world,nil)
    check(action(result.predicted,id,'pick_up') and action(result.predicted,id,'quest_area'),
        'known ordinary work remains predictable '..id)
    if not ordinary then check(not action(result.predicted,id,'turn_in'),'event is never inferred complete '..id) end
end
check(data.completed[301]==false,'prediction never changes official completion history')
'''),
    ("Discovery: absent triggerEnd getter remains unknown", r'''
record(301,100)
local getter=FixtureDB.Quest.Get
for _,field in ipairs({'name','questLevel','requiredLevel','requiredMaxLevel','requiredRaces','requiredClasses',
    'requiredSkill','requiredMinRep','requiredMaxRep','requiredSpell','requiredRanks','requiredSpecialization',
    'parentQuest','nextQuestInChain','availableStartingWith','availableUntilCompleted','disabledByQuest',
    'breadcrumbForQuestId','preQuestGroup','preQuestSingle','exclusiveTo','childQuests','startedBy','finishedBy',
    'objectives','extraObjectives'}) do
    local key=field
    FixtureDB.Quest[key]=function(id) return getter(id,key) end
end
FixtureDB.Quest.Get=nil
local data=collect({})
check(data.quests[301].eligibility=='eligible','unavailable event metadata does not erase known pickup eligibility')
check(#data.quests[301].targets==1 and not data.quests[301].targetsComplete,
    'unknown event metadata cannot certify all goals')
'''),
    ("Discovery: native coverage and ready delivery survive triggerEnd", r'''
record(201,100,{triggerEnd={'Event recorded by the client'}}); Fixture.log={201}
local data=collect()
check(data.quests[201].targetsComplete and data.quests[201].targets[1].shareable,
    'reliable native ordinary coverage is still authoritative')
Fixture.official[201]={{text='npc501: 0/1',type='monster',finished=false,numFulfilled=0,numRequired=1},
    {text='Unknown exploration',type='event',finished=false}}
data=collect()
check(not data.quests[201].targetsComplete,'unfinished unmapped native event stays unknown')
Fixture.status[201]='ready_for_turn_in'; data=collect()
check(data.quests[201].status=='ready_for_turn_in' and #data.quests[201].finishers>0,
    'official ready state retains delivery despite static event metadata')
'''),
    ("Discovery: Gossip supplies the current official starter and preserves provenance", r'''
record(201); Fixture.log={201}; place('npc',501,200)
record(301,5000)
record(302,100,{startedBy={}})
record(303,100,{startedBy={},triggerEnd={'Unknown exploration'}})
record(304,100,{startedBy={},requiredLevel='unknown'})
record(305,0)
gossip(10301,{{questID=301},{questID=302},{questID=303},{questID=304},{questID=305}})
local data=collect()
for _,id in ipairs({301,302,303,305}) do
    local quest=data.quests[id]
    local offer=action(data.opportunities,id,'pick_up')
    check(offer and offer.certainty=='confirmed' and offer.point.world.x==0
        and offer.point.source=='client' and offer.point.precision=='interaction_position','official current opportunity '..id)
    check(#quest.starters==1 and quest.starters[1].world.x==0,'Decision receives the official point '..id)
    check(quest.starters[1].source=='client' and quest.starters[1].precision=='interaction_position',
        'official point is not relabeled static '..id)
    check(#quest.targets==1 and quest.targets[1].source=='QuestieDB'
        and quest.targets[1].precision=='static_spawn','ordinary static target provenance survives '..id)
    local result=ns.Decision.Evaluate({available=true,quests={[id]=quest},completed={[id]=false},
        opportunities={{questID=id,action='pick_up'}}},{},point(1,0).world,nil)
    local pickup=action(result.predicted,id,'pick_up')
    check(pickup and pickup.point.world.x==0 and pickup.point.source=='client'
        and pickup.point.precision=='interaction_position','Decision uses the observed starter '..id)
    if id==303 then check(not action(result.predicted,id,'turn_in'),'Gossip cannot complete an unknown event') end
end
check(data.quests[302].targetsComplete,'official starter supports ordinary work without a static starter')
check(not data.quests[303].targetsComplete,'official availability does not certify unknown event conditions')
check(data.quests[304].eligibility=='unknown' and not action(data.opportunities,304,'pick_up'),
    'official availability does not erase unknown eligibility conditions')
ns.Discovery.ObserveInteraction('GOSSIP_CLOSED'); data=collect()
check(data.quests[301].starters[1].world.x==5000 and data.quests[301].starters[1].source=='QuestieDB'
    and data.quests[301].starters[1].precision=='static_spawn','static starter remains available after Gossip ends')
'''),
    ("Discovery: NPC dialogue corrects static pickup predictions without permanent skips", r'''
record(201,100); Fixture.log={201}
for id=1000,1040 do record(id,100,{requiredLevel=60}) end
record(97287,100,{name='精明的谈判',startedBy={[1]={2410}}}); place('npc',2410,100)
record(98094,200,{name='支援斥候',startedBy={[1]={2215}}}); place('npc',2215,200)
local result=plan()
check(action(result.discovery.opportunities,97287,'pick_up'),'static estimate initially remains discoverable')
Fixture.loggedIn=true; ns.StartRoute()
Fixture.units.npc={id=2410}; Fixture.offered={}
local driver=ns.route.driver
check(driver.events.GOSSIP_OPTIONS_REFRESHED and driver.events.QUEST_ACCEPTED and driver.events.PLAYER_LEVEL_UP,
    'interaction updates and eligibility changes are registered')
driver:GetScript('OnEvent')(driver,'GOSSIP_SHOW')
Fixture.time=1; driver:GetScript('OnUpdate')(driver,.2)
local data=collect()
check(data.quests[97287].eligibility=='unknown' and data.quests[97287].conditionReason=='npc_not_offering',
    'actual empty dialogue overrides the static eligibility guess')
check(not action(data.opportunities,97287,'pick_up') and not action(ns.GetPlan({}).steps,97287,'pick_up'),
    'rejected starter leaves both suggestions and formal route')
check(action(data.opportunities,98094,'pick_up'),'different NPC is not rejected by another dialogue')
check(not ns.RouteOptions.Get().skipped[97287] and not ns.RouteOptions.Get().skipped[98094],
    'observations never write player skip preferences')
setupMaps(); ns.WorldMap.Render(); ns.Minimap.Render()
local rejectedPin
for _,pin in pairs(ns.route.views[1].opportunities) do
    if pin.step and pin.step.questID==97287 then rejectedPin=pin end
end
check(rejectedPin and rejectedPin:IsVisible() and rejectedPin.text.text=='×',
    'failed availability check remains a visible map reference rather than disappearing')
rejectedPin:GetScript('OnEnter')(rejectedPin)
check(#GameTooltip.lines<=4 and GameTooltip.lines[3]:find('NPC当前未提供',1,true),
    'map reference explains the observed refusal without inventing a prerequisite')
local printed={}; local realPrint=print; print=function(text) printed[#printed+1]=text end
SlashCmdList.QUESTROUTE('why'); print=realPrint
check(table.concat(printed,'\n'):find('接取核验 [97287]',1,true),'why reports the failed NPC check')
ns.Discovery.ObserveInteraction('GOSSIP_CLOSED'); Fixture.playerX=.01
check(collect().quests[97287].conditionReason=='npc_not_offering','closing or moving does not immediately forget rejection')
ns.Discovery.ObserveInteraction('PLAYER_LEVEL_UP')
check(action(collect().opportunities,97287,'pick_up'),'changed player conditions permit a fresh estimate')
gossip(2410,{{questID=97287}})
check(action(collect().opportunities,97287,'pick_up').certainty=='confirmed','later actual offer restores availability')
'''),
    ("Discovery: rejections are per starter and future prerequisites can change offers", r'''
record(301,100,{startedBy={[1]={10301,11301}}}); place('npc',11301,200)
record(302,100,{preQuestSingle={201}})
gossip(10301,{})
local data=collect()
check(data.quests[301].eligibility=='eligible' and #data.quests[301].starters==1
    and data.quests[301].starters[1].entityID==11301,'another untested starter remains usable')
check(action(data.opportunities,301,'pick_up').point.entityID==11301,'proposals do not retain the nearer rejected starter')
gossip(11301,{})
data=collect()
check(data.quests[301].conditionReason=='npc_not_offering' and not action(data.opportunities,301,'pick_up'),
    'all known starters must reject before the quest becomes unavailable')
ns.Discovery.ObserveInteraction('QUEST_TURNED_IN')
check(#collect().quests[301].starters==2,'quest completion invalidates earlier dialogue checks')
gossip(10302,{})
data=collect()
check(data.quests[302].conditionReason=='prerequisite' and #data.quests[302].starters>0,
    'current refusal does not rule out the post-prerequisite pickup prediction')
'''),
    ("Discovery: stale or unreadable dialogue is never treated as a remote offer or refusal", r'''
record(301,100)
Fixture.offered={{questID=301}}
local data=collect()
check(action(data.opportunities,301,'pick_up').certainty=='estimated','a stale API list without an observed dialogue cannot confirm availability')
Fixture.units.npc={id=10301,readError=true}
ns.Discovery.ObserveInteraction('GOSSIP_SHOW')
check(action(collect().opportunities,301,'pick_up').certainty=='estimated','unreadable NPC identity cannot confirm an offer')
Fixture.units.npc={id=10301}; C_GossipInfo.GetNumAvailableQuests=function() return 1 end
Fixture.offered={}; ns.Discovery.ObserveInteraction('GOSSIP_SHOW')
check(action(collect().opportunities,301,'pick_up'),'incomplete list cannot reject a starter')
C_GossipInfo.GetNumAvailableQuests=function() return #Fixture.offered end
gossip(10301,{{questID=301}})
Fixture.playerX=.2; data=collect()
local offer=action(data.opportunities,301,'pick_up')
check(offer and offer.point.world.x==0 and offer.point.entityID==10301,
    'observed offer retains its NPC and interaction location after movement')
ns.Discovery.ObserveInteraction('GOSSIP_CLOSED'); data=collect()
check(not action(data.opportunities,301,'pick_up'),'closed dialogue does not create a confirmed offer at the later player position')
'''),
    ("Discovery: live NPC interactability overrides a static starter only with reliable nearby evidence", r'''
record(97287,100,{name='精明的谈判',startedBy={[1]={2410}}}); place('npc',2410,100)
FixtureDB.Npc.questStarts=function(id) if id==2410 then return {97287} end end
Fixture.units.target={id=2410}
local inRange,interactable,dead=false,false,false
UnitIsInInteractRange=function() return inRange end
UnitIsInteractable=function() return interactable end
UnitIsDeadOrGhost=function() return dead end
check(not ns.Discovery.ObserveUnits(),'out-of-range NPC cannot prove an interaction restriction')
inRange=true; dead=true
check(not ns.Discovery.ObserveUnits(),'dead NPC cannot prove a persistent interaction restriction')
dead=false; interactable=nil
check(not ns.Discovery.ObserveUnits(),'unknown interaction state stays unknown')
interactable=false
check(ns.Discovery.ObserveUnits(),'live nearby NPC records actual interaction restriction')
check(not ns.Discovery.ObserveUnits(),'unchanged observation does not cause repeated replans')
local data=collect()
check(data.quests[97287].conditionReason=='npc_not_interactable' and not action(data.opportunities,97287,'pick_up'),
    'unusable live starter cannot be advertised as a pickup')
local result=plan(); setupMaps(); ns.Minimap.Render()
local pin
for _,p in pairs(ns.route.minimapView.opportunities) do if p.step and p.step.questID==97287 then pin=p end end
check(pin and pin:IsVisible() and pin.text.text=='×','non-interactable starter keeps the grey reference')
pin:GetScript('OnEnter')(pin)
check(GameTooltip.lines[3]:find('NPC当前不可交互',1,true),'hover distinguishes inability to interact from an empty offer list')
check(not ns.RouteOptions.Get().skipped[97287],'interaction restriction never writes a manual skip')
Fixture.loggedIn=true; ns.StartRoute(); local sequence=ns.GetPlan({}).sequence
interactable=true; Fixture.time=1; ns.route.driver:GetScript('OnUpdate')(ns.route.driver,.2)
check(ns.GetPlan({}).sequence>sequence and ns.GetPlan({}).reason=='pickup_unit_changed',
    'existing position tick detects an interaction state change without moving')
check(action(collect().opportunities,97287,'pick_up'),'observed recovery releases the stale restriction')
gossip(2410,{}); interactable=true
check(not ns.Discovery.ObserveUnits() and collect().quests[97287].conditionReason=='npc_not_offering',
    'generic interaction permission does not override an actual empty quest list')
interactable=false
check(not ns.Discovery.ObserveUnits(),'an open actual dialogue is stronger evidence than the general interaction flag')
'''),
    ("Discovery: quest greeting and direct detail preserve complete versus partial evidence", r'''
record(301,100); record(302,100,{startedBy={[1]={10301}}})
Fixture.units.npc={id=10301}
GetNumAvailableQuests=function() return 0 end
ns.Discovery.ObserveInteraction('QUEST_GREETING')
check(collect().quests[301].conditionReason=='npc_not_offering','empty legacy greeting is an actual refusal')
GetQuestID=function() return 301 end
ns.Discovery.ObserveInteraction('QUEST_DETAIL')
local data=collect()
check(action(data.opportunities,301,'pick_up').certainty=='confirmed','direct quest detail confirms that quest')
check(action(data.opportunities,302,'pick_up'),'one detail page does not reject other NPC quests')
ns.Discovery.ObserveInteraction('QUEST_FINISHED')
check(action(collect().opportunities,301,'pick_up').certainty=='estimated','closing the quest frame clears live confirmation')
FixtureDB.Npc.questStarts=function() return {301,302} end
GetNumAvailableQuests=function() return 1 end
GetAvailableQuestInfo=function() return '任务 301' end
ns.Discovery.ObserveInteraction('QUEST_GREETING'); data=collect()
check(action(data.opportunities,301,'pick_up').certainty=='confirmed'
    and data.quests[302].conditionReason=='npc_not_offering','unique NPC-local legacy names identify offered and missing quests')
ns.Discovery.ObserveInteraction('QUEST_TURNED_IN')
GetAvailableQuestInfo=function() return 'not in the database' end
ns.Discovery.ObserveInteraction('QUEST_GREETING')
check(action(collect().opportunities,302,'pick_up'),'unmapped greeting cannot prove absence')
'''),
    ("Discovery: empty local coordinates retry without rescanning healthy or permanent records", r'''
FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
record(301,100); place('npc',501,200)
record(302,300,{objectives={[1]={{502,nil,0}}}}); place('npc',502,400)
record(303,100,{finishedBy={},objectives={}}); Fixture.locations.npc[10303]={[18]={{10,0}}}
record(304,100,{finishedBy={},objectives={}}); Fixture.locations.npc[10304]={[17]={{-1,-1}}}
record(305,100,{finishedBy={},objectives={}}); Fixture.locations.npc[10305]={[17]={{101,0}}}
record(306,100,{finishedBy={},objectives={}}); Fixture.locations.npc[10306]={[17]={{10,0,1}}}
record(307,100,{finishedBy={},objectives={}}); Fixture.locations.npc[10307]={}
record(308,350,{finishedBy={},objectives={}})
local context=ns.GetPlayerContext({})
local convert=C_Map.GetWorldPosFromMapPos
local failing=true
C_Map.GetWorldPosFromMapPos=function(map,position)
    if failing and position.x~=.035 then return nil end
    return convert(map,position)
end
ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get()); finishIndex()
local data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(not data.quests[301] and #data.opportunities==1,'missing local world positions are not complete or offered')
local reads,conversions={},0
local getter=FixtureDB.Quest.Get
FixtureDB.Quest.Get=function(id,field) reads[id]=(reads[id] or 0)+1; return getter(id,field) end
local spawnReads=0
local spawns=FixtureDB.Npc.spawns
FixtureDB.Npc.spawns=function(id) spawnReads=spawnReads+1; return spawns(id) end
local retryConvert=C_Map.GetWorldPosFromMapPos
C_Map.GetWorldPosFromMapPos=function(...) conversions=conversions+1; return retryConvert(...) end
Fixture.time=4.99
check(not ns.Discovery.Pump() and conversions==0,'no retry before the five-second deadline')
Fixture.time=5
check(not ns.Discovery.Pump() and conversions>0,'unsuccessful bounded retry does not request a replan')
check(reads[301] and reads[302],'only temporarily missing records are retried')
for id=303,308 do check(not reads[id],'healthy or permanently empty record is not retried '..id) end
local attempts=conversions
for _=1,5 do check(not ns.Discovery.Pump(),'completed failed retry pass stays idle') end
check(conversions==attempts,'no busy retry in the same five-second window')
failing=false; Fixture.time=9.99
check(not ns.Discovery.Pump() and conversions==attempts,'recovery waits for the next deadline')
Fixture.time=10
check(ns.Discovery.Pump(),'newly recovered points request the normal association replan')
data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(not data.building and data.scanned==data.total and #data.opportunities==3,'same-map recovery retains initial scan progress')
check(data.quests[301].targetsComplete and data.quests[302].targetsComplete,'recovered ordinary goals certify coverage')
check(spawnReads==0,'coordinate retries reuse known local spawn rows')
attempts=conversions; Fixture.time=15
check(not ns.Discovery.Pump() and conversions==attempts,'successful retry removes its pending records')
'''),
    ("Discovery: partial recovery retains good points without duplicate spatial entries", r'''
record(301,100,{objectives={[1]={{501,nil,0},{502,nil,0}}}})
record(302,100,{startedBy={[3]={601}},finishedBy={},objectives={}})
Fixture.items[601]={npcDrops={501}}
Fixture.locations.npc[501]={[17]={{2,0},{3,0}}}; place('npc',502,400)
local context=ns.GetPlayerContext({})
local convert=C_Map.GetWorldPosFromMapPos
local stage=0
C_Map.GetWorldPosFromMapPos=function(map,position)
    if position.x==.03 and stage<1 or position.x==.04 and stage<2
        or position.x==.1 and stage<3 then return nil end
    return convert(map,position)
end
ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get()); finishIndex()
local data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(#data.quests[301].targets==1 and not data.quests[301].targetsComplete,'one missing goal prevents partial coverage from claiming completion')
check(#data.quests[301].finishers==0,'missing delivery coordinate remains absent')
stage=1; Fixture.time=5
check(ns.Discovery.Pump(),'first partial recovery is published')
data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(#data.quests[301].targets==2 and not data.quests[301].targetsComplete,'alternate spawn does not hide the still-missing goal')
local calls={}
C_Map.GetWorldPosFromMapPos=function(map,position)
    calls[position.x]=(calls[position.x] or 0)+1
    if position.x==.02 or position.x==.03 then error('healthy coordinate must never be retried') end
    if position.x==.1 and stage<3 then return nil end
    return convert(map,position)
end
stage=2; Fixture.time=10
check(ns.Discovery.Pump(),'remaining target position recovers')
data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(#data.quests[301].targets==3 and data.quests[301].targetsComplete,'all ordinary goals become covered after recovery')
check(#data.quests[301].finishers==0,'delivery position waits for its own recovery')
stage=3; Fixture.time=15
check(ns.Discovery.Pump(),'finisher-only recovery requests a replan')
data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(#data.quests[301].finishers==1,'finisher-only recovery is retained')
check(not calls[.02] and not calls[.03],'healthy positions survive later transient failures')
local state
for i=1,20 do
    local name,value=debug.getupvalue(ns.Discovery.Pump,i)
    if name=='cache' then state=value; break end
end
check(state~=nil,'offline invariant check can inspect the existing local index')
local function entries(grid)
    local seen,count={},0
    for _,continent in pairs(grid) do for _,column in pairs(continent) do for _,cell in pairs(column) do
        for _,entry in ipairs(cell) do
            local p=entry.point
            local key=entry.questID..':'..(entry.action or 'target')..':'..(entry.itemID or 0)..':'
                ..p.key..':'..p.entityKind..':'..p.entityID..':'..p.x..':'..p.y
            check(not seen[key],'spatial entry is written once across retries: '..key)
            seen[key],count=true,count+1
        end
    end end end
    return count
end
check(entries(state.starts)==3,'one starter and two item-source positions are indexed exactly once')
check(entries(state.targets)==3,'three distinct target positions are indexed exactly once')
'''),
    ("Discovery: shared cache recovery survives a retry read error", r'''
record(301,100); record(302,200); place('npc',501,300)
local context=ns.GetPlayerContext({})
local getter=FixtureDB.Quest.Get
local recovered=false
FixtureDB.Quest.Get=function(id,field)
    if id==302 and field=='name' then recovered=true; Fixture.time=5 end
    return getter(id,field)
end
local convert=C_Map.GetWorldPosFromMapPos
local conversions=0
C_Map.GetWorldPosFromMapPos=function(map,position)
    conversions=conversions+1
    if position.x==.03 and not recovered then return nil end
    return convert(map,position)
end
ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get()); finishIndex()
local data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(not data.quests[301].targetsComplete and data.quests[302].targetsComplete,'later record can recover shared coordinates during initial build')
local throw=true
FixtureDB.Quest.Get=function(id,field)
    if id==301 and field=='name' and throw then error('temporary retry read error') end
    return getter(id,field)
end
Fixture.time=10
check(not ns.Discovery.Pump(),'read-error retry makes no new recommendation')
data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(data.quests[301].eligibility=='eligible' and #data.quests[301].starters==1
    and not data.quests[301].targetsComplete,'retry read error preserves the prior usable record')
local before=conversions
throw=false; Fixture.time=15
check(ns.Discovery.Pump(),'older record reuses an already recovered cache and requests a replan')
data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(data.quests[301].targetsComplete and #data.quests[301].targets==1,'older dependent record eventually gets full coverage')
check(conversions==before,'shared recovery avoids converting healthy coordinates again')
'''),
    ("Discovery: foreign item sources yield even when every source has zero local points", r'''
FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
record(301,100,{objectives={[3]={{601,nil,0}}}})
local npcs,objects={},{}
for i=1,1759 do
    npcs[i]=50000+i; objects[i]=60000+i
    Fixture.locations.npc[npcs[i]]={[18]={{10,0}}}
    Fixture.locations.object[objects[i]]={[18]={{10,0}}}
end
Fixture.items[601]={npcDrops=npcs,objectDrops=objects}
local reads,clock=0,0
for _,kind in ipairs({'Npc','Object'}) do
    local getter=FixtureDB[kind].spawns
    FixtureDB[kind].spawns=function(id) reads=reads+1; clock=clock+.01; return getter(id) end
end
debugprofilestop=function() return clock end
local context=ns.GetPlayerContext({})
ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
ns.Discovery.Pump()
local data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(data.building and reads>0 and reads<=128,'empty source enumeration yields within the operation budget')
check(clock<=3.01,'many short source reads cannot bypass the time budget')
finishIndex(); data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(not data.building and #data.quests[301].targets==0 and not data.quests[301].targetsComplete,'resumed foreign enumeration never fabricates local coverage')
local before=reads; Fixture.time=5
check(not ns.Discovery.Pump() and reads==before,'permanently foreign sources do not create location retries')
'''),
    ("Discovery: a large pending spawn list reuses the yielding Pump worker", r'''
record(301,100,{objectives={}})
local points={}
for i=1,10000 do points[i]={i/200,0} end
Fixture.locations.npc[10301]={[17]=points}
local context=ns.GetPlayerContext({})
Fixture.conversionFail[101]=true
ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get()); finishIndex()
Fixture.conversionFail[101]=nil; Fixture.time=5
local convert=C_Map.GetWorldPosFromMapPos
local conversions=0
C_Map.GetWorldPosFromMapPos=function(...) conversions=conversions+1; return convert(...) end
ns.Discovery.Pump()
check(conversions>0 and conversions<=128,'retry yields within a large pending coordinate list')
finishIndex()
local data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(not data.building and data.scanned==data.total and #data.quests[301].starters==10000,'resumed retry retains all recovered coordinates')
'''),
    ("Discovery: temporarily missing map information recovers on the same map", r'''
record(301,100)
local context=ns.GetPlayerContext({})
local getter=C_Map.GetMapInfo
C_Map.GetMapInfo=function(id) if id==101 then return nil end return getter(id) end
ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get()); finishIndex()
local data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(data.pendingLocationCount==1 and #data.opportunities==0,'unknown map information remains pending')
C_Map.GetMapInfo=getter; Fixture.time=5
check(ns.Discovery.Pump(),'map-information recovery requests a normal replan')
data=ns.Discovery.Collect(context,{}, {},ns.RouteOptions.Get())
check(action(data.opportunities,301,'pick_up') and data.pendingLocationCount==0,'same-map recovery clears pending state and restores the pickup')
'''),
    ("Planner: pending association locations cannot complete the map and recover automatically", r'''
FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
record(202,100,{objectives={[1]={{502,nil,0}}}}); Fixture.locations.npc[502]={[18]={{10,0}}}
record(301,100); Fixture.log={202}
local convert=C_Map.GetWorldPosFromMapPos
C_Map.GetWorldPosFromMapPos=function(map,position) if map==101 and position.x==.01 then return nil end return convert(map,position) end
local result=plan()
check(result.count==0 and not result.nextMapHint,'unresolved association locations cannot certify that the map is finished')
check(result.discovery.pendingLocationCount>0 and result.navigation.phase=='unavailable','public snapshot reports pending association locations')
Fixture.loggedIn=true; ns.StartRoute()
local sequence=ns.GetPlan({}).sequence
C_Map.GetWorldPosFromMapPos=convert; Fixture.time=5
ns.route.driver:GetScript('OnUpdate')(ns.route.driver,.2)
result=ns.GetPlan({})
check(result.sequence>sequence and result.pickupCount==1 and result.steps[1].questID==301,'normal driver automatically restores a local pickup after recovery')
check(result.discovery.pendingLocationCount==0,'successful recovery stops reporting pending locations')
'''),
    ("Planner: malformed database records preserve native route", r'''
record(201); record(301,100); Fixture.log={201}; Fixture.pois={[101]={NewPOI(101,.1,201)}}
local getter=FixtureDB.Quest.Get
FixtureDB.Quest.Get=function(id,field)
    if field=='objectives' then error('fixture malformed objectives') end
    return getter(id,field)
end
local result=plan()
check(result.count==1 and result.steps[1].questID==201 and result.steps[1].targetMode=='native_poi',
    'bad DB record leaves the native route usable')
check(not result.decision.recommendation and result.pickupCount==0,'bad record cannot invent a pickup')
'''),
    ("Map pins: periodic ticks never flash-hide active pins and right-click skip redraws immediately", r'''
record(301,300,{objectives={}}); Fixture.log={}
local result=plan(); setupMaps(); ns.WorldMap.Render(); ns.Minimap.Render()
local worldPin=ns.route.views[1].opportunities[1]
local miniPin=ns.route.minimapView.opportunities[1]
check(worldPin and worldPin:IsVisible() and miniPin and miniPin:IsVisible(),'advisory pins render on both maps')
local worldHideCount,miniHideCount=0,0
local realWorldHide,realMiniHide=worldPin.Hide,miniPin.Hide
function worldPin:Hide() worldHideCount=worldHideCount+1; return realWorldHide(self) end
function miniPin:Hide() miniHideCount=miniHideCount+1; return realMiniHide(self) end
for _=1,5 do ns.WorldMap.Render(); ns.Minimap.Render() end
check(worldHideCount==0 and miniHideCount==0,'periodic map ticks never Hide active pins and break RightButtonUp clicks')
worldPin:GetScript('OnClick')(worldPin)
check(ns.RouteOptions.Get().skipped[301],'right-click skips the quest')
check(not worldPin:IsVisible() and not miniPin:IsVisible(),'right-click skip hides both map pins on the same frame without waiting for the next tick')
'''),
    ("assoc-switch: shipped default is off, per character, and opening it builds the index", r'''
useShippedAssociationDefault()
record(201); record(301,100); Fixture.log={201}
local result=plan()
check(ns.RouteOptions.Get().associationEnabled==false and result.associationEnabled==false,
    'assoc-switch: a new character record starts with association off and the plan reports it')
check(result.pickupCount==0 and #result.discovery.opportunities==0 and not result.discovery.available
    and result.discovery.reason=='association_disabled' and not action(result.steps,301,'pick_up'),
    'assoc-switch: with the shipped default a nearby giver is neither indexed nor routed')
local oldName=UnitName; UnitName=function() return 'OtherCharacter' end
check(ns.RouteOptions.Get().associationEnabled==false,'assoc-switch: another character also starts off')
ns.RouteOptions.Get().associationEnabled=true; UnitName=oldName
check(ns.RouteOptions.Get().associationEnabled==false,'assoc-switch: characters do not share the switch')
local opened=ns.SetRouteOptions({associationEnabled=true})
check(opened.associationEnabled==true and opened.discovery.available and opened.discovery.building,
    'assoc-switch: turning it on starts a fresh index build')
result=plan()
check(result.associationEnabled==true and result.pickupCount==1 and result.steps[1].action=='pick_up','assoc-switch: once built the same fixture offers the pickup')
'''),
    ("assoc-switch: closed switch removes every association output of an otherwise identical fixture", r'''
Fixture.time=0
record(201); record(301,100); record(302,100); record(303,100); Fixture.log={201}
local requests=0
HaveQuestData=function(id) return id~=302 end
C_QuestLog.RequestLoadQuestByID=function() requests=requests+1 end
setupMaps(); ns.Util.Notify=function() end
local emits=watchEmits()
-- Reference: the same index, but both related quests are manually skipped, i.e. no pickup exists for the route.
ns.RouteOptions.Get().skipped[301],ns.RouteOptions.Get().skipped[302],ns.RouteOptions.Get().skipped[303]=true,true,true
local reference=plan()
check(reference.pickupCount==0 and reference.count==1,'assoc-switch: reference route has no available related quests')
local referenceKeys=stepKeys(reference)
ns.RouteOptions.Get().skipped[301],ns.RouteOptions.Get().skipped[302],ns.RouteOptions.Get().skipped[303]=nil,nil,nil
requests=0
local on=plan()
check(action(on.discovery.opportunities,301,'pick_up') and on.pickupCount==1 and on.steps[1].action=='pick_up' and on.decision.applied,
    'assoc-switch: control fixture offers and applies a pickup while open')
check(on.discovery.pendingCount==1 and requests>=1 and ns.route.associationQuestIDs and ns.route.nextAssociationCheck,
    'assoc-switch: control fixture requests uncached metadata and arms the retry while open')
ns.RouteOptions.Get().switchNotice=true; ns.route.lastNotice=nil; ns.route.associationNotice=nil
ns.Planner.Rebuild('QUEST_LOG_UPDATE')
check(countOf(emits,'route.association')>=1,'assoc-switch: control fixture emits route.association while open')
ns.WorldMap.Render(); ns.Minimap.Render()
check(visibleOpportunityPins()>0,'assoc-switch: control fixture draws pickup markers while open')
requests=0; for index=#emits,1,-1 do emits[index]=nil end
local off=ns.SetRouteOptions({associationEnabled=false})
check(off.ok and off.associationEnabled==false and off.reason=='options_changed','assoc-switch: closing applies through options_changed')
check(#off.discovery.opportunities==0 and #off.discovery.blocked==0 and #off.discovery.carriedItems==0
    and #off.discovery.announcedOpportunities==0 and off.discovery.opportunityTotal==0 and off.discovery.blockedTotal==0,
    'assoc-switch: closed discovery lists are empty')
check(off.discovery.available==false and off.discovery.building==false and off.discovery.reason=='association_disabled'
    and off.discovery.pendingCount==0 and off.discovery.pendingLocationCount==0 and off.discovery.itemGate.required==0,
    'assoc-switch: closed discovery is inactive, not building and has nothing pending')
check(off.decision.available==false and off.decision.reason=='association_disabled' and not off.decision.recommendation and not off.decision.applied,
    'assoc-switch: closed decision is unavailable with the disabled reason')
check(off.pickupCount==0 and not action(off.steps,301,'pick_up') and not action(off.steps,301,'start_item'),'assoc-switch: closed route has no pickup steps')
check(stepKeys(off)==referenceKeys,'assoc-switch: closed steps equal the route of a fixture without related quests')
check(ns.route.associationQuestIDs==nil and ns.route.nextAssociationCheck==nil,'assoc-switch: closed switch clears the metadata listener and the retry timer')
check(ns.Discovery.Pump()==false,'assoc-switch: closed Pump never reports progress')
Fixture.loggedIn=true; ns.StartRoute()
local driver=ns.route.driver
ns.RouteOptions.Get().switchNotice=true; ns.route.lastNotice=nil
for tick=1,6 do
    Fixture.time=Fixture.time+6; Fixture.playerX=tick*.0002
    driver:GetScript('OnEvent')(driver,'QUEST_LOG_UPDATE')
    driver:GetScript('OnUpdate')(driver,.2)
    ns.Planner.Rebuild('BAG_UPDATE_DELAYED')
end
ns.WorldMap.Render(); ns.Minimap.Render()
check(requests==0,'assoc-switch: closed switch never calls RequestLoadQuestByID')
check(countOf(emits,'route.association')==0,'assoc-switch: closed switch never emits route.association')
check(visibleOpportunityPins()==0,'assoc-switch: closed switch draws no pickup markers')
check(ns.GetPlan({}).pickupCount==0 and ns.route.nextAssociationCheck==nil,'assoc-switch: closed switch stays quiet through ticks and events')
'''),
    ("assoc-switch: closing releases the half-built index and reopening restarts and finishes it", r'''
Fixture.time=0
for id=301,430 do record(id,100,{objectives={}}) end
Fixture.log={}
ns.RouteOptions.Get().switchNotice=false
Fixture.loggedIn=true; ns.StartRoute()
local driver=ns.route.driver
local first=ns.Replan({})
check(first.discovery.building and first.discovery.scanned==0 and first.discovery.total>=130,'assoc-switch: control index starts empty while open')
check(ns.Discovery.Pump()==false and ns.route.plan.discovery.scanned>0 and ns.route.plan.discovery.scanned<ns.route.plan.discovery.total,
    'assoc-switch: control Pump advances a partial index while open')
local off=ns.SetRouteOptions({associationEnabled=false})
check(off.discovery.building==false and off.discovery.scanned==0,'assoc-switch: closing hides the partial build')
local progressed=false
for _=1,60 do if ns.Discovery.Pump() then progressed=true end end
check(not progressed,'assoc-switch: closed Pump never completes the old build')
local reopened=ns.SetRouteOptions({associationEnabled=true})
check(reopened.discovery.building and reopened.discovery.scanned==0,'assoc-switch: reopening rebuilds from zero because the cache was released')
local reasons={}
for _=1,200 do
    Fixture.time=Fixture.time+.2; driver:GetScript('OnUpdate')(driver,.2)
    reasons[ns.route.plan.reason]=true
    if not ns.route.plan.discovery.building then break end
end
local done=ns.GetPlan({})
check(reasons.association_index_ready and done.discovery.available and not done.discovery.building and done.discovery.scanned==done.discovery.total,
    'assoc-switch: reopened index finishes through association_index_ready')
check(#done.discovery.opportunities>0 and done.discovery.opportunityTotal>0,'assoc-switch: opportunities return after the rebuilt index')
'''),
    ("assoc-switch: closing forgets announcements so reopening cannot replay them", r'''
record(301,100,{objectives={}}); record(302,200,{objectives={}})
local result=plan(); setupMaps()
ns.Util.Notify=function() end
ns.RouteOptions.Get().switchNotice=true; result.reason='player_moved'
ns.Decision.Notify(result,nil,ns.RouteOptions.Get(),30)
check(ns.route.announcedOpportunities.items['301:pick_up:0'] and ns.route.associationNotice,'assoc-switch: control notice remembers its pickup while open')
Fixture.playerX=.5; Fixture.time=100
result=ns.Planner.Rebuild('player_moved'); ns.WorldMap.Render(); ns.Minimap.Render()
check(#result.discovery.announcedOpportunities==1 and visibleOpportunityPins()>0,'assoc-switch: control history stays visible away from the giver while open')
local off=ns.SetRouteOptions({associationEnabled=false}); ns.WorldMap.Render(); ns.Minimap.Render()
check(ns.route.announcedOpportunities==nil and ns.route.associationNotice==nil and #off.discovery.announcedOpportunities==0,
    'assoc-switch: closing clears the announcement history and last association notice')
check(visibleOpportunityPins()==0,'assoc-switch: closing hides the remembered markers at once')
local on=ns.SetRouteOptions({associationEnabled=true}); if on.discovery.building then finishIndex() end
on=ns.Replan({})
check(on.discovery.available and not on.discovery.building and #on.discovery.announcedOpportunities==0
    and ns.route.announcedOpportunities==nil and ns.route.associationNotice==nil,'assoc-switch: reopening does not bring back the old notice')
ns.WorldMap.Render(); ns.Minimap.Render()
check(visibleOpportunityPins()==0,'assoc-switch: reopened maps show no stale marker')
'''),
    ("assoc-switch: switching during rebuild back-off still attempts one immediate rebuild", r'''
record(201); Fixture.log={201}; Fixture.pois={[101]={NewPOI(101,.1,201)}}
local planned=plan()
check(planned.associationEnabled==true,'assoc-switch: control plan starts with association open')
local scan,failScan,scanCalls=C_QuestLog.GetQuestsOnMap,false,0
C_QuestLog.GetQuestsOnMap=function(id)
    scanCalls=scanCalls+1
    if failScan then error('fixture scan failure') end
    return scan(id)
end
local realPrint=print; print=function() end
failScan=true; ns.route.nextRebuildRetry=nil
ns.Replan({})
local retry=ns.route.nextRebuildRetry
check(retry and GetTime()<retry,'assoc-switch: a failing manual rebuild arms the back-off')
local base,sequence=scanCalls,ns.route.sequence
ns.Planner.Rebuild('player_moved')
check(scanCalls==base,'assoc-switch: control automatic reason is held back by the back-off')
ns.SetRouteOptions({associationEnabled=false})
check(scanCalls==base+1 and ns.route.sequence==sequence and ns.RouteOptions.Get().associationEnabled==false,
    'assoc-switch: the switch gets one immediate attempt inside the back-off and keeps the old plan on failure')
failScan=false
check(ns.route.nextRebuildRetry and GetTime()<ns.route.nextRebuildRetry,'assoc-switch: the retry window is still open')
local result=ns.SetRouteOptions({associationEnabled=false})
check(result.associationEnabled==false and ns.route.sequence==sequence+1 and ns.route.nextRebuildRetry==nil
    and result.discovery.reason=='association_disabled','assoc-switch: the next switch inside the window rebuilds at once and clears the back-off')
print=realPrint; C_QuestLog.GetQuestsOnMap=scan
'''),
    ("assoc-switch: closed switch leaves the map hint, analysis and unit tasks alone", r'''
FixtureDB.Support.Get=function() return {private={areaIdToUiMapId={[17]=101,[18]=102}}} end
record(202,100,{objectives={[1]={{502,nil,0}}}}); Fixture.locations.npc[502]={[18]={{10,0}}}
Fixture.log={202}
local open=ns.Replan({})
check(open.count==0 and open.discovery.building and not open.nextMapHint,'assoc-switch: control hint waits for the index while open')
local closed=ns.SetRouteOptions({associationEnabled=false})
check(closed.count==0 and closed.nextMapHint and closed.nextMapHint.mapID==102 and not closed.discovery.building,
    'assoc-switch: closed switch never blocks the next-map hint on the index')
local analysis=ns.AnalyzeQuests({})
check(analysis.ok,'assoc-switch: quest value analysis still succeeds while closed')
local printed={}; local realPrint=print; print=function(text) printed[#printed+1]=text end
SlashCmdList.QUESTROUTE('why'); print=realPrint
local why=table.concat(printed,'\n')
check(why:find('任务联想已关闭',1,true) and why:find('/questroute association on',1,true)
    and why:find('当前地图已无可做任务',1,true) and not why:find('任务关联索引建立中',1,true),
    'assoc-switch: why reports the switch and still prints the next-map hint')
'''),
    ("assoc-switch: nameplates and unit tasks give the same answer open and closed", r'''
record(201); Fixture.log={201}
Fixture.units={target={id=501},nameplate1={id=501}}
local plate=CreateFrame('Frame'); plate.UnitFrame={unit='nameplate1'}; Fixture.plates={plate}
Fixture.loggedIn=true; ns.StartRoute()
local on=plan(); ns.Nameplates.Render()
local openUnit=ns.GetUnitTasks({unit='target'})
check(openUnit.ok and openUnit.npcID==501 and openUnit.needed and ns.route.nameplateView.markers[plate]:IsVisible(),
    'assoc-switch: control unit task and nameplate resolve while open')
local off=ns.SetRouteOptions({associationEnabled=false}); ns.Nameplates.Render()
local closedUnit=ns.GetUnitTasks({unit='target'})
check(closedUnit.ok and closedUnit.npcID==openUnit.npcID and closedUnit.state==openUnit.state and closedUnit.needed==openUnit.needed
    and closedUnit.neededCount==openUnit.neededCount and closedUnit.label==openUnit.label,'assoc-switch: closed switch keeps get_unit_tasks unchanged')
check(ns.route.nameplateView.markers[plate]:IsVisible() and off.nameplates.enabled==on.nameplates.enabled
    and off.nameplates.unresolvedQuestCount==on.nameplates.unresolvedQuestCount,'assoc-switch: closed switch keeps nameplate markers and their plan block unchanged')
'''),
    ("assoc-switch: closed switch ignores NPC and dialogue observations and reopens them", r'''
record(97287,100,{name='精明的谈判',startedBy={[1]={2410}}}); place('npc',2410,100)
FixtureDB.Npc.questStarts=function(id) if id==2410 then return {97287} end end
Fixture.units.target={id=2410}
UnitIsInInteractRange=function() return true end
UnitIsInteractable=function() return false end
UnitIsDeadOrGhost=function() return false end
ns.SetRouteOptions({associationEnabled=false})
check(ns.Discovery.ObserveUnits()==false and ns.route.pickupChecks==nil,'assoc-switch: closed ObserveUnits records nothing and reports no change')
Fixture.loggedIn=true; ns.StartRoute()
local sequence=ns.GetPlan({}).sequence
Fixture.time=1; ns.route.driver:GetScript('OnUpdate')(ns.route.driver,.2)
check(ns.GetPlan({}).reason~='pickup_unit_changed' and ns.route.pickupChecks==nil,'assoc-switch: the driver tick cannot raise pickup_unit_changed while closed')
gossip(2410,{{questID=97287}})
check(ns.route.gossip==nil and ns.route.pickupChecks==nil,'assoc-switch: closed ObserveInteraction records no dialogue')
ns.SetRouteOptions({associationEnabled=true})
check(ns.Discovery.ObserveUnits()==true and ns.route.pickupChecks[2410],'assoc-switch: reopened ObserveUnits records the restriction')
gossip(2410,{{questID=97287}})
check(ns.route.gossip and ns.route.gossip.offered[97287],'assoc-switch: reopened ObserveInteraction records the dialogue')
'''),
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--addon", type=Path, default=DEFAULT_ADDON,
                        help="addon directory, .toc manifest, or .lua file")
    args = parser.parse_args()
    try:
        sources = read_addon_sources(args.addon)
    except (OSError, ValueError) as error:
        parser.error(str(error))

    failures = []
    passed = 0
    for label, source in CASES:
        runtime = LuaRuntime(unpack_returned_tuples=True)
        try:
            runtime.execute(SETUP)
            runtime.execute(FIXTURE)
            namespace = runtime.table()
            execute_addon(runtime, sources, namespace)
            passed += runtime.execute(HELPERS + source + "\nreturn checks", namespace, name=label)
            print(f"PASS: {label}")
        except Exception as error:
            failures.append(label)
            print(f"FAIL: {label}\n{error}")
    print(f"{'FAIL' if failures else 'PASS'}: {len(CASES) - len(failures)}/{len(CASES)} scenarios; "
          f"{passed} checks in passing scenarios; isolated Lua 5.1; {len(sources)} Lua file(s)")
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
