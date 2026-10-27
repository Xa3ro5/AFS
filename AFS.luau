-- Embedded source lets an active dungeon journey continue without another remote loader.
local AFS_SOURCE = [====[
-- AFS: quests, training and PvE. Evidence: research/ui-training-2026-10-19.md.
-- Executor client; no MCP dependency. All automation starts OFF, including saved toggles.
local selfSource,teleportResume=...
local env = type(getgenv) == "function" and getgenv() or _G
if env.AFS and env.AFS.Unload then env.AFS.Unload() end
if not game:IsLoaded() then game.Loaded:Wait() end
local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local CS = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local player = Players.LocalPlayer
if game.GameId~=10321202755 or not player or not RS:FindFirstChild("Generated") then
    warn("[AFS] Supported AFS client is not loaded.") return
end

-- Keep the existing SmugLib loader and its authentication gate.
local okLibrary, Library = pcall(function()
    local source = game:HttpGet("https://raw.githubusercontent.com/Xa3ro5/LifeIsRoblox/refs/heads/main/SmugLibCoreV2.lua", true)
    local fn, err = loadstring(source)
    assert(fn, err)
    return fn()
end)
if not okLibrary or type(Library) ~= "table" then
    warn("[AFS] SmugLib: " .. tostring(Library)) return
end

local function path(root, name)
    for segment in name:gmatch("[^.]+") do
        root = root and root:FindFirstChild(segment)
    end
    return root
end
local function module(name)
    local object = path(RS, name)
    if not object or not object:IsA("ModuleScript") then return nil end
    local ok, result = pcall(require, object)
    if ok then return result end
end
local Events = module("Generated._ClientEvents")
if not Events or not Events.equipStat or not Events.requestTrainingZones then
    warn("[AFS] Required game network interface is unavailable.") return
end
local Data = module("Client.Controllers.DataController") -- optional: unavailable in some executors
local cooldowns = module("Dictionaries.TrainingCooldowns") or {}
local statNames = {"Strength", "Durability", "Chakra", "Sword", "Speed", "Agility"}
local activeStats = {Strength=true, Durability=true, Chakra=true, Sword=true}
local config = {stat="Strength", cycle=false, cycleSeconds=30, bestZone=true,
    moveMode="Game Teleport", tweenSpeed=100, timeout=12, interval=1.1,
    speed=60, jump=60, fov=80, routeRadius=1000, resumeRespawn=true,
    bosses={}, farmBosses=false, mob="Thug", weapon="Sword", behindDistance=3, behindHeight=1, specialRotateSeconds=10, bossWeapon="Sword", powerMode="All Unlocked", specialMode="Rotate All", castPowers=true, castSpecials=true, castBasic=true, autoTransform=true, castSpecialM1=true, mobStall=90, fruit="All Fruits", placeCategory="All Locations", dungeonDifficulty="Easy"}
local flags = {IndexRewards=false,DailyRewards=false,AutoDungeon=false, AutoQuest=false, TargetMainQuest=false, QuestScan=false, BossFarm=false, KillAllPlayers=false, KillSelectedPlayer=false, FruitSnipe=false, AutoJoinBoss=false, MobFarm=false, Train=false, Rewards=false, Noclip=false, Speed=false, Jump=false,
    InfiniteJump=false, Fly=false, AntiAFK=false, Fullbright=false, FOV=false, ESP=false}
local state = {alive=true, ready=false, generation=0, action="Idle", target="—",
    result="—", waiting="—", error="—", zones={}, places={}, requests={}, claimed={},
    confirmed=0, rejected=0, trainStat=nil, trainingSnapshot=nil, move=nil}
local api = {Config=config, Flags=flags, Version="2026-10-25.1"}
env.AFS = api
local connections, toggleControls, highlights = {}, {}, {}
local window, uiRoot, zoneDropdown, placeDropdown, statusLabel, statsLabel, questLabel, mobDropdown, bossSection, mobLabel, placeLabel, fruitLabel, bossJoinLabel, fruitDropdown
local selectedZone, selectedPlace, savedPosition
local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(connections, connection)
    return connection
end
local function notify(text)
    if window then window:Notify(tostring(text), 3) end
end
local function character()
    local c = player.Character
    local h = c and c:FindFirstChildOfClass("Humanoid")
    local r = c and c:FindFirstChild("HumanoidRootPart")
    if h and r and h.Health > 0 then return c, h, r end
end
local function valid(token)
    return state.alive and token == state.generation
end
local function waitFor(seconds, token)
    local deadline = os.clock() + seconds
    repeat
        if not valid(token) then return false end
        task.wait(math.min(0.1, math.max(0, deadline-os.clock())))
    until os.clock() >= deadline
    return valid(token)
end
local function fire(name, ...)
    local event = Events[name]
    if not event or not event.fire then return false, "Action unavailable: "..name end
    local args = table.pack(...)
    return pcall(function()
        event.fire(table.unpack(args, 1, args.n))
        -- Generated fire() buffers messages; a fresh executor require needs an explicit flush.
        if Events.sendEvents and not state.eventBatch then Events.sendEvents() end
    end)
end
-- A timed-out request retains its slot until it actually returns. No overlapping retries.
local function request(name, token, ...)
    if not valid(token) then return false, "Cancelled" end
    if state.requests[name] then return false, "Previous request pending: "..name end
    local event = Events[name]
    if not event or not event.call then return false, "Action unavailable: "..name end
    local pending = {done=false}
    state.requests[name] = pending
    local args = table.pack(...)
    task.spawn(function()
        if not valid(token) then
            pending.values=table.pack(false,"Cancelled before dispatch")
        else
            pending.values = table.pack(pcall(event.call, table.unpack(args, 1, args.n)))
        end
        pending.done = true
        if state.requests[name] == pending then state.requests[name] = nil end
    end)
    local deadline = os.clock() + config.timeout
    while not pending.done do
        if not valid(token) then return false, "Cancelled; sent request may still finish" end
        if os.clock() >= deadline then return false, "Timeout: "..name end
        task.wait(0.05)
    end
    if not valid(token) then return false, "Cancelled" end
    return table.unpack(pending.values, 1, pending.values.n)
end

local suffixes = {K=1e3,M=1e6,B=1e9,T=1e12,Qd=1e15,Qi=1e18,Sx=1e21,Sp=1e24,Oc=1e27,No=1e30,Dc=1e33}
local function parseDisplay(text)
    text = tostring(text):gsub("<[^>]*>", ""):gsub(",", ""):gsub("%s", "")
    local number, suffix = text:match("^(%d+%.?%d*)(%a*)$")
    number = tonumber(number)
    local multiplier = suffix == "" and 1 or suffixes[suffix]
    if not number or not multiplier then return nil end
    local digits = text:match("%.(%d+)")
    local quantum = multiplier / 10^(digits and #digits or 0)
    -- UI is rounded. Use a conservative lower bound for eligibility, never overestimate.
    return math.max(0, number*multiplier - (suffix ~= "" and quantum or 0)), number*multiplier
end
local Adapter = {}
function Adapter.stats()
    if Data then
        local ok, stats = pcall(Data.Get, Data, "Stats")
        if ok and type(stats) == "table" then
            local result = {}
            for _, name in ipairs(statNames) do
                local entry = stats[name]
                if type(entry) == "table" and type(entry.Stat) == "number" then result[name] = entry.Stat end
            end
            if result.Strength then return result, "DataController" end
        end
    end
    local list = path(player.PlayerGui, "Main.Pages.Stats.Page.Main.List")
    local tracker = path(player.PlayerGui, "Main.HUD.StatTracker")
    local result = {}
    for _, name in ipairs(statNames) do
        local item = list and list:FindFirstChild(name)
        local amount = item and item:FindFirstChild("UpgradeAmount")
        if amount then result[name] = parseDisplay(amount.Text) end
        local live = tracker and tracker:FindFirstChild(name)
        local top = live and live:FindFirstChild("Top")
        if live and live.Visible and top then
            local current = parseDisplay(top.Text)
            if current then result[name] = current end
        end
    end
    local mirror=api.Replica and api.Replica.data and api.Replica.data.Stats
    if mirror then for name,entry in pairs(mirror) do
        if type(entry)=="table" and type(entry.Stat)=="number" then result[name]=entry.Stat end
    end end
    return result, mirror and "Replication + UI" or "UI (rounded; conservative bounds)"
end
function Adapter.questObjectives()
    local list=path(player.PlayerGui,"Main.HUD.QuestTracker.Main.Holder.List")
    local objectives={}
    if not list then return objectives end
    for _,row in ipairs(list:GetChildren()) do
        if row:IsA("GuiObject") and row.Visible then
            local title=path(row,"Main.Title")
            local progress=path(row,"QuestBar.QuestBarProgressAmount")
            if title and progress and (title.Text:match("^Train ") or title.Text:match("^Gain ")) then
                local stat=title.Text:match("(%a+)%s*$")
                local percent=tonumber(progress.Text:match("%((%d+)%%%s*%)"))
                if table.find(statNames,stat) and percent and percent<100 then
                    table.insert(objectives,{stat=stat,title=title.Text,progress=progress.Text,
                        order=row.LayoutOrder,identity=row.Name})
                end
            end
        end
    end
    table.sort(objectives,function(a,b) return a.order<b.order or (a.order==b.order and a.identity<b.identity) end)
    return objectives
end
function Adapter.eligible(zone, stats)
    for _, requirement in ipairs(zone.requirements or {}) do
        local value = stats[requirement.statType]
        if type(value) ~= "number" then return false, "Stat unavailable: "..requirement.statType end
        if value < requirement.value then return false, "Requirement not met: "..requirement.statType end
    end
    return true
end
function Adapter.best(stat)
    local stats = Adapter.stats()
    local best, score
    for _, zone in ipairs(state.zones) do
        if Adapter.eligible(zone, stats) then
            for _, reward in ipairs(zone.rewards or {}) do
                if reward.statType == stat and reward.rewardType == "Multiply" then
                    if not score or reward.amount > score or (reward.amount == score and zone.name < best.name) then
                        best, score = zone, reward.amount
                    end
                end
            end
        end
    end
    return best, score
end
-- Server replicas, not local damage prediction. Despawn alone is not death.
local mobs={catalog={},entities={},dead={},removed={},completed={},acceptedQuest=nil,target=nil,
    kills=0,quests=0,labels={},callbacks={},observers={},bootstrapping=true,history={},lastLabels=nil,
    bloodMoon=workspace:GetAttribute("bloodMoonEndsAt")~=nil,eventBatch=nil,eventRoute=nil,eventRouteIndex=0}
local descriptions=module("Descriptions.EntityDescriptions")
local repeatables=module("Client.Configs.RepeatableQuestsConfig")
local questDefinitions=module("Dictionaries.Quests")
if descriptions then
    for id,d in pairs(descriptions.descriptions or {}) do
        if id~="Default" then mobs.catalog[id]={id=id,name=d.name or id,maxHP=d.maxHealth,isBoss=d.isBoss==true} end
    end
end
if repeatables and questDefinitions then
    for area,d in pairs(repeatables) do for _,id in ipairs(d.quests or {}) do
        local ok,q=pcall(questDefinitions.Get,questDefinitions,id)
        if ok and q then for _,o in ipairs(q.Objectives or {}) do
            if o.Type=="DefeatMob" and mobs.catalog[o.MobName] then
                mobs.catalog[o.MobName].quest={id=id,area=area,npc=d.npcName,amount=o.Amount}
            end
        end end
    end end
end
-- Only server replicas / actual UI rows enter this cache. Missing data stays unknown.
local quests={catalog={},known={},blocked={},scanResult={},scanIndex=0,scanQueue=nil,claimed=0,pending={},nextAction={},current=nil}
local replica={data={},hydrated=false}
local function applyPatch(old,patch)
    if type(patch)~="table" then return patch end
    if patch.__none=="__none" then return nil end
    local result=type(old)=="table" and table.clone(old) or {}
    for k,v in pairs(patch) do
        if type(k)=="string" and tonumber(k) then k=tonumber(k) end
        result[k]=applyPatch(result[k],v)
    end
    return result
end
local function dataAt(key)
    if Data then local ok,v=pcall(Data.Get,Data,key) if ok and v~=nil then return v end end
    local v=replica.data
    for part in key:gmatch("[^.]+") do v=type(v)=="table" and v[part] or nil end
    return v
end
local function indexQuests(t,prefix)
    for k,v in pairs(t) do
        if type(v)=="table" then
            local id=prefix=="" and tostring(k) or prefix.."."..tostring(k)
            if v.Objectives then quests.catalog[id]=v else indexQuests(v,id) end
        end
    end
end
if questDefinitions then
    local ok,all=pcall(questDefinitions.GetAll,questDefinitions)
    if ok and type(all)=="table" then indexQuests(all,"") end
end
local function refreshQuestState()
    if quests.refreshedAt and os.clock()-quests.refreshedAt<0.25 then return quests.order or {} end
    local tracking=dataAt("Quests.Tracking")
    local daily=dataAt("Quests.Daily")
    local function absorb(bucket)
        if type(bucket)~="table" then return end
        for id,q in pairs(bucket) do if type(q)=="table" and quests.catalog[id] then quests.known[id]=q end end
    end
    absorb(tracking) absorb(daily)
    for _,bucket in pairs(dataAt("Battlepass.Quests") or {}) do absorb(bucket) end
    local scroll=path(player.PlayerGui,"Main.Pages.Quests.Page.Main.Bottom.QuestScroll")
    if scroll then for _,row in ipairs(scroll:GetChildren()) do
        local id=row.Name
        local definition=quests.catalog[id]
        local info=definition and path(row,"Main.Info")
        if definition and row:IsA("GuiObject") and row.Visible and info then
            local q=quests.known[id] or {Objectives={}}
            q.Objectives=q.Objectives or {}
            local bars={}
            for _,bar in ipairs(info:GetChildren()) do
                if bar.Name=="QuestBar" and bar:IsA("GuiObject") then table.insert(bars,bar) end
            end
            table.sort(bars,function(a,b) return a.LayoutOrder<b.LayoutOrder end)
            for index,bar in ipairs(bars) do
                local label=bar:FindFirstChild("QuestBarProgressAmount")
                local text=label and label.Text:gsub("<[^>]*>","")
                local percent=text and tonumber(text:match("%((%d+)%%%s*%)"))
                if percent and definition.Objectives[index] then
                    local o=q.Objectives[index] or {}
                    o.uiIncomplete=percent<100 o.uiComplete=percent==100
                    q.Objectives[index]=o
                end
            end
            local follow=path(row,"Main.RewardsBox.FollowButton.Title")
            if follow then
                q.uiFollowed=follow.Text=="Unfollow"
                if follow.Text=="Claim" or follow.Text=="Redeem" then q.Completed=true end
            end
            quests.known[id]=q
        end
    end end
    local list=path(player.PlayerGui,"Main.HUD.QuestTracker.Main.Holder.List")
    local order={}
    if list then for _,row in ipairs(list:GetChildren()) do
        if row:IsA("GuiObject") and row.Visible then
            local id,index=row.Name:match("^Progress_(.+)_(%d+)$")
            local definition=id and quests.catalog[id]
            local amount=path(row,"QuestBar.QuestBarProgressAmount")
            if definition and amount then
                index=tonumber(index)
                local q=quests.known[id] or {Objectives={}}
                q.Objectives=q.Objectives or {}
                local text=amount.Text:gsub("<[^>]*>","")
                local percent=tonumber(text:match("%((%d+)%%%s*%)"))
                if percent then
                    local o=q.Objectives[index] or {}
                    o.uiIncomplete=percent<100 o.uiComplete=percent==100 q.Objectives[index]=o
                end
                quests.known[id]=q order[id]=math.min(order[id] or math.huge,row.LayoutOrder)
            end
        end
    end end
    quests.refreshedAt=os.clock() quests.order=order
    return order
end
local function objectivePending(id,index)
    local q=quests.known[id]
    if not q or q.Redeemed or q.Completed then return false end
    local definition=quests.catalog[id] and quests.catalog[id].Objectives[index]
    if not definition then return false end
    local o=q.Objectives and (q.Objectives[index] or q.Objectives[tostring(index)])
    if not o then return true end
    if o.Completed==true or o.uiComplete==true then return false end
    if type(o.Progress)=="number" and o.Progress>=(o.Goal or definition.Amount or math.huge) then return false end
    return true
end
local function questAllowed(id)
    return not flags.TargetMainQuest or id:match("^Main%.")~=nil
end
local function questQueue()
    local order=refreshQuestState()
    local following=dataAt("Quests.Following") or {}
    local list={}
    for id,q in pairs(quests.known) do
        if questAllowed(id) and not id:match("^Repeatable%.") and not q.Redeemed then
            table.insert(list,{id=id,data=q,order=order[id] or ((following[id] or q.uiFollowed) and 10000 or 20000)})
        end
    end
    table.sort(list,function(a,b) return a.order<b.order or (a.order==b.order and a.id<b.id) end)
    return list
end
api.Replica=replica
api.Quests=quests
api.QuestQueue=questQueue

local function bloodMoonOverride()
    local selected=mobs.catalog[config.mob]
    return not config.farmBosses and mobs.bloodMoon and selected~=nil and not selected.isBoss
end
Adapter.bloodMoonOverride=bloodMoonOverride
local function observe(name,callback)
    if not Events[name] or not Events[name].setCallback then return end
    local listeners=mobs.observers[name]
    if listeners then table.insert(listeners,callback) return end
    listeners={callback} mobs.observers[name]=listeners
    -- Generated setters replace the previous callback. Register once per event,
    -- then fan out to registry, defense and aim consumers without losing any.
    table.insert(mobs.callbacks,Events[name].setCallback(function(...)
        if not state.alive or mobs.bootstrapping then return end
        for _,listener in ipairs(listeners) do
            local ok,err=pcall(listener,...)
            if not ok then state.error=name..": "..tostring(err) end
        end
    end))
end
-- Keep identity across streaming re-entry, but never reuse a confirmed dead encounter.
function mobs.ResolveModel(target)
    local model=target and target.model
    if model and model:IsDescendantOf(workspace) and (target.player or model:GetAttribute("entityId")==target.id) then return model end
    if not target then return end
    target.model=nil
    if os.clock()<(target.nextResolve or 0) then return end
    target.nextResolve=os.clock()+0.2
    local folder=workspace:FindFirstChild("ClientEntities")
    for _,candidate in ipairs(folder and folder:GetChildren() or {}) do
        if candidate:GetAttribute("entityId")==target.id then target.model=candidate return candidate end
    end
end
function mobs.IsLive(target)
    if not target or target.dead or mobs.dead[target.id] or (target.hp and target.hp<=0) then return false end
    if target.player then
        local h=target.model and target.model:FindFirstChildOfClass("Humanoid")
        return target.player.Character==target.model and h~=nil and h.Health>0
            and (not Adapter.playerEligible or Adapter.playerEligible(target.player,target.model))
    end
    if mobs.entities[target.id]~=target or mobs.removed[target.id] then return false end
    if Adapter.encounterAlive and not Adapter.encounterAlive(target) then return false end
    local model=mobs.ResolveModel(target)
    if model then
        local hp=model:GetAttribute("Health")
        return type(hp)~="number" or hp>0
    end
    -- A recent server packet permits discovery/travel, never casting into an absent model.
    return os.clock()-(target.seenAt or 0)<2
end
function mobs.CanAttack(target)
    if not mobs.IsLive(target) then return false end
    local model=mobs.ResolveModel(target)
    if not model or not model:FindFirstChildWhichIsA("BasePart",true) then return false end
    if Adapter.combatInArena and not Adapter.combatInArena(target) then return false end
    return true
end
function mobs.MarkDead(id)
    mobs.dead[id]=true
    local entry=mobs.entities[id]
    if entry then entry.hp=0 entry.dead=true end
    local target=mobs.target
    if target and target.id==id and not target.player then
        target.hp=0 target.dead=true
        if not target.deathHandled then
            target.deathHandled=true mobs.kills+=1
            if mobs.bossRun and mobs.bossRun.selected[target.name] then mobs.bossRun.served[target.name]=true end
            table.insert(mobs.history,{event="death",id=id,time=os.clock()})
            if #mobs.history>60 then table.remove(mobs.history,1) end
            state.result="Death confirmed: "..(mobs.catalog[target.name] or {name=target.name}).name.." #"..id
        end
        if mobs.ReleaseTarget then mobs.ReleaseTarget(target) end
    end
end
observe("spawnEntities",function(ids,names,models,positions,rotations,healths,maxHealths)
    for i,id in ipairs(ids) do
        local entry=mobs.entities[id]
        local pinned=mobs.target
        if not entry and pinned and pinned.id==id and not pinned.dead then entry=pinned end
        if not entry or entry.dead or entry.name~=names[i] then entry={id=id,name=names[i]} end
        mobs.dead[id]=nil mobs.removed[id]=nil
        entry.position=positions[i] entry.hp=healths[i] entry.maxHP=maxHealths[i] entry.rotation=rotations[i]
        entry.replica=true entry.model=nil entry.seenAt=os.clock()
        mobs.entities[id]=entry
        if entry.hp<=0 then mobs.MarkDead(id) end
    end
end)
observe("replicateEntities",function(data)
    for i,id in ipairs(data.ids) do
        local mob=mobs.entities[id] if mob then mob.position=data.positions[i] mob.rotation=data.rotations and data.rotations[i] or mob.rotation mob.seenAt=os.clock() end
    end
end)
observe("replicateEntityHealths",function(ids,healths)
    for i,id in ipairs(ids) do
        local mob=mobs.entities[id] if mob then mob.hp=healths[i] mob.seenAt=os.clock() end
        if healths[i]<=0 then mobs.MarkDead(id) end
    end
end)
observe("replicateEntityMaxHealths",function(ids,healths)
    for i,id in ipairs(ids) do local mob=mobs.entities[id] if mob then mob.maxHP=healths[i] end end
end)
observe("despawnEntities",function(ids,deathIds)
    for _,id in ipairs(deathIds or {}) do mobs.MarkDead(id) end
    for _,id in ipairs(ids) do
        mobs.entities[id]=nil mobs.removed[id]=true
        if mobs.target and mobs.target.id==id and mobs.ReleaseTarget then mobs.ReleaseTarget(mobs.target) end
    end
end)
observe("notifyQuestCompleted",function(id)
    if quests.catalog[id] then
        quests.known[id]=quests.known[id] or {Objectives={}}
        quests.known[id].Completed=true
    end
    if not mobs.bootstrapping and id==mobs.acceptedQuest then mobs.completed[id]=true end
end)
observe("autoQuestEvent",function(info)
    if type(info)~="table" then return end
    local id=info.questPath
    if info.kind=="Completed" and id and quests.catalog[id] then
        quests.known[id]=quests.known[id] or {Objectives={}}
        quests.known[id].Completed=true quests.known[id].Redeemed=true
        state.result="Quest completion confirmed: "..id
    end
    if info.kind=="Restarted" and id then mobs.completed[id]=nil end
    local nextId=info.nextQuestPath
    if (info.kind=="NextStarted" or info.kind=="Restarted") and nextId and quests.catalog[nextId] then
        quests.known[nextId]=quests.known[nextId] or {Objectives={}}
    end
end)
local function scanMobs()
    local folder=workspace:FindFirstChild("ClientEntities")
    if not folder then return end
    for _,model in ipairs(folder:GetChildren()) do
        local id=model:GetAttribute("entityId")
        local hp=model:GetAttribute("Health")
        if id and type(hp)=="number" and not mobs.dead[id] and not mobs.removed[id] then
            local entry=mobs.entities[id]
            if not entry then
                entry={id=id,name=model.Name,hp=hp,maxHP=model:GetAttribute("MaxHealth")}
                mobs.entities[id]=entry
            end
            if not entry.replica then entry.hp=hp entry.maxHP=model:GetAttribute("MaxHealth") end
            entry.model=model entry.position=model:GetPivot().Position entry.seenAt=os.clock()
        end
    end
end
local function mobPosition(mob)
    if mob.model and mob.model.Parent then return mob.model:GetPivot().Position end
    return mob.position
end
local skeletonTypes={}
for id,d in pairs(mobs.catalog) do
    if id:lower():find("skeleton",1,true) or d.name:lower():find("skeleton",1,true) then skeletonTypes[id]=true end
end
local function skeletonPriority(mob)
    return mob.maxHP or (mobs.catalog[mob.name] and mobs.catalog[mob.name].maxHP) or 0
end
local function nearestMob(name,skeletonBatch)
    local _,_,root=character()
    local best,distance,bestPriority,bestHP
    if not root then return end
    for id,mob in pairs(mobs.entities) do
        local allowed=name==nil or mob.name==name
        if skeletonBatch then allowed=skeletonTypes[mob.name] end
        if allowed and type(mob.hp)=="number" and mob.hp>0 and mobs.IsLive(mob) and mobPosition(mob) then
            local d=(mobPosition(mob)-root.Position).Magnitude
            local priority=skeletonBatch and skeletonPriority(mob) or 0
            local hp=skeletonBatch and (mob.maxHP or 0) or 0
            if not best or priority>bestPriority or (priority==bestPriority and hp>bestHP)
                or (priority==bestPriority and hp==bestHP and (d<distance or (d==distance and id<best.id))) then
                best,distance,bestPriority,bestHP=mob,d,priority,hp
            end
        end
    end
    return best
end
Adapter.skeletonPriority=skeletonPriority
local function hpText(value)
    if type(value)~="number" or value~=value then return "?" end
    value=math.max(0,value)
    if value==math.huge then return "∞" end
    local units={"","K","M","B","T","Qd","Qi","Sx","Sp","Oc","No","Dc"}
    local index=1
    while value>=1000 and index<#units do value/=1000 index+=1 end
    local rounded=math.floor(value*100+0.5)/100
    if rounded>=1000 and index<#units then rounded/=1000 index+=1 end
    local text=string.format("%.2f",rounded):gsub("%.?0+$","")
    return text..units[index]
end
-- Boss definitions are shared by all places. Membership comes from this world's
-- actual zonePath, spawn/arena markers and observed models, not the global catalog.
function Adapter.refreshBossDimension(force)
    local dimension=workspace:GetAttribute("currentDimension")
    if dimension~="Dimension1" and dimension~="Dimension2" and dimension~="Dimension3" then
        dimension=workspace:GetAttribute("Place")=="Dungeon" and "Dungeon" or nil
    end
    if mobs.bossDimension~=dimension then
        mobs.bossDimension=dimension mobs.dimensionBosses={} mobs.nextDimensionScan=0
        if state.ready and (flags.MobFarm or flags.BossFarm) then
            state.generation+=1 api.CancelMove()
            if mobs.ReleaseTarget then mobs.ReleaseTarget(mobs.target) end
            if mobs.bossRun then mobs.bossRun.current=nil table.clear(mobs.bossRun.served) mobs.bossRun.probes={} end
        end
    end
    mobs.dimensionBosses=mobs.dimensionBosses or {}
    if not dimension or (not force and os.clock()<(mobs.nextDimensionScan or 0)) then return end
    mobs.nextDimensionScan=os.clock()+1
    local allowed=mobs.dimensionBosses
    local function include(id)
        local d=mobs.catalog[id]
        if d and d.isBoss then allowed[id]=true end
    end
    for id,d in pairs(descriptions and descriptions.descriptions or {}) do
        if type(d.zonePath)=="string" and path(workspace,d.zonePath) then include(id) end
    end
    local rumbling=path(workspace,"Map.RumblingEvent")
    if rumbling and rumbling:GetAttribute("Active")==true then include("FoundingTitan") end
    for _,tag in ipairs({"isSpawner","isBossArena","isBossZone"}) do
        for _,object in ipairs(CS:GetTagged(tag)) do
            if object:IsDescendantOf(workspace) then
                include(object:GetAttribute("entityName")) include(object:GetAttribute("bossType"))
                if tag=="isBossZone" then
                    include(object.Name)
                    if object.Parent then include(object.Parent:GetAttribute("bossType")) end
                end
            end
        end
    end
    local folder=workspace:FindFirstChild("ClientEntities")
    for _,model in ipairs(folder and folder:GetChildren() or {}) do
        local entry=mobs.entities[model:GetAttribute("entityId")]
        include(entry and entry.name or model.Name)
    end
end
function Adapter.bossInCurrentDimension(id)
    return mobs.bossDimension~=nil and mobs.dimensionBosses~=nil and mobs.dimensionBosses[id]==true
end
function Adapter.bossSelectedLabels()
    local labels={}
    for _,label in ipairs(mobs.bossChecklistOptions or {}) do
        if config.bosses[mobs.bossChecklistIds[label]] then table.insert(labels,label) end
    end
    return labels
end
function Adapter.selectBossLabels(labels)
    if mobs.refreshingBosses then return end
    if flags.BossFarm then
        mobs.bossChecklist:SetSelected(Adapter.bossSelectedLabels())
        notify("Disable Auto Farm Bosses to edit the selection.") return
    end
    table.clear(config.bosses)
    for _,label in ipairs(type(labels)=="table" and labels or {}) do
        local id=mobs.bossChecklistIds[label]
        if id then config.bosses[id]=true end
    end
end
function Adapter.refreshBossControls()
    if not bossSection or not Adapter.bossPriority then return end
    Adapter.refreshBossDimension()
    local rows,options,ids={},{},{}
    for _,d in pairs(mobs.catalog) do
        if d.isBoss and Adapter.bossInCurrentDimension(d.id) then table.insert(rows,d) end
    end
    table.sort(rows,Adapter.bossPriority)
    for _,d in ipairs(rows) do
        local label=d.name.." · "..hpText(d.maxHP).." HP"
        if ids[label] then label=label.." ["..d.id.."]" end
        table.insert(options,label) ids[label]=d.id
    end
    mobs.bossChecklistOptions=options mobs.bossChecklistIds=ids
    local signature=tostring(mobs.bossDimension).."|"..table.concat(options,"|")
    if not mobs.bossChecklist then
        mobs.bossChecklist=bossSection:Checklist("Target Bosses",options,Adapter.selectBossLabels,Adapter.bossSelectedLabels())
        Adapter.selectBossLabels(mobs.bossChecklist:GetSelected())
        mobs.bossChecklist:SetSelected(Adapter.bossSelectedLabels())
    elseif signature~=mobs.bossChecklistSignature then
        mobs.refreshingBosses=true
        mobs.bossChecklist:SetOptions(options)
        mobs.bossChecklist:SetSelected(Adapter.bossSelectedLabels())
        mobs.refreshingBosses=false
    end
    mobs.bossChecklistSignature=signature
end
local function refreshMobDropdown()
    scanMobs()
    Adapter.refreshBossControls()
    local labels,map,selected,rows={},{},nil,{}
    local byName={}
    -- Dungeon variants share names with their overworld counterparts; show one choice per name.
    for _,mob in pairs(mobs.catalog) do
        local old=byName[mob.name]
        local rank=(mob.quest and 0 or 2)+(mob.id:find("Dungeon",1,true) and 1 or 0)
        local oldRank=old and ((old.quest and 0 or 2)+(old.id:find("Dungeon",1,true) and 1 or 0))
        if not old or rank<oldRank or (rank==oldRank and mob.id<old.id) then byName[mob.name]=mob end
    end
    local liveById,maxById={},{}
    for _,mob in pairs(byName) do
        table.insert(rows,mob)
        local live=mobs.target and mobs.target.name==mob.id and mobs.target or nearestMob(mob.id)
        liveById[mob.id]=live
        maxById[mob.id]=live and live.maxHP or mob.maxHP or math.huge
    end
    table.sort(rows,function(a,b)
        local ah,bh=maxById[a.id],maxById[b.id]
        if ah~=bh then return ah<bh end
        return a.name<b.name or (a.name==b.name and a.id<b.id)
    end)
    local normalLabels,bossLabels={},{}
    for _,mob in ipairs(rows) do
        local live=liveById[mob.id]
        local label='"'..mob.name..'" | HP: '..hpText(live and live.hp)..'/'..hpText(live and live.maxHP or mob.maxHP)
        map[label]=mob.id table.insert(labels,label)
        table.insert(mob.isBoss and bossLabels or normalLabels,label)
        if mobs.catalog[config.mob] and mobs.catalog[config.mob].name==mob.name then selected=label end
    end
    mobs.labels=map
    mobs.options={normal=normalLabels,bosses=bossLabels}
    local signature=table.concat(labels,"\n")
    if mobDropdown then
        mobs.refreshingDropdown=true -- SetOptions may invoke the library's selection callback.
        if signature~=mobs.lastLabels then
            mobDropdown:SetOptions(normalLabels)
            mobs.lastLabels=signature
        end
        if selected and not config.farmBosses and not (mobs.catalog[config.mob] and mobs.catalog[config.mob].isBoss) then
            if mobDropdown:Get()~=selected then mobDropdown:Set(selected) end
        end
        mobs.refreshingDropdown=false
    end
end
-- Server power lifecycle is the warning; client VFX size is not a damage radius.
local defense={threats={},count=0,status="Waiting for boss",revision=0}
api.BossDefense=defense
-- Verified definition Properties, usable even when executor require(Runtime) fails.
defense.KnownShapes={["AbyssalSeverance"]={["diameter"]=30,["range"]=30},["AlmightyPull"]={["delay"]=0.45,["duration"]=0.2,["range"]=75,["width"]=35},["AlmightyPush"]={["delay"]=0.4,["diameter"]=100,["duration"]=0.2},["Annihilation"]={["diameter"]=80,["duration"]=2.4},["AntBite"]={["diameter"]=150},["AntSlam"]={["diameter"]=150},["AntVenomSpit"]={["delay"]=0.5,["diameter"]=65,["duration"]=4,["poisonFlatDamage"]=75,["projectileSpeed"]=300},["ApexSeverance"]={["diameter"]=46,["duration"]=0.5,["range"]=80},["BeastCleave"]={["hitboxSize"]=96},["Beelzebub"]={["delay"]=0.45,["duration"]=1,["range"]=75,["width"]=35},["BerserkRush"]={["aoeDelay"]=0,["aoeDiameter"]=70,["dashDelay"]=0.416,["dashDuration"]=0.4,["range"]=70,["slashDelay"]=0.783},["BijuuBomb"]={["explosionDiameter"]=80,["explosionDuration"]=1.2,["projectileDiameter"]=60,["range"]=800,["shootDelay"]=1.25,["speed"]=500},["BlackDivider"]={["range"]=100,["slashDelay"]=0.533,["width"]=50},["BlackHurricane"]={["diameter"]=80,["duration"]=1,["hurricaneDelay"]=0.5,["lastHitDelay"]=0.5,["pullPadding"]=6},["BlackLightning"]={["diameter"]=80,["duration"]=1,["range"]=100},["BlackMeteorite"]={["explosionDiameter"]=80,["launchDelay"]=0.3,["launchDiameter"]=45,["range"]=156,["slashDelay"]=1.01,["smashDelay"]=1.16},["BrolyRush"]={["delay"]=0.3,["diameter"]=30,["duration"]=1},["CeroBarrido"]={["explosionDiameter"]=75,["range"]=250},["CeroDevastacion"]={["range"]=100},["ChaoticAfterglow"]={["diameter"]=100,["duration"]=2},["CleaveDismantle"]={["diameter"]=70,["duration"]=0.4,["range"]=60},["CompassNeedle"]={["dashDuration"]=0.7,["diameter"]=50,["range"]=30},["CrimsonFault"]={["delay"]=0.7,["range"]=90,["width"]=30},["DevouringClaw"]={["delay"]=0.4,["range"]=35},["Disorder"]={["explosionDiameter"]=40,["projectileDiameter"]=12,["range"]=300},["EnemyAttack"]={["duration"]=0.5,["fallbackDamage"]=10,["forwardOffset"]=4,["hitboxSize"]=8},["ExplosiveWave"]={["explosionDiameter"]=140},["FlyingBloodSickles"]={["explosionDiameter"]=30,["projectileDiameter"]=20,["range"]=200},["Fuga"]={["explosionDiameter"]=80,["projectileDiameter"]=10,["range"]=200},["GiganticRoar"]={["delay"]=0.1,["duration"]=1,["range"]=100,["width"]=30},["Gokei"]={["delay"]=0.25,["diameter"]=150,["duration"]=1.5},["GyutaroMechanic"]={["explosionDiameter"]=200},["HandDemonEnragedCharge"]={["diameter"]=60,["range"]=130,["speed"]=40},["HandDemonHandTornado"]={["diameter"]=90,["duration"]=0.3},["HandDemonRockThrow"]={["explosionDiameter"]=50,["explosionDuration"]=0.4,["projectileDiameter"]=20,["range"]=300,["speed"]=120},["HellFlare"]={["explosionDiameter"]=80,["projectileDiameter"]=10,["range"]=200},["IkkaSenjekai"]={["delay"]=0.5,["diameter"]=70,["duration"]=1.75,["range"]=50},["KingsDescent"]={["diameter"]=55,["duration"]=1.7,["lastHitDelay"]=0.5,["range"]=75},["KuramaRoar"]={["duration"]=0.8},["LanzaDelRelampago"]={["hitboxSize"]=200,["range"]=225},["LegendaryKiBlasts"]={["explosionDiameter"]=28,["projectileDiameter"]=10,["range"]=300},["LightAnnihilation"]={["diameter"]=140,["duration"]=2.3,["range"]=120},["LightRain"]={["explosionDiameter"]=15,["launchDelay"]=0.383,["projectileDiameter"]=8,["range"]=240},["LightSwordThrust"]={["dashDelay"]=0.268,["dashDuration"]=0.083},["MegiddoInfernus"]={["delay"]=0.4,["range"]=84},["MeteorShower"]={["downwardCone"]=true,["explosionDiameter"]=28,["explosionDuration"]=1,["maxSpread"]=48,["projectileDiameter"]=10,["projectiles"]=15,["range"]=300,["speed"]=150},["MoonDragon"]={["hitboxSize"]=69},["PlanetaryDevastation"]={["delay"]=0.5,["duration"]=5.5,["range"]=100},["PredatorPounce"]={["range"]=80,["slashDelay"]=0.6},["PsychicPull"]={["delay"]=0.45,["duration"]=0.2,["range"]=75,["width"]=35},["RampantArcRampage"]={["explosionDiameter"]=60},["RockBarrage"]={["explosionDiameter"]=14,["projectileDiameter"]=8,["range"]=120},["RotatingCircularSlashes"]={["delay"]=1.25,["duration"]=0.75},["SeaBeastDeadlyShower"]={["bulletDiameter"]=30,["bulletInterval"]=0.035,["bulletMaxTravelTime"]=1,["bulletSpread"]=20,["coneDegrees"]=20,["duration"]=3,["explosionDiameter"]=75,["projectileDiameter"]=30,["range"]=500,["serverBulletInterval"]=0.1,["showerDuration"]=3,["tickInterval"]=0.5,["turnSpeedDegrees"]=45},["SeaBeastDive"]={["splashDiameter"]=70},["SeaBeastRoar"]={["roarDuration"]=0.9,["shockwaveInterval"]=0.07,["shockwaveSize"]=300},["SeaBeastWaterBullet"]={["bezierSpread"]=100,["bulletLifetime"]=5,["bulletSpeed"]=200,["explosionDiameter"]=67.5,["projectileDiameter"]=15,["range"]=400,["speed"]=200,["windupDuration"]=1.2},["SeaOfTrees"]={["diameter"]=75},["Senbonzakura"]={["delay"]=1.1,["diameter"]=75,["duration"]=0.4,["range"]=25},["ShadowCross"]={["diameter"]=25,["range"]=80},["Shredder"]={["dashDelay"]=0.1,["dashDuration"]=0.2,["duration"]=1.3,["slashDelay"]=0.416666667,["width"]=30},["ShukakuBeastBomb"]={["explosionDiameter"]=80,["explosionDuration"]=0.4},["ShukakuGroundSmash"]={["explosionDiameter"]=160,["explosionDuration"]=0.5},["ShukakuWindBullets"]={["PROJECTILE_LIFETIME"]=5,["PROJECTILE_SPEED"]=140,["explosionDiameter"]=80,["explosionDuration"]=0.4,["projectileDiameter"]=40,["range"]=200,["shootDelay"]=0,["speed"]=140,["speedupMultiplier"]=1.6},["SwordSkyJudgement"]={["diameter"]=45,["duration"]=0.5,["range"]=81},["TitanSlam"]={["diameter"]=100},["TitanThrow"]={["diameter"]=70,["range"]=300},["TormentaDeMurcielago"]={["hitboxSize"]=140},["TornadoSmash"]={["diameter"]=22},["TripleTSlam"]={["effectLifetime"]=4,["flingDuration"]=1,["flingSpeed"]=250,["flingSpinSpeed"]=12,["flingUpwardBias"]=1.5,["groundSearchDistance"]=60,["ragdollDuration"]=2.5,["ringDuration"]=0.45,["sourceHitDiameter"]=1728,["sourceImpactForward"]=436,["sourceRigHeight"]=715.38,["windDuration"]=0.6},["VoidSteps"]={["diameter"]=40,["duration"]=0.5,["lastHitDelay"]=0.5,["range"]=80},["WaterBullet"]={["explosionDiameter"]=31.25,["projectileDiameter"]=12.5,["range"]=168},["WhirlWindStorm"]={["delay"]=0.3,["projectileDiameter"]=30,["range"]=200},["WindBullet"]={["explosionDiameter"]=24,["projectileDiameter"]=9.6,["pullPadding"]=6,["range"]=202.5},["WrathfulOutcry"]={["delay"]=0.5,["diameter"]=108,["duration"]=1.85,["lastHitDelay"]=0.4},["YojunSenka"]={["explosionDiameter"]=80,["projectileDiameter"]=10,["range"]=200}}
-- Conservative Berserk envelopes cover the final roar blast, offset boxes and dashes.
-- Live Properties include lastHitDiameter/box offsets missing from the old summary.
-- Extra clearance is intentional; bossScale also drives VFX and is not hitbox proof.
defense.KnownShapes.WrathfulOutcry={diameter=234,delay=0.5,duration=1.85,lastHitDelay=0.4}
defense.KnownShapes.BeastCleave={diameter=204,delay=0.5,duration=0.7}
defense.KnownShapes.PredatorPounce={diameter=254,range=112,width=84,slashDelay=0.6,duration=1.067}
defense.KnownShapes.Shredder={diameter=90,range=130,width=65,dashDelay=0.1,dashDuration=0.2,slashDelay=0.417,duration=2.3}
-- Directional Berserk attacks use offset boxes. A bounding circle incorrectly
-- rules out the boss's back and forces a full retreat for every sword swing.
defense.BerserkBoxes={
    BeastCleave={width=134.4,length=88.2,offset=31.5},
    PredatorPounce={width=84,length=168,offset=35,sweep=112},
    Shredder={width=39,length=65,offset=6.5,sweep=130},
}
-- Live Properties: Ricochet grabs an offset sphere before the stun/air combo.
-- Barrage rocks start around the caster and scatter outside its center ray.
defense.KnownShapes.PsychicRicochet={grabDiameter=35,forwardOffset=10,grabDelay=0.417,
    riseDuration=0.5,ricochetHits=10,ricochetInterval=0.05,mergeDelay=0.2,
    convergeDuration=0.2,slamDuration=0.2,stunDuration=2.5}
defense.KnownShapes.RockBarrage={explosionDiameter=14,projectileDiameter=8,range=120,
    width=62,speed=300,riseDuration=0.6,projectiles=5,maxInterval=0.1,explosionDuration=0.25}
defense.KnownShapes.WhirlWindStorm.speed=150
defense.KnownShapes.HandDemonEnragedCharge.windupDuration=1.1
local function insideArena(zone,point,margin)
    if not zone or not zone.Parent or not zone:IsA("Part") then return false end
    margin=margin or 4
    if zone.Shape~=Enum.PartType.Block then
        return (point-zone.Position).Magnitude<=zone.Size.X/2-margin
    end
    local p=zone.CFrame:PointToObjectSpace(point)
    -- These gameplay volumes begin at floor height: reserve body space horizontally,
    -- but do not reject an otherwise valid ground point for a five-stud vertical inset.
    local half=zone.Size/2-Vector3.new(margin,math.min(margin,1),margin)
    return math.abs(p.X)<=half.X and math.abs(p.Y)<=half.Y and math.abs(p.Z)<=half.Z
end
defense.Inside=insideArena
-- Event arenas (Berserk, for example) can retain only isSafeZone while active.
-- Resolve the boss's authoritative zonePath before consulting generic tags.
function defense.ResolveZone(target)
    local position=mobPosition(target)
    if not position then return end
    local d=descriptions and descriptions.descriptions and descriptions.descriptions[target.name]
    local declared=d and type(d.zonePath)=="string" and path(workspace,d.zonePath)
    if insideArena(declared,position,0) then return declared end
    local zone
    for _,candidate in ipairs(CS:GetTagged("isBossZone")) do
        if insideArena(candidate,position,0) and (not zone or candidate.Size.Magnitude<zone.Size.Magnitude) then zone=candidate end
    end
    return zone
end
do
-- Reject environmental hazards; never edit their touch handlers or the map.
local safety={hazards={},revision=0,rejected=0,lastReason="—"}
defense.Safety=safety
local function hazardLabel(object)
    local name=object.Name:lower():gsub("[%s_%-]", "")
    return name:find("lava",1,true) or name:find("kill",1,true) or name:find("deathzone",1,true)
        or name:find("killzone",1,true) or name:find("hazard",1,true) or name=="acid"
end
local function hazardPart(part)
    if not part:IsA("BasePart") then return false end
    local object=part
    while object and object~=workspace do
        if hazardLabel(object) then return true end
        object=object.Parent
    end
    for _,child in ipairs(part:GetChildren()) do
        if (child:IsA("Script") or child:IsA("LocalScript")) and hazardLabel(child) then return true end
    end
    return false
end
local function indexHazard(object)
    local part=object:IsA("BasePart") and object or object.Parent
    if part and part:IsA("BasePart") and hazardPart(part) then
        if not safety.hazards[part] then safety.hazards[part]=true safety.revision+=1 end
    end
end
local map=workspace:FindFirstChild("Map")
if map then
    for _,object in ipairs(map:GetDescendants()) do indexHazard(object) end
    connect(map.DescendantAdded,indexHazard)
    connect(map.DescendantRemoving,function(object)
        if safety.hazards[object] then safety.hazards[object]=nil safety.revision+=1 end
    end)
end
local function arenaFor(target)
    return defense.ResolveZone(target)
end
defense.ArenaFor=arenaFor
local function nearHazard(point,radius)
    for part in pairs(safety.hazards) do
        if part:IsDescendantOf(workspace) then
            local p=part.CFrame:PointToObjectSpace(point)
            local half=part.Size/2+Vector3.new(radius,radius,radius)
            if math.abs(p.X)<=half.X and math.abs(p.Y)<=half.Y and math.abs(p.Z)<=half.Z then return part end
        end
    end
end
safety.NearHazard=nearHazard
local function queryExclusions(zone)
    local exclude={zone}
    if player.Character then table.insert(exclude,player.Character) end
    for _,object in ipairs(workspace:GetChildren()) do
        if object.Name=="ClientEntities" or object.Name=="Living" or object.Name=="Ignore" or object.Name=="Zones" then
            table.insert(exclude,object)
        end
    end
    -- Non-solid gameplay zone volumes must never hide the actual floor/hazard below them.
    for _,tag in ipairs({"isBossZone","isSafeZone","isIneligibleZone"}) do
        for _,object in ipairs(CS:GetTagged(tag)) do if object:IsA("BasePart") then table.insert(exclude,object) end end
    end
    return exclude
end
-- SeaBeast's live aggro zone is over the non-collidable RealWater plane.
-- This support is allowed only there; lava/void elsewhere still require solid ground.
function safety.WaterSupport(point,zone,width)
    if zone~=path(workspace,"Zones.Aggro.SeaBeast") then return end
    local waterFolder=path(workspace,"Zones.Water")
    if not waterFolder then return end
    for _,water in ipairs(waterFolder:GetChildren()) do
        if water.Name=="RealWater" and water:IsA("BasePart") and water.CFrame.UpVector.Y>=0.99 then
            local q=water.CFrame:PointToObjectSpace(point)
            if math.abs(q.X)+width<water.Size.X/2 and math.abs(q.Z)+width<water.Size.Z/2 then
                return water.CFrame:PointToWorldSpace(Vector3.new(q.X,water.Size.Y/2,q.Z))
            end
        end
    end
end
function safety.Validate(point,zone,preserveHeight)
    if not zone then return nil,"Arena boundary is not loaded" end
    local _,h,root=character()
    local foot=math.max(3.5,h and root and h.HipHeight+root.Size.Y/2+0.5 or 3.5)
    local width=math.max(3,root and math.max(root.Size.X,root.Size.Z)/2+2 or 3)
    local exclude=queryExclusions(zone)
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude params.FilterDescendantsInstances=exclude params.RespectCanCollide=true
    local hit=workspace:Raycast(point+Vector3.new(0,40,0),Vector3.new(0,-100,0),params)
    local waterFloor=not hit and safety.WaterSupport(point,zone,width)
    if not hit and not waterFloor then return nil,"No solid ground" end
    if hit and (hazardPart(hit.Instance) or safety.hazards[hit.Instance]) then return nil,"Unsafe ground: "..hit.Instance.Name end
    if hit and hit.Normal.Y<0.7 then return nil,"Ground is too steep" end
    local floor=hit and hit.Position or waterFloor
    -- Support the whole footprint. One ray can otherwise accept a ledge above lava or a hole.
    for i=0,(waterFloor and -1 or 7) do
        local angle=i*math.pi/4
        local offset=Vector3.new(math.cos(angle)*width,0,math.sin(angle)*width)
        local edge=workspace:Raycast(floor+offset+Vector3.new(0,4,0),Vector3.new(0,-8,0),params)
        if not edge or edge.Normal.Y<0.7 or math.abs(edge.Position.Y-floor.Y)>2.5 then return nil,"Platform edge / gap below character" end
        if hazardPart(edge.Instance) or safety.hazards[edge.Instance] then return nil,"Lava or lethal surface below" end
    end
    local y=floor.Y+foot+(waterFloor and 3 or 0)
    if preserveHeight and point.Y>=y and point.Y<=floor.Y+math.max(14,foot+4) then y=point.Y end
    local safe=Vector3.new(point.X,y,point.Z)
    if not insideArena(zone,safe,width+2) then return nil,"Too close to arena boundary" end
    local hazard=nearHazard(safe,math.max(foot,width)+2)
    if hazard then return nil,"Unsafe space around character: "..hazard.Name end
    if workspace:Raycast(safe,Vector3.new(0,4,0),params) then return nil,"Insufficient headroom" end
    for i=0,7 do
        local angle=i*math.pi/4
        local offset=Vector3.new(math.cos(angle)*width,0,math.sin(angle)*width)
        for _,height in ipairs({-1,2}) do
            if workspace:Raycast(safe+Vector3.new(0,height,0),offset,params) then return nil,"Character space is obstructed" end
        end
    end
    return safe
end
-- FoundingTitan marches outside boss zones. Its owned hover needs free air,
-- rather than a floor ray that would pull the character back into the Rumbling.
function safety.Air(point)
    if nearHazard(point,8) then return false end
    local params=OverlapParams.new()
    params.FilterType=Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances=queryExclusions(nil)
    params.RespectCanCollide=true
    return #workspace:GetPartBoundsInBox(CFrame.new(point),Vector3.new(8,10,8),params)==0
end
function safety.Follow(target,root,point,forward,distance)
    local zone=arenaFor(target)
    if not zone then
        defense.status="Boss position: arena boundary is not loaded"
        return nil
    end
    local now=os.clock()
    local cached=safety.follow
    if cached and cached.id==target.id and cached.revision==safety.revision and now<cached.expires
        and (cached.desired-point).Magnitude<0.5 and not safety.NearHazard(cached.point,6) then return CFrame.lookAt(cached.point,mobPosition(target)) end
    local safe,why=safety.Validate(point,zone,true)
    if not safe then
        safety.rejected+=1 safety.lastReason=why
        local position=mobPosition(target)
        -- Keep the slider radius; choose a different side of the boss when its back is unsafe.
        for i=1,15 do
            local angle=math.ceil(i/2)*(i%2==1 and 1 or -1)*math.pi/8
            local direction=CFrame.Angles(0,angle,0):VectorToWorldSpace(forward)
            local candidate=position-direction*distance+Vector3.new(0,point.Y-position.Y,0)
            safe=safety.Validate(candidate,zone,true)
            if safe then break end
        end
    end
    if safe then
        safety.follow={id=target.id,desired=point,point=safe,expires=now+0.15,revision=safety.revision}
        safety.lastSafe={zone=zone,point=safe}
        return CFrame.lookAt(safe,mobPosition(target))
    end
    defense.status="No safe ground near boss: "..tostring(why)
    local last=safety.lastSafe
    if last and last.zone==zone then
        local validated=safety.Validate(last.point,zone,true)
        if validated then return CFrame.lookAt(validated,mobPosition(target)) end
    end
    return safety.Emergency(zone,mobPosition(target))
end
function safety.Emergency(zone,lookAt)
    local arena=zone and zone.Parent
    local spawn=arena and arena:FindFirstChild("PlayerSpawn")
    if spawn and spawn:IsA("BasePart") then
        local point=safety.Validate(spawn.Position,zone,true)
        if point then return CFrame.lookAt(point,lookAt) end
    end
    local last=safety.lastSafe
    if last and last.zone==zone then
        local point=safety.Validate(last.point,zone,true)
        if point then return CFrame.lookAt(point,lookAt) end
    end
end

end -- safety implementation scope
local function bossAnimation(name,asset)
    local d=descriptions and descriptions.descriptions and descriptions.descriptions[name]
    for key,animation in pairs(d and d.animations or {}) do
        if typeof(animation)=="Instance" and animation.AnimationId:match("%d+$")==tostring(asset):match("%d+$") then
            local label=tostring(key):lower()
            return not (label:find("idle",1,true) or label:find("walk",1,true) or label:find("run",1,true)
                or label:find("death",1,true) or label:find("spawn",1,true)
                or label:find("stun",1,true)),key
        end
    end
    -- External animations are explicit server actions, but unknown locomotion is not an attack signal.
    return false
end
do
local powerNames={}
local directory=path(RS,"Configs.Powers")
if directory then
    for _,object in ipairs(directory:GetDescendants()) do
        if object:IsA("ModuleScript") and object:FindFirstChild("Client") then
            powerNames[object.Name:lower()]={id=object.Name,module=object}
        end
    end
end
local aliases={Kurama={swipe="KuramaSwipe",roar="KuramaRoar"},SeaBeast={deadlyshowerstart="SeaBeastDeadlyShower",deadlyshower="SeaBeastDeadlyShower",waterbullet="SeaBeastWaterBullet"},
    HandDemon={rockthrow="HandDemonRockThrow",handtornado="HandDemonHandTornado",enragedcharge="HandDemonEnragedCharge"}}
function defense.AnimationPower(name,asset)
    local attack,label=bossAnimation(name,asset)
    if not attack then return end
    label=tostring(label)
    local key=label:lower()
    local melee=key:match("^m%d+$")~=nil or key=="swipe"
    local alias=aliases[name] and aliases[name][key]
    local entry=powerNames[(alias or label):lower()]
    return entry and entry.id or (melee and "EnemyAttack" or "UnknownAnimation:"..label),melee,label
end
function defense.LiveShape(id)
    if defense.KnownShapes[id] then return defense.KnownShapes[id] end
    local entry=powerNames[tostring(id):lower()]
    if not entry then return end
    if entry.shape~=nil then return entry.shape or nil end
    local ok,definition=pcall(require,entry.module)
    local properties=ok and type(definition)=="table" and definition.Properties
    if type(properties)~="table" then entry.shape=false return end
    local shape={}
    for _,key in ipairs({"diameter","explosionDiameter","projectileDiameter","width","range","forwardOffset","hitboxSize","aoeDiameter","launchDiameter","pullPadding"}) do
        local value=properties[key]
        if type(value)=="number" then shape[key]=value
        elseif typeof(value)=="Vector3" then shape[key]=math.max(value.X,value.Y,value.Z) end
    end
    entry.shape=shape
    return shape
end
-- Reserve close AOE space before the warning packet; attack speed and latency
-- can otherwise place the server's older character position inside the first hit.
function defense.BodyRadius(target)
    -- All Berserk AOE has a windup; reserve its radius only while that attack is active.
    -- M1 still has the independent predictive melee envelope in SafeFrom.
    if target.name=="BerserkBoss" then return 0 end
    defense.bodyRadii=defense.bodyRadii or {}
    if defense.bodyRadii[target.name] then return defense.bodyRadii[target.name] end
    local d=descriptions and descriptions.descriptions and descriptions.descriptions[target.name]
    local radius=0
    for label in pairs(d and d.animations or {}) do
        local key=tostring(label):lower()
        local entry=powerNames[(aliases[target.name] and aliases[target.name][key] or key):lower()]
        local shape=entry and defense.LiveShape(entry.id)
        if shape and not shape.range then
            radius=math.max(radius,math.max(shape.diameter or 0,shape.explosionDiameter or 0,shape.aoeDiameter or 0,shape.hitboxSize or 0,shape.grabDiameter or 0)/2+(shape.pullPadding or 0)+math.abs(shape.forwardOffset or 0))
        end
    end
    defense.bodyRadii[target.name]=radius
    return radius
end
end -- animation contracts scope
function defense.ThreatDuration(shape)
    if not shape then return 2.5 end
    local travel=shape.speed and shape.range and shape.range/math.max(1,shape.speed) or 0
    return math.max(2.5,(shape.duration or 0)+(shape.delay or 0)+(shape.hurricaneDelay or 0)+(shape.lastHitDelay or 0)
        +math.max(shape.smashDelay or 0,shape.slashDelay or 0,shape.launchDelay or 0)
        +travel+(shape.explosionDuration or 0)+(shape.bulletMaxTravelTime or 0)+(shape.windupDuration or 0)
        +(shape.grabDelay or 0)+(shape.riseDuration or 0)+(shape.ricochetHits or 0)*(shape.ricochetInterval or 0)
        +(shape.mergeDelay or 0)+(shape.convergeDuration or 0)+(shape.slamDuration or 0)
        +(shape.projectiles or 0)*math.max(0.025,shape.maxInterval or 0)+0.8)
end
local function registerAnimation(entityId,asset,track)
    local enemy=mobs.entities[entityId]
    local selected=enemy and mobs.bossRun and mobs.bossRun.selected[enemy.name]
    if not (flags.AutoDungeon or flags.MobFarm or flags.BossFarm or flags.AutoQuest or flags.KillAllPlayers or flags.KillSelectedPlayer)
        or (not flags.AutoDungeon and not selected and (not mobs.target or mobs.target.id~=entityId)) then return end
    local definition=enemy and mobs.catalog[enemy.name]
    if not definition or not definition.isBoss then return end
    local power,melee,label=defense.AnimationPower(enemy.name,asset)
    if not power then return end
    local id="animation:"..entityId..":"..tostring(asset)
    local old=defense.threats[id]
    if old and (not old.ends or old.ends>os.clock()) then
        if track then old.track=track old.ends=nil end
        return
    end
    local _,_,root=character()
    local shape=defense.LiveShape(power)
    local lifetime=defense.ThreatDuration(shape)
    defense.threats[id]={entityId=entityId,power=power,melee=melee,label=label,origin=mobPosition(enemy),aim=root and root.Position,
        created=os.clock(),minimumEnd=os.clock()+lifetime,animation=true,forward=defense.Forward(enemy),track=track,ends=not track and os.clock()+lifetime or nil}
    defense.revision+=1
    if not track and defense.Apply then defense.Apply() end
end
observe("playEntityAnimation",function(entityId,asset) registerAnimation(entityId,asset) end)
observe("stopEntityAnimation",function(entityId,asset)
    local t=defense.threats["animation:"..entityId..":"..tostring(asset)]
    if t then t.ends=math.max(t.minimumEnd or 0,os.clock()+0.65) t.track=nil end
end)
observe("createClientPower",function(info)
    if type(info)~="table" or not info.entityId or not info.identifier then return end
    local enemy=mobs.entities[info.entityId]
    local selected=enemy and mobs.bossRun and mobs.bossRun.selected[enemy.name]
    if not (flags.AutoDungeon or flags.MobFarm or flags.BossFarm or flags.AutoQuest or flags.KillAllPlayers or flags.KillSelectedPlayer)
        or (not flags.AutoDungeon and not selected and (not mobs.target or mobs.target.id~=info.entityId)) then return end
    local d=enemy and mobs.catalog[enemy.name]
    if not d or not d.isBoss then return end
    local _,_,root=character()
    defense.threats[info.identifier]={entityId=info.entityId,power=info.powerId,
        origin=mobPosition(enemy),aim=root and root.Position,forward=defense.Forward(enemy),created=os.clock(),
        minimumEnd=os.clock()+defense.ThreatDuration(defense.LiveShape(info.powerId))}
    defense.revision+=1
    -- Do not wait for the farm loop, a cast hold, or the next render frame.
    if defense.Apply then defense.Apply() end
end)
-- Boss channels can retarget after creation. Follow the replicated aim, not only the initial warning.
local function updateThreatAim(identifier,point,direction)
    local t=defense.threats[identifier]
    if not t or typeof(point)~="Vector3" then return end
    t.aim=point
    if typeof(direction)=="Vector3" and direction.Magnitude>0.01 then t.forward=direction.Unit end
    defense.revision+=1
    if defense.Apply then defense.Apply() end
end
observe("setClientAimInfo",function(info)
    local aim=type(info)=="table" and info.aimInfo
    if type(aim)=="table" then updateThreatAim(info.identifier,aim.position,aim.direction) end
end)
-- These process packets carry the two immutable rock destinations. Later Aim
-- packets describe a new aim; they must not erase a rock that is already flying.
function defense.RecordProjectile(t,key,point)
    if not t or t.power~="HandDemonRockThrow" or typeof(point)~="Vector3" then return end
    local index=tostring(key):match("^enemyPosition([12])$")
    local impact=tostring(key):match("^rockExplode([12])$")
    if not index and not impact then return end
    local enemy=mobs.entities[t.entityId]
    local model=enemy and enemy.model
    local hand=model and model:FindFirstChild((index or impact)=="1" and "RightBottomHand" or "LeftBottomHand",true)
    local origin=hand and (hand:IsA("Bone") and hand.TransformedWorldCFrame.Position or hand:IsA("BasePart") and hand.Position)
        or t.origin or (enemy and mobPosition(enemy))
    if not origin then return end
    local shape=defense.LiveShape(t.power) or {}
    t.projectiles=t.projectiles or {}
    local id=index or impact
    local previous=t.projectiles[id]
    t.projectiles[id]={origin=previous and previous.origin or origin,aim=point,
        ends=os.clock()+(impact and (shape.explosionDuration or 0.4)+0.4
            or (point-origin).Magnitude/(shape.speed or 120)+(shape.explosionDuration or 0.4)+0.8)}
    t.minimumEnd=math.max(t.minimumEnd or 0,t.projectiles[id].ends)
    if t.ends then t.ends=math.max(t.ends,t.minimumEnd) end
    defense.revision+=1
    if defense.Apply then defense.Apply() end
end
observe("updateClientPower",function(info)
    if type(info)~="table" then return end
    if info.state=="Aim" then updateThreatAim(info.identifier,info.arguments)
    else
        local t=defense.threats[info.identifier]
        local target=mobs.target
        if not t and target and target.name=="HandDemon" and mobs.IsLive(target)
            and (tostring(info.state):match("^enemyPosition[12]$") or tostring(info.state):match("^rockExplode[12]$")) then
            -- A streamed-in boss may already be winding up: recover its power
            -- identity from the Hand Demon-specific process channel.
            t={entityId=target.id,power="HandDemonRockThrow",origin=mobPosition(target),created=os.clock()}
            defense.threats[info.identifier]=t
        end
        defense.RecordProjectile(t,info.state,info.arguments)
    end
end)
observe("destroyClientPower",function(id)
    local threat=defense.threats[id]
    if threat then threat.ends=math.max(threat.minimumEnd or 0,os.clock()+0.65) end
end)
do
local shapes={ConquerorsHaki={diameter=150.0},ShukakuBeastBomb={explosionDiameter=80.0},Bakudo61={range=140.0,diameter=60.0},MultiSlash={diameter=18.0,forwardOffset=8.0},RisingSlash={diameter=25.0},GatesOfBabylon={explosionDiameter=28.0,projectileDiameter=10.0,range=300.0},NightKickGuy={diameter=35.0,range=75.0,explosionDiameter=60.0},LapseBlue={forwardOffset=0.0},LegendaryKiBlasts={explosionDiameter=28.0,projectileDiameter=10.0,range=300.0},FallenDown={diameter=140.0},BrolyRush={diameter=30.0},SeaBeastDeadlyShower={explosionDiameter=75.0},ShukakuGroundSmash={explosionDiameter=160.0},TenjiKaijin={explosionDiameter=80.0,projectileDiameter=30.0,range=300.0},DragonsBreath={range=80.0},FlyingSlash={range=200.0},BlackFlash={range=6.0},ArmoredSusanoo={forwardOffset=80.0,hitboxSize=150.0},SeaBeastWaterBullet={explosionDiameter=67.5,projectileDiameter=15.0,range=400.0},MoltenCore={range=50.0},HollowPurple={diameter=50.0,forwardOffset=7.0,range=600.0},HandDemonHandTornado={diameter=90.0},AntVenomSpit={diameter=65.0},DragonFist={explosionDiameter=39.0},RoadRoller={range=75.0,diameter=30.0},Zoltraak={range=180.0,diameter=32.0},Amaterasu={hitboxSize=60.0,range=150.0},InfiniteVoid={diameter=120.0,forwardOffset=0.0},RisingSunEdge={range=120.0},ArmoredArrow={range=200.0},KnivesThrow={range=120.0,diameter=7.0},SpiritBomb={range=140.0,diameter=50.0},TornadoSmash={diameter=22.0},HellFlare={explosionDiameter=80.0,projectileDiameter=10.0,range=200.0},Blink={range=100.0},EnemyAttack={forwardOffset=4.0},BigBangKamehameha={range=100.0,width=30.0},MultiShuriken={diameter=40.0,projectileDiameter=25.0,range=200.0},SeaOfTrees={diameter=75.0},GiganticRoar={range=100.0,width=30.0},RapidPunchRework={range=13.0},ReversalRed={diameter=40.0},StandBarrage={range=20.0},BlackLightning={diameter=80.0,range=100.0},Timestop={diameter=150.0},DivergentDescent={diameter=40.0,range=90.0},SeriousTableFlip={range=140.0},Torch={range=40.0},CruelSun={projectileDiameter=100.0,explosionDiameter=200.0,range=450.0},Rasenshuriken={explosionDiameter=30.0,projectileDiameter=10.0,range=200.0},BijuuBombPlayer={explosionDiameter=80.0,projectileDiameter=50.0,range=300.0},ArmoredRain={hitboxSize=180.0,range=200.0},BijuuBomb={explosionDiameter=80.0,projectileDiameter=60.0,range=800.0},Megiddo={hitboxSize=80.0},Beelzebub={range=75.0,width=35.0},SpiritualPressure={diameter=100.0},MagmaEruption={range=70.0},MagmaShower={explosionDiameter=30.0,projectileDiameter=15.0,range=100.0},ShukakuWindBullets={explosionDiameter=80.0,projectileDiameter=40.0,range=200.0},ExplosiveWave={explosionDiameter=140.0},JudgementCut={diameter=110.0,forwardOffset=0.0},MegiddoInfernus={range=84.0},PurgatoryOnigiri={range=280.0},AntBite={diameter=150.0},MeteorShower={explosionDiameter=28.0,projectileDiameter=10.0,range=300.0},HandDemonEnragedCharge={diameter=60.0,range=130.0},AntSlam={diameter=150.0},KiBlasts={explosionDiameter=24.0,projectileDiameter=10.0},RapidPunch={range=13.0},HandDemonRockThrow={explosionDiameter=50.0,projectileDiameter=20.0,range=300.0},Onigiri={range=50.0},EnergyBlast={range=140.0},MagmaFist={explosionDiameter=50.0,projectileDiameter=20.0},MultiSlash_SilverChariot={diameter=10.0},RendingClaw={range=25.0},AbyssalSeverance={range=30.0,diameter=30.0},DevouringClaw={range=35.0},ShadowCross={range=80.0,diameter=25.0},ShadowBarrage={diameter=50.0},ShadowStrike={range=40.0},ApexSeverance={diameter=46.0,range=80.0},ThousandSlashes={diameter=60.0,forwardOffset=0.0},DoubleSlash={range=200.0},TornadoSlash={diameter=130.0},WaterSlash={range=80.0},ThunderSlashes={explosionDiameter=40.0},GaleSlashes={range=100.0}}
local function horizontal(v) return Vector3.new(v.X,0,v.Z) end
function defense.Forward(target)
    if target.rotation then
        local angle=target.rotation/255*math.pi*2
        return Vector3.new(-math.sin(angle),0,-math.cos(angle))
    end
    local model=target.model
    local part=model and model.Parent and (model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart"))
    return part and horizontal(part.CFrame.LookVector).Unit or target.lastForward or Vector3.new(0,0,-1)
end
-- Exclusion estimates are conservative planning envelopes, not claims about hidden server hitboxes.
function defense.SafeFrom(point,target,threats)
    local position=mobPosition(target)
    if not position then return false end
    local d=descriptions and descriptions.descriptions and descriptions.descriptions[target.name]
    local detection=d and d.attackDetection or {width=16,range=16,forwardOffset=8}
    local forward=defense.Forward(target)
    local hit=api.Combat and api.Combat.Hit
    local sample=hit and hit.motion[target.id]
    local latency=hit and hit.latency or 0.1
    local speed=sample and sample.velocity.Magnitude or 0
    -- Psychic can accelerate to 100 studs/s between packets, including from rest.
    if target.name=="WildPsychic" then speed=math.max(speed,d and d.runSpeed or 100) end
    local padding=4+math.min(target.name=="WildPsychic" and 24 or 8,speed*(latency+(target.name=="WildPsychic" and 0.12 or 0.06)))
    -- Interpolated models can trail the server. Reserve the predicted body position too.
    local predicted=sample and os.clock()-sample.time<0.35 and sample.position+sample.velocity*(latency+0.06) or position
    local meleeReach=math.max(defense.BodyRadius(target),math.sqrt(((detection.width or detection.range)/2)^2+((detection.forwardOffset or 0)+detection.range/2)^2))+padding
    -- Do not enter the next M1 before its warning arrives: the server sees our older position.
    if horizontal(point-position).Magnitude<=meleeReach or horizontal(point-predicted).Magnitude<=meleeReach then return false end
    local sweep=horizontal(predicted-position)
    if sweep.Magnitude>0.1 then
        local q=horizontal(point-position)
        local along=math.clamp(q:Dot(sweep.Unit),0,sweep.Magnitude)
        if (q-sweep.Unit*along).Magnitude<=meleeReach then return false end
    end
    local function box(origin,direction,width,length,offset)
        local frame=CFrame.lookAt(origin,origin+direction)
        local q=frame:PointToObjectSpace(point)
        return math.abs(q.X)<=width/2+padding and math.abs(q.Z+offset)<=length/2+padding
    end
    -- Check live facing as well as the warning snapshot: bosses can turn while winding up.
    if box(position,forward,detection.width or detection.range,detection.range,detection.forwardOffset or 0)
        or box(predicted,forward,detection.width or detection.range,detection.range,detection.forwardOffset or 0) then return false end
    for _,t in ipairs(threats) do
        local origin=t.origin or position
        local direction=t.forward or forward
        local berserkBox=target.name=="BerserkBoss" and defense.BerserkBoxes[t.power]
        if berserkBox then
            local w,l,o=berserkBox.width,berserkBox.length,berserkBox.offset
            if box(origin,direction,w,l,o) or box(position,forward,w,l,o)
                or box(predicted,forward,w,l,o) then return false end
            if berserkBox.sweep then
                local reach=berserkBox.sweep+l/2+o
                if box(origin,direction,w,reach,reach/2)
                    or box(position,forward,w,reach,reach/2) then return false end
            end
            continue
        end
        if t.melee or t.power=="EnemyAttack" or t.power=="KuramaSwipe" then
            -- A boss can rotate after its warning. Clear the full swept attack volume,
            -- rather than assuming the current back/side remains safe until impact.
            local reach=math.sqrt(((detection.width or detection.range)/2)^2+((detection.forwardOffset or 0)+detection.range/2)^2)+padding
            if horizontal(point-origin).Magnitude<=reach or horizontal(point-position).Magnitude<=reach
                or horizontal(point-predicted).Magnitude<=reach then return false end
        else
            local shape=defense.LiveShape(t.power) or shapes[t.power]
            for _,projectile in pairs(t.projectiles or {}) do
                if os.clock()<projectile.ends then
                    local segment=horizontal(projectile.aim-projectile.origin)
                    local q=horizontal(point-projectile.origin)
                    local along=segment.Magnitude>0.01 and math.clamp(q:Dot(segment.Unit),0,segment.Magnitude) or 0
                    local nearest=segment.Magnitude>0.01 and segment.Unit*along or Vector3.zero
                    local clearance=math.max(shape and shape.projectileDiameter or 0,shape and shape.explosionDiameter or 0)/2+padding
                    if (q-nearest).Magnitude<=clearance then return false end
                end
            end
            local radius=shape and math.max(shape.diameter or 0,shape.explosionDiameter or 0,shape.hitboxSize or 0,shape.aoeDiameter or 0,shape.launchDiameter or 0,shape.grabDiameter or 0)/2+(shape.pullPadding or 0) or 0
            local distance=horizontal(point-position).Magnitude
            if shape and shape.downwardCone then
                local source=t.peakOrigin or origin
                local altitude=math.max(0,source.Y-point.Y,position.Y-point.Y)
                local angle=math.rad(math.clamp(shape.maxSpread or 0,0,85))
                local footprint=math.min((shape.range or 0)*math.sin(angle),altitude*math.tan(angle))+radius+padding
                if horizontal(point-source).Magnitude<=footprint or distance<=footprint then return false end
            end
            local offset=shape and shape.forwardOffset or 0
            if radius>0 then
                if horizontal(point-(position+forward*offset)).Magnitude<=radius+padding
                    or horizontal(point-(origin+direction*offset)).Magnitude<=radius+padding then return false end
                if t.aim and horizontal(point-t.aim).Magnitude<=radius+padding then return false end
            else
                -- Unknown server geometry: use a larger envelope, never derive damage size from VFX.
                local fallback=math.max(24,(detection.range or 16)+(detection.forwardOffset or 0))
                if distance<=fallback+padding or (t.aim and horizontal(point-t.aim).Magnitude<=fallback+padding) then return false end
            end
            if shape and shape.range then
                -- Sweeps/beams also have a corridor, even without a projectileDiameter property.
                local width=math.max(shape.projectileDiameter or 0,shape.width or 0,shape.diameter or 0,shape.hitboxSize or 0,detection.width or 0)/2
                local q=horizontal(point-origin)
                local aim=t.aim and horizontal(t.aim-origin)
                local path=aim and aim.Magnitude>0.1 and aim.Unit or direction
                local along=math.clamp(q:Dot(path),0,shape.range)
                local spread=shape.coneDegrees and math.tan(math.rad(shape.coneDegrees))*along+radius or 0
                if (q-path*along).Magnitude<=width+padding+spread then return false end
                local current=horizontal(point-position)
                local liveAlong=math.clamp(current:Dot(forward),0,shape.range)
                local liveSpread=shape.coneDegrees and math.tan(math.rad(shape.coneDegrees))*liveAlong+radius or 0
                if (current-forward*liveAlong).Magnitude<=width+padding+liveSpread then return false end
            end
        end
    end
    return true
end
end -- danger geometry scope
-- The visual spine trails the replicated root by thousands of studs. Reserve
-- the actual overhead column and the description's server body height instead
-- of letting a distant spike or synthetic _AimHitbox force a 1000-stud retreat.
function defense.FoundingHeight()
    local d=descriptions and descriptions.descriptions and descriptions.descriptions.FoundingTitan
    return math.max(424,(d and typeof(d.size)=="Vector3" and d.size.Y/2 or 300)+124)
end
function defense.FoundingPoint(target)
    if target.name~="FoundingTitan" then return end
    local model=mobs.ResolveModel(target)
    local position=model and mobPosition(target)
    if not position then return end
    local now=os.clock()
    local cached=defense.founding
    if not cached or cached.model~=model or now>=cached.expires then
        local height=defense.FoundingHeight()
        for _,part in ipairs(model:GetDescendants()) do
            if part:IsA("BasePart") and part.Name~="_AimHitbox" then
                local frame,half=part.CFrame,part.Size/2
                local right,up,look=frame.RightVector,frame.UpVector,frame.LookVector
                local extent=Vector3.new(math.abs(right.X)*half.X+math.abs(up.X)*half.Y+math.abs(look.X)*half.Z,
                    math.abs(right.Y)*half.X+math.abs(up.Y)*half.Y+math.abs(look.Y)*half.Z,
                    math.abs(right.Z)*half.X+math.abs(up.Z)*half.Y+math.abs(look.Z)*half.Z)
                local delta=frame.Position-position
                if math.abs(delta.X)<=extent.X+12 and math.abs(delta.Z)<=extent.Z+12 then
                    height=math.max(height,delta.Y+extent.Y+124)
                end
            end
        end
        cached={model=model,height=height,expires=now+0.25}
        defense.founding=cached
    end
    local point=position+Vector3.new(0,cached.height,0)
    if not cached.point or now>=(cached.checked or 0) or (point-cached.point).Magnitude>8 then
        cached.point=point cached.checked=now+0.12 cached.clear=defense.Safety.Air(point)
    end
    if cached.clear and not defense.Safety.NearHazard(point,8) then return point end
end
function defense.Frame(target,root)
    if flags.AutoDungeon and Adapter.Dungeon then return Adapter.Dungeon.Frame(target,root) end
    if target.name=="FoundingTitan" then
        local point=defense.FoundingPoint(target)
        if not point then
            defense.point=nil defense.hover=nil
            defense.status="FoundingTitan: waiting for clear air above the rig"
            return nil,true
        end
        if defense.target~=target.id then defense.count+=1 end
        defense.target=target.id defense.point=point defense.zone=nil defense.hover=true
        defense.status="FoundingTitan · hovering above the rig"
        return CFrame.lookAt(point,mobPosition(target)),true
    end
    local now=os.clock()
    -- Catch an attack already playing when the target was acquired, and local animation replication.
    if now>=(defense.nextAnimationScan or 0) then
        defense.nextAnimationScan=now+0.1
        local model=target.model
        local animator=model and model.Parent and model:FindFirstChildWhichIsA("Animator",true)
        if animator then
            for _,track in ipairs(animator:GetPlayingAnimationTracks()) do
                if track.Animation then registerAnimation(target.id,track.Animation.AnimationId:match("%d+$"),track) end
            end
        end
    end
    local threats={}
    for id,t in pairs(defense.threats) do
        if t.track and not t.track.IsPlaying then t.track=nil t.ends=math.max(t.minimumEnd or 0,now+0.65) end
        if (t.ends and now>=t.ends) or mobs.dead[t.entityId] then defense.threats[id]=nil
        elseif t.entityId==target.id then
            local shape=defense.LiveShape(t.power)
            local position=mobPosition(target)
            if shape and shape.downwardCone and position and (not t.peakOrigin or position.Y>t.peakOrigin.Y) then t.peakOrigin=position end
            table.insert(threats,t)
        end
    end
    if #threats==0 then
        local position=mobPosition(target)
        local preferred=position and position-defense.Forward(target)*math.clamp(config.behindDistance or 3,1.5,10)
        if not preferred or defense.SafeFrom(preferred,target,{}) then
            defense.point=nil defense.target=nil defense.status="Near boss · waiting for attack"
            return nil,false
        end
        -- An approaching boss can reach us before the next warning packet.
    end
    local position=mobPosition(target)
    if not position then return nil,true end
    local zone=defense.ResolveZone(target)
    if defense.target~=target.id or defense.zone~=zone then
        defense.zone=zone defense.point=nil defense.target=target.id
    end
    if not zone then
        defense.status="Attack: arena boundary missing; distant dodge unverified"
        return nil,true
    end
    -- Keep an already safe firing position throughout an attack. Cooldown changes
    -- must not make the movement controller jump between equally safe candidates.
    if (target.name=="BerserkBoss" or target.name=="HandDemon" or target.name=="WildPsychic") and (#threats>0 or (root.Position-position).Magnitude<=40)
        and defense.SafeFrom(root.Position,target,threats) then
        local held=defense.Safety.Validate(root.Position,zone,true)
        if held and (held-root.Position).Magnitude<2 then
            defense.point=held
            defense.status="Holding safe attack position · "..#threats.." attacks"
            return CFrame.lookAt(held,position),true
        end
    end
    if defense.point and defense.checkedRevision==defense.revision and now<(defense.nextCheck or 0)
        and defense.safetyRevision==defense.Safety.revision and not defense.Safety.NearHazard(defense.point,6)
        and defense.SafeFrom(defense.point,target,threats) then
        return CFrame.lookAt(defense.point,position),true
    end
    defense.nextCheck=now+0.12 defense.checkedRevision=defense.revision defense.safetyRevision=defense.Safety.revision
    local candidates={}
    local preferred=math.clamp(config.behindDistance or 3,1.5,10)
    local forward=defense.Forward(target)
    local function add(p)
        if not defense.SafeFrom(p,target,threats) then return end
        local distance=(p-position).Magnitude
        local hits=target.name~="BerserkBoss" and defense.OffenseScore and defense.OffenseScore(p,target) or 0
        local movement=(p-root.Position).Magnitude
        table.insert(candidates,{point=p,score=hits*1000-math.abs(distance-preferred)*2-movement*0.15})
    end
    if defense.point then add(defense.point) end
    for _,radius in ipairs({preferred,14,20,28,40,55,75,100,140,200,280}) do
        for i=0,15 do
            local direction=CFrame.Angles(0,i*math.pi/8,0):VectorToWorldSpace(forward)
            add(position-direction*radius)
        end
    end
    table.sort(candidates,function(a,b) return a.score>b.score end)
    local best
    for _,candidate in ipairs(candidates) do
        local point,why=defense.Safety.Validate(candidate.point,zone,true)
        if point and defense.SafeFrom(point,target,threats) then best=point break end
        defense.Safety.rejected+=1 defense.Safety.lastReason=why or "Ground intersects attack"
    end
    if best then
        if not defense.point or (best-defense.point).Magnitude>8 then defense.count+=1 end
        defense.Safety.lastSafe={zone=zone,point=best}
        defense.hover=defense.Safety.WaterSupport(best,zone,3)~=nil
        defense.point=best defense.status="Safe range · "..math.floor((best-position).Magnitude).." studs · "..#threats.." attacks"
        return CFrame.lookAt(best,position),true
    end
    defense.status="Attack: no dodge ground found inside arena"
    local emergency=defense.Safety.Emergency(zone,position)
    if emergency and defense.SafeFrom(emergency.Position,target,threats) then return emergency,true end
    return nil,true
end

local function mobFacingFrame(target,root)
    if flags.AutoDungeon and Adapter.Dungeon then return Adapter.Dungeon.Frame(target,root) end
    if target.player and Adapter.playerFrame then return Adapter.playerFrame(target,root) end
    if root and mobs.catalog[target.name] and mobs.catalog[target.name].isBoss then
        local frame,danger=defense.Frame(target,root)
        if danger then return frame end
    end
    local position=mobPosition(target)
    if not position then return end
    local model=target.model
    local part=model and model.Parent and (model.PrimaryPart or model:FindFirstChild("HumanoidRootPart"))
    local forward
    if type(target.rotation)=="number" then
        forward=CFrame.Angles(0,target.rotation/255*math.pi*2,0).LookVector
    elseif part then forward=part.CFrame.LookVector
    else forward=target.lastForward or (root and (position-root.Position)) end
    if not forward then return end
    forward=Vector3.new(forward.X,0,forward.Z)
    if forward.Magnitude<0.001 then return end
    forward=forward.Unit target.lastForward=forward
    local distance=math.clamp(tonumber(config.behindDistance) or 3,1.5,10)
    local height=math.clamp(tonumber(config.behindHeight) or 1,-1,3)
    local point=position-forward*distance+Vector3.new(0,height,0)
    if root and mobs.catalog[target.name] and mobs.catalog[target.name].isBoss then
        return defense.Safety.Follow(target,root,point,forward,distance)
    end
    return CFrame.lookAt(point,position)
end
Adapter.formatHP=hpText
Adapter.mobFacingFrame=mobFacingFrame
local placeTags = {isQuest="NPC", specialCrate="Specials", isDungeonGate="Dungeon",
    isDailyWheel="Daily Spin", championCapsule="Champions",
    isSafeZone="Safe Zone", isTowerNpc="Tower", isTournamentShopNpc="Tournament Shop"}
local placeCategories={"All Locations","NPC","Spawn","Safe Zone","Dungeon","Tower","Champions","Specials","Daily Spin","Tournament Shop"}
local function objectFrame(object)
    if object:IsA("Attachment") then return object.WorldCFrame end
    if object:IsA("BasePart") then return object.CFrame end
    if object:IsA("Model") and object:FindFirstChildWhichIsA("BasePart",true) then return object:GetPivot() end
end
local function updatePlaceOptions()
    local labels={}
    for _,place in ipairs(state.places) do
        if config.placeCategory=="All Locations" or place.category==config.placeCategory then table.insert(labels,place.label) end
    end
    if not table.find(labels,selectedPlace) then selectedPlace=labels[1] end
    if placeDropdown then placeDropdown:SetOptions(labels) placeDropdown:Set(selectedPlace) end
    if placeLabel then placeLabel:SetText("Locations: "..#labels.." · "..config.placeCategory) end
end
local function refreshPlaces()
    local places, seen = {}, {}
    for tag, category in pairs(placeTags) do
        for _, object in ipairs(CS:GetTagged(tag)) do
            if object:IsDescendantOf(workspace) and not seen[object] and objectFrame(object) then
                seen[object] = true
                table.insert(places, {object=object, category=category,
                    label=category.." · "..tostring(object:GetAttribute("QuestKey") or object:GetAttribute("entityName") or object.Name)})
            end
        end
    end
    local spawns = workspace:FindFirstChild("Spawns")
    if spawns then for _, object in ipairs(spawns:GetChildren()) do
        if objectFrame(object) then table.insert(places,{object=object,category="Spawn",label="Spawn · "..object.Name}) end
    end end
    table.sort(places, function(a,b)
        local ac,bc=table.find(placeCategories,a.category) or 99,table.find(placeCategories,b.category) or 99
        if ac~=bc then return ac<bc end
        return a.label:lower() < b.label:lower() or (a.label == b.label and a.object:GetFullName() < b.object:GetFullName())
    end)
    local labels, counts = {}, {}
    for _, place in ipairs(places) do
        local name = place.label
        counts[name] = (counts[name] or 0)+1
        if counts[name] > 1 then place.label = name.." #"..counts[name] end
        table.insert(labels, place.label)
    end
    state.places = places
    updatePlaceOptions()
end
function api.Refresh()
    local dimension=workspace:GetAttribute("currentDimension")
    local token = state.generation
    local ok, zones = request("requestTrainingZones", token)
    if valid(token) and workspace:GetAttribute("currentDimension")==dimension and ok and type(zones) == "table" then
        state.zones = zones
        local labels = {}
        table.sort(zones,function(a,b)
            local ar,br=(a.rewards or {})[1],(b.rewards or {})[1]
            local ai,bi=table.find(statNames,ar and ar.statType) or 99,table.find(statNames,br and br.statType) or 99
            if ai~=bi then return ai<bi end
            local av,bv=0,0
            for _,r in ipairs(a.requirements or {}) do av=math.max(av,r.value) end
            for _,r in ipairs(b.requirements or {}) do bv=math.max(bv,r.value) end
            if av~=bv then return av<bv end
            return a.displayName < b.displayName
        end)
        for _, zone in ipairs(zones) do
            local reward=(zone.rewards or {})[1]
            zone.label = (reward and reward.statType.." · " or "")..zone.displayName.." ["..zone.name.."]"
            table.insert(labels, zone.label)
        end
        if not table.find(labels,selectedZone) then selectedZone=labels[1] end
        if zoneDropdown then zoneDropdown:SetOptions(labels) zoneDropdown:Set(selectedZone) end
        state.result = "Catalog: "..#zones.." training areas"
    elseif valid(token) then state.error = "Catalog: "..tostring(zones) end
    if valid(token) then refreshPlaces() end
    return ok
end

-- One arbiter owns character properties for Player, fly, and every tween.
local snapshot, flight, lightSnapshot, cameraSnapshots = nil, nil, nil, {}
local function sameValue(a,b)
    if type(a)=="number" and type(b)=="number" then
        return math.abs(a-b)<0.00001*math.max(1,math.abs(b))
    end
    return a==b
end
local function capture(c,h,r)
    if snapshot and snapshot.character == c then return snapshot end
    snapshot = {character=c,humanoid=h,root=r,speed=h.WalkSpeed,jumpPower=h.JumpPower,
        jumpHeight=h.JumpHeight,autoRotate=h.AutoRotate,platformStand=h.PlatformStand,
        anchored=r.Anchored,parts={},owned={}}
    return snapshot
end
local function assign(object, property, value, original)
    local key = property
    local owned = snapshot.owned[object]
    if not owned then owned={} snapshot.owned[object]=owned end
    if value ~= nil then
        if not owned[key] then owned[key] = {original=original} end
        object[property] = value
        owned[key].last = value
    elseif owned[key] then
        if sameValue(object[property],owned[key].last) then object[property] = owned[key].original end
        owned[key] = nil
    end
end
local function destroyFlight()
    if flight then
        flight.velocity:Destroy() flight.attachment:Destroy() flight=nil
    end
end
local function restoreCharacter()
    destroyFlight()
    if not snapshot then return end
    for object, properties in pairs(snapshot.owned) do
        if object.Parent then for property, lease in pairs(properties) do
            pcall(function() if sameValue(object[property],lease.last) then object[property]=lease.original end end)
        end end
    end
    for part, lease in pairs(snapshot.parts) do
        if part.Parent and part.CanCollide == false then part.CanCollide = lease end
    end
    snapshot = nil
end
local function applyPlayer()
    local c,h,r = character()
    if not c then restoreCharacter() return end
    local s = capture(c,h,r)
    local moving = state.move and state.move.root == r
    local flying = flags.Fly and not moving
    local pinned=(flags.AutoDungeon or flags.MobFarm or flags.BossFarm or flags.AutoQuest or flags.KillAllPlayers or flags.KillSelectedPlayer) and mobs.target and (mobs.target.player or mobs.entities[mobs.target.id]) and not state.fruitBusy and not mobs.dead[mobs.target.id]
    assign(h,"WalkSpeed",flags.Speed and config.speed or nil,s.speed)
    if h.UseJumpPower then
        assign(h,"JumpPower",flags.Jump and config.jump or nil,s.jumpPower)
        assign(h,"JumpHeight",nil,s.jumpHeight)
    else
        assign(h,"JumpHeight",flags.Jump and config.jump^2/(2*workspace.Gravity) or nil,s.jumpHeight)
        assign(h,"JumpPower",nil,s.jumpPower)
    end
    local rotation, platform, anchor
    if moving or flying then rotation=false platform=true end
    local waitingHover=defense.waitPoint and defense.hover and (flags.AutoDungeon or flags.MobFarm or flags.BossFarm or flags.AutoQuest or flags.KillAllPlayers or flags.KillSelectedPlayer) and not state.fruitBusy
    if pinned or waitingHover then rotation=false if defense.hover then platform=true end end
    if moving then anchor=true end
    assign(h,"AutoRotate",rotation,s.autoRotate)
    assign(h,"PlatformStand",platform,s.platformStand)
    assign(r,"Anchored",anchor,s.anchored)
    if flags.Noclip or moving or pinned or waitingHover then
        for _,part in ipairs(c:GetDescendants()) do if part:IsA("BasePart") then
            if s.parts[part] == nil then s.parts[part] = part.CanCollide end
            part.CanCollide=false
        end end
    else
        for part, original in pairs(s.parts) do
            if part.Parent and not part.CanCollide then part.CanCollide=original end
            s.parts[part]=nil
        end
    end
    if flying then
        if not flight or flight.root ~= r then
            destroyFlight()
            local attachment=Instance.new("Attachment") attachment.Parent=r
            local velocity=Instance.new("LinearVelocity")
            velocity.Attachment0=attachment velocity.MaxForce=math.huge
            velocity.RelativeTo=Enum.ActuatorRelativeTo.World velocity.VectorVelocity=Vector3.zero velocity.Parent=r
            flight={root=r,attachment=attachment,velocity=velocity}
        end
        local camera=workspace.CurrentCamera
        local direction=Vector3.zero
        if camera and not UIS:GetFocusedTextBox() then
            if UIS:IsKeyDown(Enum.KeyCode.W) then direction += camera.CFrame.LookVector end
            if UIS:IsKeyDown(Enum.KeyCode.S) then direction -= camera.CFrame.LookVector end
            if UIS:IsKeyDown(Enum.KeyCode.D) then direction += camera.CFrame.RightVector end
            if UIS:IsKeyDown(Enum.KeyCode.A) then direction -= camera.CFrame.RightVector end
            if UIS:IsKeyDown(Enum.KeyCode.Space) then direction += Vector3.yAxis end
            if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then direction -= Vector3.yAxis end
        end
        flight.velocity.VectorVelocity = direction.Magnitude > 0 and direction.Unit*config.speed or Vector3.zero
    else destroyFlight() end
end
function api.CancelMove()
    local move=state.move
    if move then
        state.move=nil
        if move.tween then move.tween:Cancel() end
        applyPlayer()
    end
end
local function travel(cf, token, mobTeleport)
    if not valid(token) then return false,"Cancelled" end
    local airTarget=mobs.target
    local airPoint=mobTeleport and airTarget and (flags.AutoDungeon and Adapter.Dungeon and Adapter.Dungeon.Point(airTarget) or defense.FoundingPoint(airTarget))
    if not airTarget and flags.AutoDungeon and defense.waitPoint then airPoint=defense.waitPoint.Position end
    local airMove=airPoint and (cf.Position-airPoint).Magnitude<8
    -- A previous SeaBeast probe must not keep owning the root during a new route.
    if not airMove then defense.waitPoint=nil defense.hover=nil end
    -- Farm transfers to a waiting spawn / interaction point use the same arena floor guard.
    if mobTeleport and not airMove then
        local zone
        for _,candidate in ipairs(CS:GetTagged("isBossZone")) do
            if defense.Inside(candidate,cf.Position,0) and (not zone or candidate.Size.Magnitude<zone.Size.Magnitude) then zone=candidate end
        end
        if zone then
            local point,why=defense.Safety.Validate(cf.Position,zone,true)
            if not point then return false,"Unsafe arena position: "..tostring(why) end
            cf=CFrame.new(point)*cf.Rotation
        end
    end
    api.CancelMove()
    local c,h,r=character()
    if not c then return false,"Waiting for a living character" end
    if flags.Fly then return false,"Disable Fly first" end
    if mobTeleport or config.moveMode ~= "Tween" then
        local move={root=r}
        capture(c,h,r)
        state.move=move applyPlayer()
        local ok,err=pcall(function()
            r.AssemblyLinearVelocity=Vector3.zero r.AssemblyAngularVelocity=Vector3.zero
            c:PivotTo(cf*r.CFrame:ToObjectSpace(c:GetPivot()))
        end)
        local settled=ok and waitFor(mobTeleport and 0.1 or 0.3,token)
        local owned=state.move==move
        if owned then api.CancelMove() end
        if not ok then return false,tostring(err) end
        if not settled or not owned or player.Character~=c or h.Health<=0 then return false,"Cancelled" end
        if not waitFor(0.2,token) then return false,"Cancelled" end
        local reached=(r.Position-cf.Position).Magnitude<8
        if reached and mobTeleport then
            local zone=path(workspace,"Zones.Aggro.SeaBeast")
            if zone and defense.Inside(zone,r.Position,0) and defense.Safety.WaterSupport(r.Position,zone,3) then
                defense.waitPoint=r.CFrame defense.hover=true
            end
        end
        return reached,reached and "Position confirmed after teleport" or "Position corrected or blocked after teleport"
    end
    local duration=(r.Position-cf.Position).Magnitude/config.tweenSpeed
    if duration > config.timeout then return false,"Route exceeds timeout; increase speed or timeout" end
    local move={root=r}
    capture(c,h,r)
    state.move=move applyPlayer()
    local ok,err=pcall(function()
        move.tween=TweenService:Create(r,TweenInfo.new(math.max(0.05,duration),Enum.EasingStyle.Linear),{CFrame=cf})
        move.tween:Play()
        local deadline=os.clock()+duration+0.5
        while valid(token) and state.move==move and player.Character==c and h.Health>0 and os.clock()<deadline do
            if move.tween.PlaybackState==Enum.PlaybackState.Completed then break end
            task.wait(0.05)
        end
    end)
    local completed=ok and valid(token) and state.move==move and player.Character==c and h.Health>0
        and move.tween.PlaybackState==Enum.PlaybackState.Completed
    if state.move==move then api.CancelMove() end
    if not completed then return false,ok and "Teleport cancelled" or tostring(err) end
    if not waitFor(0.5,token) then return false,"Cancelled" end
    return (r.Position-cf.Position).Magnitude < 8,"Checking position after tween"
end
local function zoneContains(zone,r)
    local part=path(workspace,"Zones.Training."..zone.name)
    if part and part:IsA("BasePart") then
        local p=part.CFrame:PointToObjectSpace(r.Position)
        local half=part.Size/2+Vector3.new(0,8,0)
        return math.abs(p.X)<=half.X and math.abs(p.Y)<=half.Y and math.abs(p.Z)<=half.Z
    end
    return false
end
local function zoneTravel(zone,stat,token)
    local eligible,reason=Adapter.eligible(zone,Adapter.stats())
    if not eligible then return false,reason end
    if config.moveMode=="Game Teleport" or stat=="Speed" or stat=="Agility" then
        defense.waitPoint=nil defense.hover=nil
        api.CancelMove()
        local ok,accepted,message=request("requestTrainingZoneTeleport",token,zone.name,stat)
        if not ok or accepted ~= true then return false,tostring(message or accepted) end
        if not waitFor(0.7,token) then return false,"Cancelled" end
        local _,_,r=character()
        return r and zoneContains(zone,r) or false,"Teleport accepted; checking area bounds"
    end
    local part=path(workspace,"Zones.Training."..zone.name)
    local indicator=part and part:FindFirstChild("Indicator")
    if not indicator or not indicator:IsA("Attachment") then return false,"Area is not loaded; use Game Teleport" end
    return travel(indicator.WorldCFrame+Vector3.new(0,3,0),token)
end

local function releaseTraining()
    if Adapter.TrainingGear then Adapter.TrainingGear.Release() end
    local current=state.trainStat
    state.trainStat=nil
    if current and activeStats[current] then fire("equipStat",{state=false,statType=current}) end
    local saved=state.trainingSnapshot
    state.trainingSnapshot=nil
    if saved and player.Character==saved.character and activeStats[saved.stat] then
        fire("equipStat",{state=true,statType=saved.stat})
    end
    local _,h=character()
    if h then h:Move(Vector3.zero,false) h.Jump=false end
end
local function clearESP()
    for object,highlight in pairs(highlights) do highlight:Destroy() highlights[object]=nil end
end
local function restoreVisuals(kind)
    if lightSnapshot and (not kind or kind=="Fullbright") then
        for key,lease in pairs(lightSnapshot) do if Lighting[key]==lease.last then Lighting[key]=lease.original end end
        lightSnapshot=nil
    end
    if not kind or kind=="FOV" then
        for camera,lease in pairs(cameraSnapshots) do
            if camera.Parent and math.abs(camera.FieldOfView-lease.last)<0.001 then camera.FieldOfView=lease.original end
            cameraSnapshots[camera]=nil
        end
    end
end
-- Fruit identity comes from the game's definition folder and isFruit/fruitName contract.
local fruits={catalog={},labels={},retry=setmetatable({},{__mode="k"}),collected=0,status="Idle",target=nil}
local fruitDefinitions=path(RS,"Dictionaries.Specials.Descriptions.Fruit")
local fruitOptions={"All Fruits"}
if fruitDefinitions then
    for _,definition in ipairs(fruitDefinitions:GetChildren()) do
        if definition:IsA("ModuleScript") then
            fruits.catalog[definition.Name]=true
            table.insert(fruitOptions,definition.Name)
        end
    end
end
table.sort(fruitOptions,function(a,b)
    if a=="All Fruits" then return true end
    if b=="All Fruits" then return false end
    return a:lower()<b:lower()
end)
local inventory={amounts={},revisions={},hydrated=false}
-- Observe this executor's Generated replica; never replace the game's native prompt listener.
if Events.clientSync and Events.clientSync.setCallback then
    table.insert(mobs.callbacks,Events.clientSync.setCallback(function(payloads)
        if not state.alive then return end
        for _,payload in ipairs(payloads) do
            local data=payload.data and payload.data[tostring(player.UserId).."_PlayerData"]
            if type(data)=="table" then
                if payload.type=="init" then replica.data=data replica.hydrated=true
                else replica.data=applyPatch(replica.data,data) end
            end
            if type(data)=="table" and type(data.Inventory)=="table" then
                if payload.type=="init" then inventory.hydrated=true table.clear(inventory.amounts) end
                for id,item in pairs(data.Inventory) do
                    if type(item)=="table" and type(item.amount)=="number" then
                        inventory.amounts[id]=item.amount
                        inventory.revisions[id]=(inventory.revisions[id] or 0)+1
                    end
                end
            end
        end
    end))
end
local function itemAmount(id)
    if Data then
        local ok,item=pcall(Data.Get,Data,"Inventory."..id)
        if ok and type(item)=="table" and type(item.amount)=="number" then return item.amount end
    end
    if inventory.amounts[id]~=nil then return inventory.amounts[id] end
    if inventory.hydrated then return 0 end
    local row=path(player.PlayerGui,"Main.Pages.Inventory.Page.Main.Bottom.List."..id)
    if row and row:IsA("GuiObject") and row.Visible then
        local amount=row:FindFirstChild("Amount",true)
        if amount and amount:IsA("TextLabel") then
            if amount.Text=="" then return 1 end -- createItemFrame hides x1.
            return tonumber(amount.Text:match("x(%d+)$"))
        end
    end
end
local function promptPoint(prompt)
    local parent=prompt and prompt.Parent
    if parent and parent:IsA("Attachment") then return parent.WorldCFrame end
    return parent and objectFrame(parent)
end
local function activatePrompt(prompt,token,guard)
    if type(fireproximityprompt)~="function" then return false,"fireproximityprompt is unavailable" end
    if not valid(token) or not prompt or not prompt.Parent or not prompt.Enabled or (guard and not guard()) then return false,"Prompt unavailable" end
    local cf=promptPoint(prompt)
    if not cf then return false,"No interaction point" end
    local moved,why=travel(cf*CFrame.new(0,0,math.min(2,prompt.MaxActivationDistance*0.4)),token,true)
    if not moved then return false,why end
    local holdUntil=os.clock()+prompt.HoldDuration+0.2
    repeat
        if not waitFor(0.1,token) or (guard and not guard()) then return false,"Cancelled" end
        local _,_,currentRoot=character()
        local currentPoint=promptPoint(prompt)
        if not currentRoot or not currentPoint or not prompt.Enabled then return false,"Prompt disappeared" end
        if (currentRoot.Position-currentPoint.Position).Magnitude>prompt.MaxActivationDistance*0.7 then
            local held,reason=travel(currentPoint*CFrame.new(0,0,math.min(2,prompt.MaxActivationDistance*0.4)),token,true)
            if not held then return false,reason end
        end
    until os.clock()>=holdUntil
    local _,_,root=character()
    cf=promptPoint(prompt)
    if not valid(token) or (guard and not guard()) or not root or not cf or not prompt.Enabled
        or (root.Position-cf.Position).Magnitude>prompt.MaxActivationDistance then return false,"Prompt is out of range" end
    local ok,err=pcall(fireproximityprompt,prompt)
    return ok,err
end
local function findFruit()
    local _,_,root=character()
    if not root then return end
    local best,distance
    for _,object in ipairs(CS:GetTagged("isFruit")) do
        local id=object:GetAttribute("fruitName")
        if object:IsDescendantOf(workspace) and fruits.catalog[id]
            and (config.fruit=="All Fruits" or config.fruit==id)
            and os.clock()>=(fruits.retry[object] or 0) then
            local prompt=object:FindFirstChildWhichIsA("ProximityPrompt",true)
            local cf=prompt and promptPoint(prompt)
            if prompt and prompt.Enabled and cf then
                local d=(root.Position-cf.Position).Magnitude
                if not best or d<distance then best,distance={object=object,id=id,prompt=prompt},d end
            end
        end
    end
    return best
end
local function collectFruit(target,token)
    fruits.target=target.id fruits.status="Collecting "..target.id
    state.action="Snipe Fruit" state.target=target.id
    local before=itemAmount(target.id)
    local revision=inventory.revisions[target.id] or 0
    local ok,why=activatePrompt(target.prompt,token)
    if not valid(token) or not flags.FruitSnipe then return end
    if not ok then fruits.status=tostring(why) fruits.retry[target.object]=os.clock()+10 return end
    local deadline=os.clock()+6
    repeat
        local amount=itemAmount(target.id)
        local replicated=(inventory.revisions[target.id] or 0)>revision and (inventory.amounts[target.id] or 0)>0
        if (before~=nil and amount~=nil and amount>before) or replicated then
            fruits.collected+=1 fruits.retry[target.object]=os.clock()+30
            fruits.status="Collected: "..target.id.." · inventory confirmed"
            state.result=fruits.status return
        end
        if not waitFor(0.1,token) or not flags.FruitSnipe then return end
    until os.clock()>=deadline
    fruits.retry[target.object]=os.clock()+15
    fruits.status=target.object:IsDescendantOf(workspace) and "Collection unconfirmed; retrying in 15s"
        or "Fruit disappeared; inventory update unconfirmed"
end
Adapter.findFruit=findFruit
api.Fruits=fruits
function api.SelectFruit(id)
    if id~="All Fruits" and not fruits.catalog[id] then return false end
    config.fruit=id
    if fruitDropdown then fruitDropdown:Set(id) end
    if flags.FruitSnipe then api.Set("FruitSnipe",true) end
    return true
end
task.spawn(function()
    while state.alive do
        if state.ready and flags.FruitSnipe and not (mobs.target and mobs.catalog[mobs.target.name] and mobs.catalog[mobs.target.name].isBoss and mobs.IsLive(mobs.target)) then
            local target=findFruit()
            if target then
                -- Preempt the current segment, retain toggles, and let existing workers resume afterwards.
                state.fruitBusy=true state.generation+=1
                local token=state.generation
                api.CancelMove() releaseTraining() mobs.target=nil
                local ok,err=xpcall(function() collectFruit(target,token) end,debug.traceback)
                state.fruitBusy=false fruits.target=nil
                if not ok and valid(token) then fruits.status=tostring(err) fruits.retry[target.object]=os.clock()+15 end
            else
                fruits.status=workspace.StreamingEnabled and "Scanning loaded areas (streaming enabled)"
                    or "Scanning map · waiting for "..config.fruit
            end
        end
        task.wait(0.5)
    end
end)

local bossConfig=module("Configs.ArenaBossConfig")
local bossKeys={CurseKing="MalevolentKey",Mada="MadaraKey",Kokushibo="KokushiboKey"}
local bossAttempts={}
local dungeonBosses={KingAnt={name="JejuIsland",key="JejuIslandKey"},VastoLorde={name="Limbo",key="LimboKey"}}
local dungeon={queues={},state={},pending=nil,readyAt=0,farm={status="Idle"}}
Adapter.Dungeon=dungeon
local delta=module("Packages.DeltaCompress")
for event,field in pairs({replicateQueues="queues",replicateDungeonState="state"}) do
    if delta and Events[event] and Events[event].setCallback then
        table.insert(mobs.callbacks,Events[event].setCallback(function(patchData)
            if state.alive then dungeon[field]=delta.applyImmutable(dungeon[field],patchData) end
        end))
    end
end
quests.towerState={} quests.tournamentState={}
for event,field in pairs({replicateTowerState="towerState",replicateTournamentState="tournamentState"}) do
    observe(event,function(patchData)
        if delta then quests[field]=delta.applyImmutable(quests[field],patchData) end
    end)
end
-- Combat-only controller for the dungeon already joined by the player.
function dungeon.Active()
    return flags.AutoDungeon and workspace:GetAttribute("Place")=="Dungeon" and dungeon.farm.job==game.JobId
end
function dungeon.Eligible(target)
    return dungeon.Active() and target and not target.player and mobs.catalog[target.name]~=nil
        and mobs.IsLive(target) and mobs.ResolveModel(target)~=nil
end
-- Powers.TakeDamage checks the player's position against the enemy's room
-- restrictedZones. A high hover outside this volume can cast but deals no damage.
function dungeon.Room(target)
    local model=mobs.ResolveModel(target) local position=model and mobPosition(target)
    if not position then return end
    local cached=dungeon.farm.room
    if cached and cached.id==target.id and cached.model==model and cached.folder.Parent then return cached.folder end
    local map=workspace:FindFirstChild("Map")
    local nearest,best
    for _,area in ipairs(map and map:GetChildren() or {}) do
        local spawns=path(area,"Spawns.Entities") local doors=area:FindFirstChild("Doors")
        if spawns then
            local open=-1
            for _,door in ipairs(doors and doors:GetChildren() or {}) do
                local n=tonumber(door.Name)
                if n and door:IsA("BasePart") and not door.CanCollide then open=math.max(open,n) end
            end
            local current=spawns:FindFirstChild(tostring(open+1))
            for _,zone in ipairs(current and current:GetChildren() or {}) do
                if zone:IsA("BasePart") and CS:HasTag(zone,"isDungeonEntityZone") and defense.Inside(zone,position,0) then
                    dungeon.farm.room={id=target.id,model=model,folder=current} return current
                end
            end
            for _,spawn in ipairs(spawns:GetDescendants()) do
                if spawn:IsA("BasePart") and spawn:GetAttribute("entityName")==target.name then
                    local distance=(spawn.Position-position).Magnitude
                    if not best or distance<best then nearest=spawn.Parent best=distance end
                end
            end
        end
    end
    if nearest then dungeon.farm.room={id=target.id,model=model,folder=nearest} return nearest end
end
function dungeon.Point(target)
    local function horizontal(v) return Vector3.new(v.X,0,v.Z) end
    if not dungeon.Eligible(target) then return end
    local room=dungeon.Room(target) if not room then return end
    local model=target.model local position=mobPosition(target) local now=os.clock()
    local d=descriptions and descriptions.descriptions and descriptions.descriptions[target.name]
    local detection=d and d.attackDetection or {range=20,width=20,forwardOffset=10}
    local reach=math.sqrt(((detection.width or 20)/2)^2+((detection.forwardOffset or 0)+(detection.range or 20)/2)^2)
    local boss=mobs.catalog[target.name].isBoss
    local cached=dungeon.farm.air
    if cached and cached.id==target.id and cached.model==model and cached.revision==defense.revision
        and now<cached.expires and (position-cached.origin).Magnitude<1 then return cached.point end
    local threats={} local spread=boss and math.max(50,reach+24) or 36
    for id,t in pairs(defense.threats) do
        if t.track and not t.track.IsPlaying then t.track=nil t.ends=math.max(t.minimumEnd or 0,now+0.65) end
        if (t.ends and now>=t.ends) or mobs.dead[t.entityId] then defense.threats[id]=nil
        elseif t.entityId==target.id then table.insert(threats,t) end
    end
    local nearbyBosses={} local nearbyMobs={}
    local desiredY=position.Y+(boss and 60 or 32)
    for _,enemy in pairs(mobs.entities) do
        if enemy~=target and mobs.IsLive(enemy) and mobs.ResolveModel(enemy) then
            local p=mobPosition(enemy)
            local enemyDefinition=mobs.catalog[enemy.name]
            if p and enemyDefinition then
                if enemyDefinition.isBoss then
                    local warnings={}
                    for _,warning in pairs(defense.threats) do
                        if warning.entityId==enemy.id and (not warning.ends or now<warning.ends) then table.insert(warnings,warning) end
                    end
                    table.insert(nearbyBosses,{target=enemy,threats=warnings})
                elseif horizontal(p-position).Magnitude<150 then
                    desiredY=math.max(desiredY,p.Y+32)
                    local description=descriptions and descriptions.descriptions and descriptions.descriptions[enemy.name]
                    local detection=description and description.attackDetection or {range=24,width=24,forwardOffset=12}
                    local radius=math.sqrt(((detection.width or 24)/2)^2+((detection.forwardOffset or 0)+(detection.range or 24)/2)^2)+12
                    table.insert(nearbyMobs,{position=p,radius=radius})
                end
            end
        end
    end
    local base=Vector3.new(position.X,desiredY,position.Z)
    local candidates={base}
    if cached and cached.id==target.id then table.insert(candidates,1,base+cached.offset) end
    for _,radius in ipairs({spread,spread*1.5,spread*2,spread*3,180,240,320}) do
        for i=0,15 do local angle=i*math.pi/8 table.insert(candidates,base+Vector3.new(math.cos(angle)*radius,0,math.sin(angle)*radius)) end
    end
    local zones={}
    for _,zone in ipairs(room:GetChildren()) do
        if zone:IsA("BasePart") and CS:HasTag(zone,"isDungeonEntityZone") then table.insert(zones,zone) end
    end
    for _,candidate in ipairs(candidates) do
        for _,zone in ipairs(zones) do
            local localPoint=zone.CFrame:PointToObjectSpace(candidate)
            local half=zone.Size/2-Vector3.new(6,6,6)
            if half.X<=0 or half.Y<=0 or half.Z<=0 then continue end
            -- Stay inside the live server room, with space for the character's body.
            local point=zone.CFrame:PointToWorldSpace(Vector3.new(math.clamp(localPoint.X,-half.X,half.X),math.clamp(localPoint.Y,-half.Y,half.Y),math.clamp(localPoint.Z,-half.Z,half.Z)))
            local safe=point.Y-position.Y>=24 and (not boss or defense.SafeFrom(point,target,threats))
            if safe then
                for _,other in ipairs(nearbyBosses) do
                    if not defense.SafeFrom(point,other.target,other.threats) then safe=false break end
                end
            end
            if safe then
                for _,other in ipairs(nearbyMobs) do
                    if point.Y-other.position.Y<24 and horizontal(point-other.position).Magnitude<=other.radius then safe=false break end
                end
            end
            if safe and defense.Safety.Air(point) then
                dungeon.farm.air={id=target.id,model=model,revision=defense.revision,expires=now+0.10,origin=position,point=point,offset=point-base,zone=zone}
                return point
            end
        end
    end
    dungeon.farm.air=nil
end
function dungeon.Frame(target,root)
    local point=dungeon.Point(target)
    if not point then
        defense.point=nil
        if root and defense.Safety.Air(root.Position) then
            defense.hover=true defense.waitPoint=root.CFrame
            defense.status="Dungeon · holding while safe air is unavailable"
            return root.CFrame,true
        end
        defense.hover=nil return nil,true
    end
    if defense.target~=target.id then defense.count+=1 end
    defense.target=target.id defense.point=point defense.hover=true defense.zone=nil
    defense.status="Dungeon · air lock · "..target.name
    return CFrame.lookAt(point,mobPosition(target)),true
end
-- Authored room zones and door state are read from this map, never from an asset template.
function dungeon.Advance(token)
    if os.clock()<(dungeon.farm.nextAdvance or 0) then return end
    dungeon.farm.nextAdvance=os.clock()+2
    local map=workspace:FindFirstChild("Map") if not map then return end
    for _,area in ipairs(map:GetChildren()) do
        local spawns=path(area,"Spawns.Entities") local doors=area:FindFirstChild("Doors")
        if spawns and doors then
            local open=-1
            for _,door in ipairs(doors:GetChildren()) do
                local n=tonumber(door.Name)
                if n and door:IsA("BasePart") and not door.CanCollide then open=math.max(open,n) end
            end
            local room=spawns:FindFirstChild(tostring(open+1))
            local _,_,root=character()
            local nearest,distance
            for _,zone in ipairs(room and room:GetChildren() or {}) do
                if zone:IsA("BasePart") and CS:HasTag(zone,"isDungeonEntityZone") then
                    local d=root and (zone.Position-root.Position).Magnitude or math.huge
                    if not distance or d<distance then nearest=zone distance=d end
                end
            end
            if nearest then
                local point=nearest.CFrame:PointToWorldSpace(Vector3.new(0,math.max(0,nearest.Size.Y/2-8),0))
                if defense.Safety.Air(point) then
                    local cf=CFrame.new(point)
                    defense.waitPoint=cf defense.hover=true
                    local reached=travel(cf,token,true)
                    if valid(token) and dungeon.Active() and reached then
                        defense.waitPoint=cf defense.hover=true
                        dungeon.farm.status="Room "..(open+1).." · waiting for enemies"
                    end
                end
                return
            end
        end
    end
end
function dungeon.Step(token)
    if not valid(token) then return end
    local phase=workspace:GetAttribute("Phase") or dungeon.state.phase
    if not dungeon.Active() or phase=="Beaten" or phase=="Failed" or phase=="Terminated" then
        local result=phase=="Beaten" and "Dungeon complete" or ("Dungeon stopped · "..tostring(phase or "left instance"))
        api.Set("AutoDungeon",false) dungeon.farm.status=result state.result=result return
    end
    if phase~="Running" then dungeon.farm.status="Waiting for dungeon to run" return end
    local c,h,root=character()
    if not c then dungeon.farm.status="Waiting for respawn" return end
    scanMobs()
    local target=mobs.target
    if target and not dungeon.Eligible(target) then mobs.ReleaseTarget(target) target=nil end
    if not target then
        -- Keep a valid current identity locked. Rank new live targets by distance;
        -- authored dungeon progression determines which waves actually exist.
        local distance
        for _,entry in pairs(mobs.entities) do
            if dungeon.Eligible(entry) then
                local d=(mobPosition(entry)-root.Position).Magnitude
                if not distance or d<distance or (d==distance and tostring(entry.id)<tostring(target.id)) then target=entry distance=d end
            end
        end
        if not target then
            dungeon.farm.status="Waiting for next wave" state.action="Auto Dungeon" state.waiting=dungeon.farm.status
            if os.clock()-(dungeon.farm.emptySince or 0)>1.5 then dungeon.Advance(token) end
            return
        end
        dungeon.farm.emptySince=os.clock() dungeon.farm.air=nil
        mobs.target=target mobs.targetToken=token defense.waitPoint=nil
        table.insert(mobs.history,{event="target",id=target.id,name=target.name,time=os.clock()})
        if #mobs.history>60 then table.remove(mobs.history,1) end
        local stats=Adapter.stats()
        local weapon=config.bossWeapon=="Strongest Stat" and ((stats.Strength or 0)>(stats.Sword or 0) and "Strength" or "Sword") or config.bossWeapon
        state.trainStat=weapon fire("equipStat",{state=true,statType=weapon})
        local frame=dungeon.Frame(target,root)
        if frame then travel(frame,token,true) end
        if not valid(token) then return end
    end
    if not dungeon.Eligible(target) then return end
    dungeon.farm.emptySince=os.clock()
    dungeon.farm.status=(mobs.catalog[target.name].isBoss and "Boss" or "Wave").." · "..target.name.." #"..target.id.." · "..hpText(target.hp).." HP"
    state.action="Auto Dungeon" state.target=target.name.." #"..target.id state.waiting=dungeon.farm.status
    api.Combat.Step(target,token)
end

local function localDungeonQueue()
    for _,queue in pairs(dungeon.queues) do
        if queue.owner==player.UserId or (queue.members and table.find(queue.members,player.UserId)) then return queue end
    end
end
local function queueFunction()
    return type(queue_on_teleport)=="function" and queue_on_teleport
        or (type(syn)=="table" and type(syn.queue_on_teleport)=="function" and syn.queue_on_teleport)
end
connect(player.OnTeleport,function(phase)
    if phase==Enum.TeleportState.Started and state.alive and flags.AutoQuest and quests.current then
        local queue=queueFunction()
        local current=quests.current.id
        if queue and type(selfSource)=="string" then
            local data=game:GetService("HttpService"):JSONEncode(quests.known[current] or {})
            local bosses=game:GetService("HttpService"):JSONEncode(mobs.bossRun and mobs.bossRun.selected or config.bosses)
            local code=string.format("local s=%q;assert(loadstring(s,'AFS'))(s,{questId=%q,questData=%q,swordDurability=%s,difficulty=%q,targetMainQuest=%s,bossFarm=%s,bossesData=%q})",selfSource,current,data,tostring(config.swordDurability==true),config.dungeonDifficulty,tostring(flags.TargetMainQuest),tostring(flags.BossFarm),bosses)
            local ok,err=pcall(queue,code)
            if not ok then state.error=tostring(err) end
        end
        return
    end
    if phase~=Enum.TeleportState.Started or not state.alive or not flags.AutoJoinBoss or not flags.BossFarm
        or not dungeonBosses[config.mob] or (not dungeon.pending and workspace:GetAttribute("Place")~="Dungeon") then return end
    local queue=queueFunction()
    if not queue or type(selfSource)~="string" then return end
    local code=string.format("local s=%q; local f=assert(loadstring(s, 'AFS')); f(s,{mob=%q,weapon=%q,difficulty=%q})",
        selfSource,config.mob,config.weapon,config.dungeonDifficulty)
    local ok,err=pcall(queue,code)
    if not ok then state.error="Dungeon continuation: "..tostring(err) end
end)
local function bossArena(id)
    for _,arena in ipairs(CS:GetTagged("isBossArena")) do
        if arena:IsDescendantOf(workspace) and arena:GetAttribute("bossType")==id then return arena end
    end
end
local function bossParticipant(arena)
    for _,id in ipairs(string.split(arena:GetAttribute("bossParticipants") or "",",")) do
        if id==tostring(player.UserId) then return true end
    end
    return false
end
-- Paid summons/crafting remain forbidden. Free START totems are the final fallback.
local function bossActivationInfo(id)
    if dungeonBosses[id] then return "Existing dungeons only; no queue creation or keys" end
    local arena=bossArena(id)
    if arena then return "JOIN / free START after other targets · state "..tostring(arena:GetAttribute("bossState") or "Idle") end
    return "Existing spawn · no summons"
end
Adapter.bossActivationInfo=bossActivationInfo
function Adapter.bossTier(d)
    local arena=bossArena(d.id)
    if d.id=="Kurama" or d.id=="Brole" or d.id=="Lieve"
        or (arena and arena:FindFirstChild("Totem") and not arena:FindFirstChild("Summon") and not bossKeys[d.id]) then return 0 end
    if bossKeys[d.id] or d.id=="BerserkBoss" or d.id=="DemonLord" or d.id=="TripleT" then return 2 end
    return 1
end
function Adapter.encounterAlive(target)
    local d=mobs.catalog[target.name]
    if not d or not d.isBoss then return true end
    if target.name=="FoundingTitan" then
        local event=path(workspace,"Map.RumblingEvent")
        if event and event:GetAttribute("Active")~=true then return false end
    end
    local arena=bossArena(target.name)
    if arena then
        return arena:GetAttribute("bossState")=="Active" and bossParticipant(arena)
    end
    if target.name=="BerserkBoss" then
        local ends=workspace:GetAttribute("bloodMoonEndsAt")
        if type(ends)~="number" or ends<=workspace:GetServerTimeNow() then return false end
    end
    local zone=defense.ArenaFor(target)
    if zone then
        local spawned,active=zone:GetAttribute("bossSpawned"),zone:GetAttribute("isZoneActive")
        if spawned==false and active~=true or active==false and spawned~=true then return false end
    end
    return true
end
function Adapter.combatInArena(target)
    if flags.AutoDungeon then
        local _,_,root=character()
        local point=dungeon.Point(target)
        return root~=nil and point~=nil and not state.move and (root.Position-point).Magnitude<8
    end
    if target.player and Adapter.inSafeZone then
        local _,_,root=character()
        return root~=nil and not Adapter.inSafeZone(root.Position)
    end
    local d=mobs.catalog[target.name]
    if not d or not d.isBoss then return true end
    local _,_,root=character()
    if target.name=="FoundingTitan" then
        local point=defense.FoundingPoint(target)
        return root~=nil and point~=nil and (root.Position-point).Magnitude<=40
    end
    local zone=defense.ArenaFor(target)
    return root~=nil and (zone and defense.Inside(zone,root.Position,0)
        or (not zone and (root.Position-mobPosition(target)).Magnitude<=60))
end
function Adapter.otherSelectedAlive(except)
    local selected=mobs.bossRun and mobs.bossRun.selected or config.bosses
    for id in pairs(selected) do
        if id~=except and Adapter.bossInCurrentDimension(id) then
            if nearestMob(id) then return true end
            local arena=bossArena(id)
            if arena and (arena:GetAttribute("bossState")=="Active" or arena:GetAttribute("bossState")=="Intermission") then return true end
            for _,zone in ipairs(CS:GetTagged("isBossZone")) do
                if (zone.Name==id or zone.Parent:GetAttribute("bossType")==id)
                    and (zone:GetAttribute("bossSpawned")==true or zone:GetAttribute("isZoneActive")==true) then return true end
            end
        end
    end
    return false
end
function Adapter.canStartBoss(d,arena)
    local requirement=d and bossConfig and bossConfig.join_requirements and bossConfig.join_requirements[d.id]
    local total=player:GetAttribute("playerListTotalPower")
    if requirement and requirement.PowerRequirement>0 and (type(total)~="number" or total<requirement.PowerRequirement) then return false end
    return d~=nil and arena~=nil and Adapter.bossTier(d)==0 and not bossKeys[d.id]
        and arena:FindFirstChild("Summon")==nil and arena:FindFirstChild("Totem")~=nil
        and arena:GetAttribute("bossState")=="Idle" and not Adapter.otherSelectedAlive(d.id)
end
function Adapter.bossPriority(a,b)
    local at,bt=Adapter.bossTier(a),Adapter.bossTier(b)
    if at~=bt then return at>bt end
    local am,bm=nearestMob(a.id),nearestMob(b.id)
    local ah,bh=am and am.maxHP or a.maxHP or 0,bm and bm.maxHP or b.maxHP or 0
    if ah~=bh then return ah>bh end
    return a.id<b.id
end
function Adapter.bossAvailable(d)
    if not Adapter.bossInCurrentDimension(d.id) then return false end
    if dungeonBosses[d.id] then return workspace:GetAttribute("Place")=="Dungeon" end
    local arena=bossArena(d.id)
    if arena then
        local phase=arena:GetAttribute("bossState") or "Idle"
        local participant=bossParticipant(arena)
        local requirement=bossConfig and bossConfig.join_requirements and bossConfig.join_requirements[d.id]
        local total=player:GetAttribute("playerListTotalPower")
        if not participant and requirement and requirement.PowerRequirement>0
            and (type(total)~="number" or total<requirement.PowerRequirement) then return false end
        return (phase=="Active" and participant and nearestMob(d.id)~=nil) or phase=="Intermission"
            or (not flags.AutoQuest and Adapter.canStartBoss(d,arena))
    end
    return nearestMob(d.id)~=nil
end
function Adapter.nextBoss()
    local run=mobs.bossRun
    if not run then return end
    Adapter.refreshBossDimension()
    if mobs.IsLive(mobs.target) and run.selected[mobs.target.name] and Adapter.bossInCurrentDimension(mobs.target.name) then
        run.current=mobs.target.name return mobs.catalog[run.current]
    end
    local rows={}
    for id in pairs(run.selected) do
        local d=mobs.catalog[id]
        if d and Adapter.bossAvailable(d) then table.insert(rows,d) end
    end
    table.sort(rows,Adapter.bossPriority)
    for _,d in ipairs(rows) do if not run.served[d.id] then run.current=d.id return d end end
    if #rows>0 then
        table.clear(run.served) run.round+=1 run.current=rows[1].id return rows[1]
    end
    run.current=nil
end
local function prepareBoss(definition,token)
    if not definition.isBoss then return true end
    local id=definition.id
    if dungeonBosses[id] then
        if workspace:GetAttribute("Place")~="Dungeon" then return false,"Waiting for existing dungeon; keys are disabled" end
        if dungeon.state.runningEvents and table.find(dungeon.state.runningEvents,"playersReadyUp") then
            if os.clock()>=dungeon.readyAt then dungeon.readyAt=os.clock()+5 fire("contentReadyUp") end
            return false,"Dungeon: waiting for waves"
        end
        return true
    end
    local arena=bossArena(id)
    if not arena then
        if id=="DemonLord" or id=="TripleT" or id=="BerserkBoss" then
            local target=nearestMob(id)
            if target and bossAttempts[id]~=target.id then
                bossAttempts[id]=target.id
                fire(id=="DemonLord" and "requestDemonLordTeleport" or (id=="BerserkBoss" and "requestBloodMoonBossTeleport" or "requestTripleTTeleport"))
                return waitFor(1,token),"Join existing event"
            end
        end
        return true
    end
    local phase=arena:GetAttribute("bossState") or "Idle"
    if bossParticipant(arena) then
        if phase=="Active" then return true end
        if phase=="Intermission" then return false,"Participation confirmed; waiting for countdown" end
    end
    if phase=="Idle" and Adapter.canStartBoss(definition,arena) then
        local previous=bossAttempts[arena]
        if previous and previous.start and os.clock()-previous.at<8 then return false,"Waiting for START confirmation" end
        local totem=arena:FindFirstChild("Totem")
        local prompt=totem and totem:FindFirstChildWhichIsA("ProximityPrompt",true)
        if not prompt then return false,"START totem is not loaded" end
        bossAttempts[arena]={start=true,at=os.clock()}
        local ok,why=activatePrompt(prompt,token,function() return Adapter.canStartBoss(definition,arena) end)
        if not ok then bossAttempts[arena]=nil return false,why end
        return false,"START sent; waiting for countdown / participation"
    end
    if phase~="Intermission" then return false,"Waiting for another player to start boss · "..phase end
    local identifier=arena:GetAttribute("bossIdentifier")
    if not identifier then return false,"Waiting for active encounter identity" end
    local requirement=bossConfig and bossConfig.join_requirements and bossConfig.join_requirements[id]
    local total=player:GetAttribute("playerListTotalPower")
    if requirement and requirement.PowerRequirement>0 and (type(total)~="number" or total<requirement.PowerRequirement) then
        return false,"Power requirement not met: "..requirement.PowerRequirement
    end
    local previous=bossAttempts[arena]
    if previous and previous.identifier==identifier and os.clock()-previous.at<5 then return false,"Waiting for JOIN confirmation" end
    if not valid(token) or arena:GetAttribute("bossState")~="Intermission" then return false,"Entry window closed" end
    bossAttempts[arena]={identifier=identifier,at=os.clock()}
    local ok,why=fire("bossEncounterChoice",{choice="join",identifier=identifier})
    if not ok then return false,why end
    local deadline=os.clock()+4
    repeat
        if not valid(token) then return false,"Cancelled" end
        if bossParticipant(arena) then
            state.result="Participation confirmed: "..definition.name
            return arena:GetAttribute("bossState")=="Active","Waiting for countdown"
        end
        if not waitFor(0.1,token) then return false,"Cancelled" end
    until os.clock()>=deadline
    return false,"JOIN sent; participation unconfirmed"
end
Adapter.prepareBoss=prepareBoss

-- Metadata from the current game definitions; see research/combat-catalog-current.json.
local combatMetadata={["powers"]={["ConquerorsHaki"]={["baseCooldown"]=16.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["ShukakuBeastBomb"]={["baseCooldown"]=0.0,["bossDamage"]=23.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["Bakudo61"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=0.05,["damageMultiplier"]=1.0},["MultiSlash"]={["baseCooldown"]=8.0,["bossDamage"]=8.0,["startupDelay"]=0.1,["damageMultiplier"]=2.0},["RisingSlash"]={["baseCooldown"]=8.0,["bossDamage"]=25.0,["startupDelay"]=0.1,["damageMultiplier"]=10.0},["AntSlam"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["SixPaths"]={["baseCooldown"]=0.9,["bossDamage"]=0.0,["damageMultiplier"]=0.0,["Transformation"]=true},["NightKickGuy"]={["baseCooldown"]=18.0,["bossDamage"]=30.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["BlackLightning"]={["baseCooldown"]=14.0,["bossDamage"]=38.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["LegendaryKiBlasts"]={["baseCooldown"]=15.0,["bossDamage"]=12.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["SSJ3"]={["baseCooldown"]=4.183,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=0.0,["Transformation"]=true},["FallenDown"]={["baseCooldown"]=45.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=3.0},["Mob100"]={["baseCooldown"]=2.717,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=0.0,["Transformation"]=true},["SeaBeastRoar"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=1.0,["damageMultiplier"]=1.0},["BrolyRush"]={["baseCooldown"]=11.0,["bossDamage"]=21.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["GodsWrath"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=1.1,["damageMultiplier"]=1.0},["RubberSecondGear"]={["baseCooldown"]=2.0,["bossDamage"]=0.0,["damageMultiplier"]=3.0,["Transformation"]=true},["Blink"]={["baseCooldown"]=1.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=0.0},["TripleTSlam"]={["baseCooldown"]=6.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["DragonsBreath"]={["baseCooldown"]=13.0,["bossDamage"]=10.0,["startupDelay"]=0.1,["damageMultiplier"]=8.0},["TornadoSmash"]={["baseCooldown"]=6.0,["bossDamage"]=50.0,["startupDelay"]=0.1,["damageMultiplier"]=20.0},["KingsAura"]={["baseCooldown"]=4.5,["bossDamage"]=0.0,["damageMultiplier"]=3.0,["Transformation"]=true},["FlyingSlash"]={["baseCooldown"]=6.0,["bossDamage"]=90.0,["startupDelay"]=0.2,["damageMultiplier"]=15.0},["BlackFlash"]={["baseCooldown"]=10.0,["bossDamage"]=90.0,["startupDelay"]=0.15,["damageMultiplier"]=35.0},["Onigiri"]={["baseCooldown"]=5.0,["bossDamage"]=100.0,["startupDelay"]=0.35,["damageMultiplier"]=12.0},["PlanetarySpiralSphere"]={["baseCooldown"]=16.0,["bossDamage"]=15.0,["startupDelay"]=0.1,["damageMultiplier"]=8.0},["SuperSaiyan"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=3.0,["Transformation"]=true},["KuramaRoar"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=0.6,["damageMultiplier"]=1.0},["HandDemonHandTornado"]={["baseCooldown"]=0.0,["bossDamage"]=23.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["AntVenomSpit"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["AntBite"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["JudgementCut"]={["baseCooldown"]=8.0,["bossDamage"]=16.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["Zoltraak"]={["baseCooldown"]=16.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["ShadowCrossRed"]={["baseCooldown"]=8.0,["bossDamage"]=22.5,["startupDelay"]=0.1,["damageMultiplier"]=8.0},["SpiralSphere"]={["baseCooldown"]=4.0,["bossDamage"]=40.0,["startupDelay"]=0.1,["damageMultiplier"]=15.0},["PerfectCounter"]={["baseCooldown"]=8.0,["bossDamage"]=60.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["HandDemonRockThrow"]={["baseCooldown"]=0.0,["bossDamage"]=23.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["ExplosiveWave"]={["baseCooldown"]=18.0,["bossDamage"]=22.0,["startupDelay"]=0.0,["damageMultiplier"]=17.0},["BigBangKamehameha"]={["baseCooldown"]=21.0,["bossDamage"]=11.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["GiganticRoar"]={["baseCooldown"]=17.0,["bossDamage"]=32.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["MultiShuriken"]={["baseCooldown"]=8.0,["bossDamage"]=17.0,["startupDelay"]=0.5,["damageMultiplier"]=12.0},["LSSJ"]={["baseCooldown"]=4.183,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=0.0,["Transformation"]=true},["FlameFlight"]={["baseCooldown"]=0.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0},["SpiritualPressure"]={["baseCooldown"]=14.0,["bossDamage"]=11.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["SeaBeastWaterBullet"]={["baseCooldown"]=8.0,["bossDamage"]=0.0,["startupDelay"]=0.5,["damageMultiplier"]=1.0},["AbyssalSeveranceRed"]={["baseCooldown"]=12.0,["bossDamage"]=11.0,["startupDelay"]=0.1,["damageMultiplier"]=6.0},["Flight"]={["baseCooldown"]=0.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0},["BijuuBombPlayer"]={["baseCooldown"]=20.0,["bossDamage"]=10.0,["startupDelay"]=0.3,["damageMultiplier"]=5.0},["HellFlare"]={["baseCooldown"]=17.0,["bossDamage"]=25.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["DivergentDescent"]={["baseCooldown"]=10.0,["bossDamage"]=75.0,["startupDelay"]=0.15,["damageMultiplier"]=25.0},["SeriousTableFlip"]={["baseCooldown"]=18.0,["bossDamage"]=80.0,["startupDelay"]=0.15,["damageMultiplier"]=30.0},["HeavenRestriction"]={["baseCooldown"]=2.2,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=0.0,["Transformation"]=true},["CruelSun"]={["baseCooldown"]=18.0,["bossDamage"]=12.0,["startupDelay"]=0.0,["damageMultiplier"]=11.0},["SeriousPunch"]={["baseCooldown"]=45.0,["bossDamage"]=150.0,["startupDelay"]=0.0,["damageMultiplier"]=80.0},["Rasenshuriken"]={["baseCooldown"]=14.0,["bossDamage"]=6.0,["startupDelay"]=0.3,["damageMultiplier"]=12.0},["ShukakuGroundSmash"]={["baseCooldown"]=0.0,["bossDamage"]=23.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["NormalPunch"]={["baseCooldown"]=8.0,["bossDamage"]=60.0,["startupDelay"]=0.1,["damageMultiplier"]=20.0},["VastoMask"]={["baseCooldown"]=2.617,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=0.0,["Transformation"]=true},["BijuuBomb"]={["baseCooldown"]=5.0,["bossDamage"]=5.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["Megiddo"]={["baseCooldown"]=18.0,["bossDamage"]=11.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["Beelzebub"]={["baseCooldown"]=12.0,["bossDamage"]=25.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["SeaBeastDeadlyShower"]={["baseCooldown"]=10.0,["bossDamage"]=0.0,["startupDelay"]=1.0,["damageMultiplier"]=1.0},["SpiritBomb"]={["baseCooldown"]=10.0,["bossDamage"]=7.0,["startupDelay"]=1.5,["damageMultiplier"]=10.0},["DevilUnion"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=0.0,["Transformation"]=true},["ShukakuWindBullets"]={["baseCooldown"]=0.0,["bossDamage"]=23.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["SuperSaiyan2"]={["baseCooldown"]=2.4,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=0.0,["Transformation"]=true},["ModelSwap"]={["baseCooldown"]=0.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["KuramaSwipe"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=0.485,["damageMultiplier"]=1.0},["SeaOfTrees"]={["baseCooldown"]=10.0,["bossDamage"]=35.0,["startupDelay"]=0.1,["damageMultiplier"]=20.0},["Instinct"]={["baseCooldown"]=30.0,["bossDamage"]=0.0,["damageMultiplier"]=0.0},["Hamon"]={["baseCooldown"]=2.0,["bossDamage"]=0.0,["Transformation"]=true},["Susanoo"]={["baseCooldown"]=0.9,["bossDamage"]=15.0,["damageMultiplier"]=15.0,["Transformation"]=true},["FourthGate"]={["baseCooldown"]=2.0,["bossDamage"]=0.0,["damageMultiplier"]=0.0,["Transformation"]=true},["EnemyAttack"]={["baseCooldown"]=1.0,["bossDamage"]=0.0,["startupDelay"]=0.25,["damageMultiplier"]=1.0},["SeaBeastBite"]={["baseCooldown"]=4.0,["bossDamage"]=0.0,["startupDelay"]=0.3,["damageMultiplier"]=1.0},["PurgatoryOnigiri"]={["baseCooldown"]=6.0,["bossDamage"]=200.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["FlashStep"]={["baseCooldown"]=5.2,["bossDamage"]=0.0,["damageMultiplier"]=1.0},["MeteorShower"]={["baseCooldown"]=16.0,["bossDamage"]=27.5,["startupDelay"]=0.0,["damageMultiplier"]=13.0},["DragonFist"]={["baseCooldown"]=16.0,["bossDamage"]=95.0,["startupDelay"]=0.0,["damageMultiplier"]=26.0},["HandDemonEnragedCharge"]={["baseCooldown"]=0.0,["bossDamage"]=23.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["MegiddoInfernus"]={["baseCooldown"]=20.0,["bossDamage"]=22.5,["startupDelay"]=0.2,["damageMultiplier"]=12.0},["KiBlasts"]={["baseCooldown"]=12.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["RapidPunch"]={["baseCooldown"]=5.0,["bossDamage"]=2.5,["startupDelay"]=0.45,["damageMultiplier"]=1.0},["RapidPunchRework"]={["baseCooldown"]=5.0,["bossDamage"]=1.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["Dash"]={["baseCooldown"]=1.5,["bossDamage"]=0.0,["damageMultiplier"]=1.0},["SeaBeastDive"]={["baseCooldown"]=6.0,["bossDamage"]=0.0,["startupDelay"]=0.5,["damageMultiplier"]=1.0},["EnergyBlast"]={["baseCooldown"]=8.0,["bossDamage"]=10.0,["startupDelay"]=0.7,["damageMultiplier"]=8.0},["GatesOfBabylon"]={["baseCooldown"]=13.0,["bossDamage"]=12.5,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["FlareKick"]={["baseCooldown"]=10.0,["bossDamage"]=75.0,["startupDelay"]=0.0,["damageMultiplier"]=11.0},["RubberGatling"]={["baseCooldown"]=12.0,["bossDamage"]=5.5,["startupDelay"]=0.45,["damageMultiplier"]=3.0},["LichtPiercer"]={["baseCooldown"]=7.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["BeastCleave"]={["baseCooldown"]=16.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["VoidSteps"]={["baseCooldown"]=12.0,["bossDamage"]=20.0,["startupDelay"]=0.1,["damageMultiplier"]=9.0},["BarrierSurge"]={["baseCooldown"]=20.0,["bossDamage"]=70.0,["startupDelay"]=0.0,["damageMultiplier"]=18.0},["GravityCrush"]={["baseCooldown"]=8.0,["bossDamage"]=65.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["GravityChamber"]={["baseCooldown"]=13.0,["bossDamage"]=12.5,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["MalevolentShrine"]={["baseCooldown"]=9.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["FlashfireJetKindle"]={["baseCooldown"]=16.0,["bossDamage"]=5.0,["startupDelay"]=0.4,["damageMultiplier"]=10.0},["IceSurf"]={["baseCooldown"]=12.0,["bossDamage"]=2.5,["startupDelay"]=0.1,["damageMultiplier"]=6.0},["AlmightyPull"]={["baseCooldown"]=12.0,["bossDamage"]=70.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["FireFly"]={["baseCooldown"]=8.0,["bossDamage"]=20.0,["startupDelay"]=0.15,["damageMultiplier"]=10.0},["ArmoredSusanoo"]={["baseCooldown"]=30.0,["bossDamage"]=30.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["BreathBlast"]={["baseCooldown"]=7.0,["bossDamage"]=7.5,["startupDelay"]=0.4,["damageMultiplier"]=7.0},["StringPerformance"]={["baseCooldown"]=25.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=11.0},["RegularCero"]={["baseCooldown"]=11.0,["bossDamage"]=45.0,["startupDelay"]=0.0,["damageMultiplier"]=16.0},["FullCowlTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=0.0},["MagmaFist"]={["baseCooldown"]=14.0,["bossDamage"]=8.0,["startupDelay"]=0.175,["damageMultiplier"]=10.0},["DebugCutscene"]={["baseCooldown"]=0.0,["bossDamage"]=1e+50,["startupDelay"]=0.0,["damageMultiplier"]=1e+50},["EarthRend"]={["baseCooldown"]=11.0,["bossDamage"]=85.0,["startupDelay"]=0.25,["damageMultiplier"]=16.0},["RoadRoller"]={["baseCooldown"]=15.0,["bossDamage"]=11.5,["startupDelay"]=0.7,["damageMultiplier"]=12.0},["BarrierSlam"]={["baseCooldown"]=14.0,["bossDamage"]=60.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["WaterShield"]={["baseCooldown"]=12.0,["bossDamage"]=75.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["GyutaroMechanic"]={["baseCooldown"]=0.0,["bossDamage"]=4.5,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["DivineRetribution"]={["baseCooldown"]=18.0,["bossDamage"]=60.0,["startupDelay"]=0.9,["damageMultiplier"]=18.0},["KnivesThrow"]={["baseCooldown"]=6.0,["bossDamage"]=80.0,["startupDelay"]=0.95,["damageMultiplier"]=28.0},["YojunSenka"]={["baseCooldown"]=14.0,["bossDamage"]=70.0,["startupDelay"]=0.4,["damageMultiplier"]=12.0},["ChronoBarrage"]={["baseCooldown"]=11.0,["bossDamage"]=31.0,["startupDelay"]=0.0,["damageMultiplier"]=11.5},["CeroDespiadada"]={["baseCooldown"]=17.0,["bossDamage"]=12.5,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["RatioCut"]={["baseCooldown"]=10.0,["bossDamage"]=75.0,["startupDelay"]=0.225,["damageMultiplier"]=20.0},["DetroitSmash"]={["baseCooldown"]=8.0,["bossDamage"]=80.0,["startupDelay"]=0.4,["damageMultiplier"]=11.0},["LightningStrikes"]={["baseCooldown"]=12.0,["bossDamage"]=28.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["LightKick"]={["baseCooldown"]=7.0,["bossDamage"]=45.0,["startupDelay"]=0.1,["damageMultiplier"]=15.0},["HeavenlyImpact"]={["baseCooldown"]=10.0,["bossDamage"]=100.0,["startupDelay"]=0.65,["damageMultiplier"]=24.0},["SandCoffin"]={["baseCooldown"]=11.0,["bossDamage"]=8.0,["startupDelay"]=0.2,["damageMultiplier"]=4.0},["LightningBarrage"]={["baseCooldown"]=12.0,["bossDamage"]=20.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["ExplosiveBeads"]={["baseCooldown"]=10.0,["bossDamage"]=25.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["Torch"]={["baseCooldown"]=10.0,["bossDamage"]=75.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["StarPlatinum_Barrage"]={["baseCooldown"]=2.0,["bossDamage"]=1.0,["startupDelay"]=0.1,["damageMultiplier"]=1.0},["OneEyeTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["CrimsonFault"]={["baseCooldown"]=10.0,["bossDamage"]=100.0,["startupDelay"]=0.0,["damageMultiplier"]=18.0},["LightningCharge"]={["baseCooldown"]=9.0,["bossDamage"]=24.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["ShrineDomainExpansionPlayer"]={["baseCooldown"]=120.0,["bossDamage"]=8.0,["startupDelay"]=0.0,["damageMultiplier"]=3.0},["Gear4Bazooka"]={["baseCooldown"]=20.0,["bossDamage"]=95.0,["startupDelay"]=0.6,["damageMultiplier"]=24.0},["KaijuBarrage"]={["baseCooldown"]=11.0,["bossDamage"]=8.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["Liberation"]={["baseCooldown"]=15.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["LightSaber"]={["baseCooldown"]=7.0,["bossDamage"]=70.0,["startupDelay"]=0.25,["damageMultiplier"]=25.0},["TitanRampage"]={["baseCooldown"]=16.0,["bossDamage"]=30.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["KanekiJab"]={["baseCooldown"]=6.0,["bossDamage"]=40.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["StarrkWolves"]={["baseCooldown"]=20.0,["bossDamage"]=25.0,["startupDelay"]=0.583,["damageMultiplier"]=13.0},["SandSageModeBeastBomb"]={["baseCooldown"]=14.0,["bossDamage"]=95.0,["startupDelay"]=0.0,["damageMultiplier"]=17.0},["ChronoBolt"]={["baseCooldown"]=8.0,["bossDamage"]=27.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["Annihilation"]={["baseCooldown"]=34.0,["bossDamage"]=13.5,["startupDelay"]=0.0,["damageMultiplier"]=11.0},["GonPaper"]={["baseCooldown"]=15.0,["bossDamage"]=125.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["LightRain"]={["baseCooldown"]=7.0,["bossDamage"]=16.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["RugidoDelVacio"]={["baseCooldown"]=18.0,["bossDamage"]=13.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["WaterBullet"]={["baseCooldown"]=5.0,["bossDamage"]=75.0,["startupDelay"]=0.0,["damageMultiplier"]=11.0},["CursedEnergyBlast"]={["baseCooldown"]=30.0,["bossDamage"]=8.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["SpiritArrow"]={["baseCooldown"]=14.0,["bossDamage"]=30.0,["startupDelay"]=0.0,["damageMultiplier"]=11.0},["RatioSmash"]={["baseCooldown"]=8.0,["bossDamage"]=50.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["Fuga"]={["baseCooldown"]=25.0,["bossDamage"]=11.0,["startupDelay"]=1.7,["damageMultiplier"]=8.0},["SandSageModeRoar"]={["baseCooldown"]=16.0,["bossDamage"]=20.0,["startupDelay"]=0.833,["damageMultiplier"]=10.0},["SheerHeartAttack"]={["baseCooldown"]=12.0,["bossDamage"]=80.0,["startupDelay"]=0.3,["damageMultiplier"]=24.0},["DivergentPunch"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["WrathfulOutcry"]={["baseCooldown"]=13.0,["bossDamage"]=55.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["BarrierExpansion"]={["baseCooldown"]=8.0,["bossDamage"]=45.0,["startupDelay"]=0.2,["damageMultiplier"]=8.0},["CursedHell"]={["baseCooldown"]=16.0,["bossDamage"]=7.0,["startupDelay"]=0.6,["damageMultiplier"]=4.0},["Appetizer"]={["baseCooldown"]=8.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["Senbonzakura"]={["baseCooldown"]=8.0,["bossDamage"]=50.0,["startupDelay"]=0.4,["damageMultiplier"]=10.0},["USASmash"]={["baseCooldown"]=23.0,["bossDamage"]=145.0,["startupDelay"]=0.45,["damageMultiplier"]=18.0},["FinalCero"]={["baseCooldown"]=14.0,["bossDamage"]=14.0,["startupDelay"]=0.0,["damageMultiplier"]=4.0},["CentipedeMindBreak"]={["baseCooldown"]=12.0,["bossDamage"]=6.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["BlazingUniverse"]={["baseCooldown"]=8.0,["bossDamage"]=85.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["AccelerationField"]={["baseCooldown"]=2.0,["bossDamage"]=1.0,["startupDelay"]=0.1,["damageMultiplier"]=1.0},["JetPistol"]={["baseCooldown"]=8.0,["bossDamage"]=65.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["ColossalNuke"]={["baseCooldown"]=48.0,["bossDamage"]=21.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["RisingPhoenix"]={["baseCooldown"]=24.0,["bossDamage"]=18.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["RikaPunch"]={["baseCooldown"]=8.0,["bossDamage"]=62.0,["startupDelay"]=0.0,["damageMultiplier"]=25.0},["Ittai"]={["baseCooldown"]=15.0,["bossDamage"]=60.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["FlamingKick"]={["baseCooldown"]=6.0,["bossDamage"]=65.0,["startupDelay"]=0.4,["damageMultiplier"]=8.0},["GroundStab"]={["baseCooldown"]=18.0,["bossDamage"]=70.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["Enkai"]={["baseCooldown"]=25.0,["bossDamage"]=11.0,["startupDelay"]=0.8,["damageMultiplier"]=8.0},["RevolvingSky"]={["baseCooldown"]=8.0,["bossDamage"]=4.5,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["AzureInferno"]={["baseCooldown"]=16.0,["bossDamage"]=22.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["SandBeastModeTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["Screech"]={["baseCooldown"]=15.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["FlameTiger"]={["baseCooldown"]=20.0,["bossDamage"]=100.0,["startupDelay"]=0.0,["damageMultiplier"]=23.0},["GlacialSurge"]={["baseCooldown"]=12.0,["bossDamage"]=75.0,["startupDelay"]=0.3,["damageMultiplier"]=20.0},["Gear4Transform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=30.0,["Transformation"]=true},["TsukiyamaSlam"]={["baseCooldown"]=10.0,["bossDamage"]=50.0,["startupDelay"]=0.1,["damageMultiplier"]=20.0},["FullManchesterSmash"]={["baseCooldown"]=12.0,["bossDamage"]=90.0,["startupDelay"]=0.4,["damageMultiplier"]=14.0},["KingsDescent"]={["baseCooldown"]=18.0,["bossDamage"]=15.0,["startupDelay"]=0.017,["damageMultiplier"]=8.0},["WaterBomb"]={["baseCooldown"]=9.0,["bossDamage"]=25.0,["startupDelay"]=0.2,["damageMultiplier"]=9.0},["ThousandSlashes"]={["baseCooldown"]=9.0,["bossDamage"]=7.75,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["YouWerentInvited"]={["baseCooldown"]=12.0,["bossDamage"]=65.0,["startupDelay"]=0.5,["damageMultiplier"]=35.0},["SandBeastModeRoar"]={["baseCooldown"]=16.0,["bossDamage"]=19.0,["startupDelay"]=0.833,["damageMultiplier"]=8.0},["RubberPistol"]={["baseCooldown"]=6.0,["bossDamage"]=40.0,["startupDelay"]=0.15,["damageMultiplier"]=10.0},["MagmaEruption"]={["baseCooldown"]=12.0,["bossDamage"]=15.0,["startupDelay"]=0.4,["damageMultiplier"]=9.0},["KanekiBarrage"]={["baseCooldown"]=6.0,["bossDamage"]=4.5,["startupDelay"]=0.0,["damageMultiplier"]=3.0},["Detonate"]={["baseCooldown"]=10.0,["bossDamage"]=75.0,["startupDelay"]=0.3,["damageMultiplier"]=16.0},["TornadoSlash"]={["baseCooldown"]=35.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=4.0},["IcePartisan"]={["baseCooldown"]=5.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["HeavenlyVolley"]={["baseCooldown"]=7.0,["bossDamage"]=7.0,["startupDelay"]=0.0,["damageMultiplier"]=3.0},["RubberBazooka"]={["baseCooldown"]=9.0,["bossDamage"]=55.0,["startupDelay"]=0.01,["damageMultiplier"]=20.0},["InsectEruption"]={["baseCooldown"]=10.0,["bossDamage"]=45.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["ReflectionKick"]={["baseCooldown"]=11.0,["bossDamage"]=75.0,["startupDelay"]=0.25,["damageMultiplier"]=18.0},["ArmoredRain"]={["baseCooldown"]=20.0,["bossDamage"]=20.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["GreatApeAerialSlam"]={["baseCooldown"]=12.0,["bossDamage"]=90.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["BlazingVortex"]={["baseCooldown"]=14.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=13.0},["MoltenCore"]={["baseCooldown"]=10.0,["bossDamage"]=65.0,["startupDelay"]=0.15,["damageMultiplier"]=30.0},["GetsugoTensho"]={["baseCooldown"]=10.0,["bossDamage"]=60.0,["startupDelay"]=0.2,["damageMultiplier"]=8.0},["SandBerserkModeRoar"]={["baseCooldown"]=12.0,["bossDamage"]=18.0,["startupDelay"]=0.5,["damageMultiplier"]=8.0},["GranCeroOscuras"]={["baseCooldown"]=32.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["GetsugoRush"]={["baseCooldown"]=25.0,["bossDamage"]=8.0,["startupDelay"]=0.0,["damageMultiplier"]=16.0},["LanzaDelRelampago"]={["baseCooldown"]=30.0,["bossDamage"]=35.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["MagmaBarrage"]={["baseCooldown"]=7.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["GonRock"]={["baseCooldown"]=9.0,["bossDamage"]=105.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["RulersAuthority"]={["baseCooldown"]=32.0,["bossDamage"]=4.0,["startupDelay"]=0.1,["damageMultiplier"]=4.0},["WindBullet"]={["baseCooldown"]=6.0,["bossDamage"]=65.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["TrigramGrid"]={["baseCooldown"]=16.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["KingsRupture"]={["baseCooldown"]=8.0,["bossDamage"]=65.0,["startupDelay"]=0.075,["damageMultiplier"]=14.0},["RubberAxe"]={["baseCooldown"]=7.0,["bossDamage"]=50.0,["startupDelay"]=0.1,["damageMultiplier"]=15.0},["SandSageModeSandShuriken"]={["baseCooldown"]=22.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["LoathsomeMoon"]={["baseCooldown"]=24.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["MonstersTrail"]={["baseCooldown"]=14.0,["bossDamage"]=6.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["MoonGazing"]={["baseCooldown"]=14.0,["bossDamage"]=17.5,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["GonDeparture"]={["baseCooldown"]=20.0,["bossDamage"]=50.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["OneEyeRoar"]={["baseCooldown"]=13.0,["bossDamage"]=15.0,["startupDelay"]=0.4,["damageMultiplier"]=6.0},["RikaRoar"]={["baseCooldown"]=15.0,["bossDamage"]=8.5,["startupDelay"]=0.6,["damageMultiplier"]=5.0},["PerceptionElevation"]={["baseCooldown"]=26.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["SpinAttack"]={["baseCooldown"]=17.0,["bossDamage"]=20.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["BlackMatter"]={["baseCooldown"]=19.0,["bossDamage"]=6.5,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["SandBerserkModeTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["SandBeastModeBeastBomb"]={["baseCooldown"]=12.0,["bossDamage"]=90.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["CentipedeSlam"]={["baseCooldown"]=7.0,["bossDamage"]=65.0,["startupDelay"]=0.067,["damageMultiplier"]=25.0},["BarrierRush"]={["baseCooldown"]=10.0,["bossDamage"]=50.0,["startupDelay"]=0.4,["damageMultiplier"]=12.0},["InfiniteVoid"]={["baseCooldown"]=35.0,["bossDamage"]=4.0,["startupDelay"]=0.0,["damageMultiplier"]=2.0},["AlmightyPush"]={["baseCooldown"]=8.0,["bossDamage"]=65.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["DebugStandBarrage"]={["baseCooldown"]=5.0,["bossDamage"]=1e+50,["startupDelay"]=0.0,["damageMultiplier"]=1e+50},["EveryLastDrop"]={["baseCooldown"]=20.0,["bossDamage"]=5.75,["startupDelay"]=0.4,["damageMultiplier"]=5.0},["ColossalSteamBurst"]={["baseCooldown"]=24.0,["bossDamage"]=20.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["ArmoredTitanTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=30.0,["Transformation"]=true},["Gear4Barrage"]={["baseCooldown"]=10.0,["bossDamage"]=5.0,["startupDelay"]=0.2,["damageMultiplier"]=2.5},["TitanRage"]={["baseCooldown"]=32.0,["bossDamage"]=30.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["LapseBlue"]={["baseCooldown"]=12.0,["bossDamage"]=5.0,["startupDelay"]=0.2,["damageMultiplier"]=7.0},["ThousandArrows"]={["baseCooldown"]=25.0,["bossDamage"]=16.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["Shredder"]={["baseCooldown"]=12.0,["bossDamage"]=35.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["Mirage"]={["baseCooldown"]=8.0,["bossDamage"]=17.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["BlastRush"]={["baseCooldown"]=7.0,["bossDamage"]=40.0,["startupDelay"]=0.4,["damageMultiplier"]=8.0},["SoundBreathingRoar"]={["baseCooldown"]=14.0,["bossDamage"]=40.0,["startupDelay"]=0.0,["damageMultiplier"]=16.0},["FeralCleave"]={["baseCooldown"]=18.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["PheasantBeak"]={["baseCooldown"]=9.0,["bossDamage"]=80.0,["startupDelay"]=0.5,["damageMultiplier"]=22.0},["ChopWhirlwind"]={["baseCooldown"]=6.0,["bossDamage"]=4.5,["startupDelay"]=0.05,["damageMultiplier"]=3.0},["WhiteTigerTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["ConstantResounding"]={["baseCooldown"]=17.0,["bossDamage"]=11.5,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["SwordSkyJudgement"]={["baseCooldown"]=11.0,["bossDamage"]=16.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["GreatApeDeathBeam"]={["baseCooldown"]=15.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["GonScissors"]={["baseCooldown"]=11.0,["bossDamage"]=110.0,["startupDelay"]=0.0,["damageMultiplier"]=16.0},["InsectTornado"]={["baseCooldown"]=13.0,["bossDamage"]=4.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["ThunderClap"]={["baseCooldown"]=8.0,["bossDamage"]=70.0,["startupDelay"]=0.0,["damageMultiplier"]=16.0},["SwordStrike"]={["baseCooldown"]=15.0,["bossDamage"]=25.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["TrueBankaiTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["SovereignJudgment"]={["baseCooldown"]=32.0,["bossDamage"]=20.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["InsectAssault"]={["baseCooldown"]=8.0,["bossDamage"]=3.0,["startupDelay"]=0.25,["damageMultiplier"]=4.0},["PhantomCut"]={["baseCooldown"]=8.0,["bossDamage"]=60.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["ChopGoKart"]={["baseCooldown"]=8.0,["bossDamage"]=5.0,["startupDelay"]=0.5,["damageMultiplier"]=8.0},["OneEyeBarrage"]={["baseCooldown"]=9.0,["bossDamage"]=5.0,["startupDelay"]=0.0,["damageMultiplier"]=4.0},["GrimoireWhirlWindStorm"]={["baseCooldown"]=14.0,["bossDamage"]=19.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["ByakuganActivate"]={["baseCooldown"]=8.0,["bossDamage"]=55.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["DevouringClaw"]={["baseCooldown"]=16.0,["bossDamage"]=135.0,["startupDelay"]=0.1,["damageMultiplier"]=16.0},["SoulSplitter"]={["baseCooldown"]=12.0,["bossDamage"]=80.0,["startupDelay"]=0.45,["damageMultiplier"]=20.0},["CompassNeedle"]={["baseCooldown"]=8.0,["bossDamage"]=87.5,["startupDelay"]=0.0,["damageMultiplier"]=25.0},["ChronoSphere"]={["baseCooldown"]=17.0,["bossDamage"]=21.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["WaterfallBasin"]={["baseCooldown"]=10.0,["bossDamage"]=7.5,["startupDelay"]=0.0,["damageMultiplier"]=9.5},["WaterWheel"]={["baseCooldown"]=14.0,["bossDamage"]=9.5,["startupDelay"]=0.0,["damageMultiplier"]=11.0},["Gokei"]={["baseCooldown"]=22.0,["bossDamage"]=10.0,["startupDelay"]=0.3,["damageMultiplier"]=5.0},["YamoriGrinder"]={["baseCooldown"]=10.0,["bossDamage"]=4.0,["startupDelay"]=0.2,["damageMultiplier"]=4.0},["RatioPunch"]={["baseCooldown"]=5.0,["bossDamage"]=40.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["PerfectSusanooTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=30.0,["Transformation"]=true},["ShadowCross"]={["baseCooldown"]=8.0,["bossDamage"]=22.5,["startupDelay"]=0.1,["damageMultiplier"]=8.0},["Amaterasu"]={["baseCooldown"]=12.0,["bossDamage"]=17.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["FireShots"]={["baseCooldown"]=8.0,["bossDamage"]=8.0,["startupDelay"]=1.0,["damageMultiplier"]=4.0},["TitanThrow"]={["baseCooldown"]=12.0,["bossDamage"]=75.0,["startupDelay"]=0.0,["damageMultiplier"]=25.0},["AttackTitanTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=30.0,["Transformation"]=true},["TitanHeal"]={["baseCooldown"]=65.0,["bossDamage"]=30.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["Ephemeral"]={["baseCooldown"]=22.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=13.0},["GraniteBlast"]={["baseCooldown"]=8.0,["bossDamage"]=7.0,["startupDelay"]=0.3,["damageMultiplier"]=5.0},["SandSpada"]={["baseCooldown"]=15.0,["bossDamage"]=90.0,["startupDelay"]=0.2,["damageMultiplier"]=25.0},["FlamePillar"]={["baseCooldown"]=12.0,["bossDamage"]=7.0,["startupDelay"]=0.05,["damageMultiplier"]=5.0},["MultiSlash_SilverChariot"]={["baseCooldown"]=7.0,["bossDamage"]=5.0,["startupDelay"]=0.1,["damageMultiplier"]=5.0},["Genjutsu"]={["baseCooldown"]=10.0,["bossDamage"]=60.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["GravityMeteorShower"]={["baseCooldown"]=22.0,["bossDamage"]=20.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["YamoriJab"]={["baseCooldown"]=6.0,["bossDamage"]=50.0,["startupDelay"]=0.1,["damageMultiplier"]=15.0},["ShrineDomainExpansion"]={["baseCooldown"]=30.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["WhirlWindStorm"]={["baseCooldown"]=10.0,["bossDamage"]=80.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["CrazyDiamondHealMode"]={["baseCooldown"]=15.0,["bossDamage"]=90.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["SpeechDontMove"]={["baseCooldown"]=15.0,["bossDamage"]=0.0,["startupDelay"]=0.2,["damageMultiplier"]=1.0},["KillEntitiesInRadius"]={["baseCooldown"]=1.0,["bossDamage"]=1e+50,["startupDelay"]=0.0,["damageMultiplier"]=1e+50},["YamoriSpin"]={["baseCooldown"]=6.0,["bossDamage"]=5.5,["startupDelay"]=0.0,["damageMultiplier"]=4.0},["BarringShot"]={["baseCooldown"]=11.0,["bossDamage"]=40.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["TwinBladeDance"]={["baseCooldown"]=23.0,["bossDamage"]=20.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["ReversalRed"]={["baseCooldown"]=7.0,["bossDamage"]=80.0,["startupDelay"]=0.0,["damageMultiplier"]=25.0},["StandBarrage"]={["baseCooldown"]=5.0,["bossDamage"]=1.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["IceSpikes"]={["baseCooldown"]=9.0,["bossDamage"]=60.0,["startupDelay"]=0.5,["damageMultiplier"]=13.0},["SandBeastModeSlam"]={["baseCooldown"]=8.0,["bossDamage"]=84.0,["startupDelay"]=0.633,["damageMultiplier"]=12.0},["ColossalTitanTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=30.0,["Transformation"]=true},["TwilightOfTheGods"]={["baseCooldown"]=30.0,["bossDamage"]=30.0,["startupDelay"]=1.2,["damageMultiplier"]=9.0},["Guillotine"]={["baseCooldown"]=14.0,["bossDamage"]=75.0,["startupDelay"]=0.1,["damageMultiplier"]=16.0},["TsukiyamaDash"]={["baseCooldown"]=7.0,["bossDamage"]=40.0,["startupDelay"]=0.15,["damageMultiplier"]=15.0},["CrazyDiamondSmash"]={["baseCooldown"]=8.0,["bossDamage"]=70.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["GigantPistol"]={["baseCooldown"]=12.0,["bossDamage"]=85.0,["startupDelay"]=0.0,["damageMultiplier"]=24.0},["FlashfreezeHeatwave"]={["baseCooldown"]=21.0,["bossDamage"]=5.0,["startupDelay"]=0.2,["damageMultiplier"]=15.0},["DivergentSmash"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["TitanRun"]={["baseCooldown"]=8.0,["bossDamage"]=30.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["CleaveDismantle"]={["baseCooldown"]=8.0,["bossDamage"]=18.0,["startupDelay"]=0.1,["damageMultiplier"]=7.0},["LotusStrike"]={["baseCooldown"]=13.0,["bossDamage"]=110.0,["startupDelay"]=0.0,["damageMultiplier"]=21.0},["EnGarde"]={["baseCooldown"]=6.0,["bossDamage"]=60.0,["startupDelay"]=0.3,["damageMultiplier"]=10.0},["BerserkRush"]={["baseCooldown"]=10.0,["bossDamage"]=45.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["PhoenixFullTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["MagmaShower"]={["baseCooldown"]=25.0,["bossDamage"]=5.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["SandBerserkModeSlam"]={["baseCooldown"]=7.0,["bossDamage"]=80.0,["startupDelay"]=0.633,["damageMultiplier"]=10.0},["GodSlayer"]={["baseCooldown"]=7.0,["bossDamage"]=6.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["MadeInHeaven_Barrage"]={["baseCooldown"]=2.0,["bossDamage"]=1.0,["startupDelay"]=0.1,["damageMultiplier"]=1.0},["SandSageModeTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["GreatApeTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=30.0,["Transformation"]=true},["TrueBankaiBarrage"]={["baseCooldown"]=9.0,["bossDamage"]=7.5,["startupDelay"]=0.0,["damageMultiplier"]=3.5},["SummoningJutsu"]={["baseCooldown"]=12.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["CoreBreaker"]={["baseCooldown"]=23.0,["bossDamage"]=11.5,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["StunGrenade"]={["baseCooldown"]=9.0,["bossDamage"]=50.0,["startupDelay"]=0.4,["damageMultiplier"]=10.0},["Rengoku"]={["baseCooldown"]=27.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["KanekiLeap"]={["baseCooldown"]=8.0,["bossDamage"]=55.0,["startupDelay"]=0.0,["damageMultiplier"]=17.0},["KillAllEntities"]={["baseCooldown"]=1.0,["bossDamage"]=1e+50,["startupDelay"]=0.0,["damageMultiplier"]=1e+50},["AssassinsArt"]={["baseCooldown"]=6.0,["bossDamage"]=17.5,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["CeroBala"]={["baseCooldown"]=10.0,["bossDamage"]=20.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["ShadowBarrage"]={["baseCooldown"]=9.0,["bossDamage"]=5.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["ArmoredArrow"]={["baseCooldown"]=15.0,["bossDamage"]=90.0,["startupDelay"]=0.0,["damageMultiplier"]=18.0},["IcyGlare"]={["baseCooldown"]=10.0,["bossDamage"]=25.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["TidesOfTime"]={["baseCooldown"]=32.0,["bossDamage"]=8.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["SkyRippingFist"]={["baseCooldown"]=20.0,["bossDamage"]=7.5,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["TenjiKaijin"]={["baseCooldown"]=18.0,["bossDamage"]=100.0,["startupDelay"]=0.167,["damageMultiplier"]=18.0},["BaranJumpSlam"]={["baseCooldown"]=8.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["Erasure"]={["baseCooldown"]=8.0,["bossDamage"]=50.0,["startupDelay"]=0.1,["damageMultiplier"]=8.0},["AbyssalSeverance"]={["baseCooldown"]=12.0,["bossDamage"]=11.0,["startupDelay"]=0.1,["damageMultiplier"]=6.0},["GreatFajin"]={["baseCooldown"]=10.0,["bossDamage"]=8.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["CeroSierra"]={["baseCooldown"]=13.0,["bossDamage"]=13.5,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["ColossalStomp"]={["baseCooldown"]=16.0,["bossDamage"]=80.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["PsychicPull"]={["baseCooldown"]=7.0,["bossDamage"]=75.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["SpaceErasure"]={["baseCooldown"]=8.0,["bossDamage"]=70.0,["startupDelay"]=0.1,["damageMultiplier"]=8.0},["KaijuTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["GodlikeSpeed"]={["baseCooldown"]=14.0,["bossDamage"]=40.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["TormentaDeMurcielago"]={["baseCooldown"]=21.0,["bossDamage"]=30.0,["startupDelay"]=0.0,["damageMultiplier"]=16.0},["MoonDragon"]={["baseCooldown"]=8.0,["bossDamage"]=85.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["PsychicRicochet"]={["baseCooldown"]=28.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["PlanetaryDevastation"]={["baseCooldown"]=20.0,["bossDamage"]=5.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["CeroBarrido"]={["baseCooldown"]=12.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["ShockPunch"]={["baseCooldown"]=6.0,["bossDamage"]=30.0,["startupDelay"]=0.1,["damageMultiplier"]=12.0},["RadiantFault"]={["baseCooldown"]=16.0,["bossDamage"]=17.0,["startupDelay"]=0.0,["damageMultiplier"]=19.0},["SandSageModeSlam"]={["baseCooldown"]=11.0,["bossDamage"]=90.0,["startupDelay"]=0.6,["damageMultiplier"]=15.0},["HollowRoar"]={["baseCooldown"]=12.0,["bossDamage"]=9.0,["startupDelay"]=0.3,["damageMultiplier"]=10.0},["BuddhaTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["DescensoDelCero"]={["baseCooldown"]=16.0,["bossDamage"]=18.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["BlackMoon"]={["baseCooldown"]=11.0,["bossDamage"]=115.0,["startupDelay"]=0.0,["damageMultiplier"]=22.0},["GunShot"]={["baseCooldown"]=9.0,["bossDamage"]=65.0,["startupDelay"]=0.0,["damageMultiplier"]=11.0},["CeroDevastacion"]={["baseCooldown"]=15.0,["bossDamage"]=12.5,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["Asteroid"]={["baseCooldown"]=18.0,["bossDamage"]=80.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["ScorchingHell"]={["baseCooldown"]=40.0,["bossDamage"]=2.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["TimeMolotov"]={["baseCooldown"]=18.0,["bossDamage"]=8.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["CrossHurricane"]={["baseCooldown"]=10.0,["bossDamage"]=55.0,["startupDelay"]=0.883,["damageMultiplier"]=10.0},["SilverChariot_Barrage"]={["baseCooldown"]=5.0,["bossDamage"]=3.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["TrigramAssault"]={["baseCooldown"]=14.0,["bossDamage"]=5.5,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["PredatorPounce"]={["baseCooldown"]=10.0,["bossDamage"]=80.0,["startupDelay"]=0.0,["damageMultiplier"]=22.0},["IceAwakening"]={["baseCooldown"]=21.0,["bossDamage"]=120.0,["startupDelay"]=0.6,["damageMultiplier"]=27.0},["VastoTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["BlastClutcher"]={["baseCooldown"]=8.0,["bossDamage"]=50.0,["startupDelay"]=0.1,["damageMultiplier"]=16.0},["OverhaulPunch"]={["baseCooldown"]=9.0,["bossDamage"]=80.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["LightningThrow"]={["baseCooldown"]=14.0,["bossDamage"]=25.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["Reassemble"]={["baseCooldown"]=28.0,["bossDamage"]=100.0,["startupDelay"]=0.25,["damageMultiplier"]=24.0},["RockBarrage"]={["baseCooldown"]=14.0,["bossDamage"]=20.0,["startupDelay"]=0.0,["damageMultiplier"]=13.0},["FinalGetsugoTensho"]={["baseCooldown"]=30.0,["bossDamage"]=17.0,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["HardenFist"]={["baseCooldown"]=34.0,["bossDamage"]=30.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["BitesTheDust"]={["baseCooldown"]=18.0,["bossDamage"]=90.0,["startupDelay"]=0.75,["damageMultiplier"]=20.0},["HollowPurple"]={["baseCooldown"]=25.0,["bossDamage"]=140.0,["startupDelay"]=0.3,["damageMultiplier"]=32.0},["SpeechExplode"]={["baseCooldown"]=12.0,["bossDamage"]=9.0,["startupDelay"]=0.5,["damageMultiplier"]=6.0},["SpeechBlastAway"]={["baseCooldown"]=8.0,["bossDamage"]=12.0,["startupDelay"]=0.4,["damageMultiplier"]=5.0},["PhoenixTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=1.0,["Transformation"]=true},["LightAnnihilation"]={["baseCooldown"]=16.0,["bossDamage"]=11.5,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["StarFinger"]={["baseCooldown"]=7.0,["bossDamage"]=85.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["EraseAcceleration"]={["baseCooldown"]=10.0,["bossDamage"]=55.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["IkkaSenjekai"]={["baseCooldown"]=10.0,["bossDamage"]=5.0,["startupDelay"]=0.7,["damageMultiplier"]=4.0},["JetGatling"]={["baseCooldown"]=6.0,["bossDamage"]=6.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["HowitzerImpact"]={["baseCooldown"]=15.0,["bossDamage"]=75.0,["startupDelay"]=0.1,["damageMultiplier"]=13.0},["MirrorOfMisfortune"]={["baseCooldown"]=13.0,["bossDamage"]=25.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["CentipedeSpin"]={["baseCooldown"]=5.0,["bossDamage"]=8.5,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["ArrowVolley"]={["baseCooldown"]=10.0,["bossDamage"]=12.5,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["GonRetribution"]={["baseCooldown"]=12.0,["bossDamage"]=50.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["OFASurge"]={["baseCooldown"]=16.0,["bossDamage"]=5.0,["startupDelay"]=0.45,["damageMultiplier"]=10.0},["AcidSlam"]={["baseCooldown"]=14.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["DiscThrow"]={["baseCooldown"]=17.0,["bossDamage"]=30.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["ChaoticAfterglow"]={["baseCooldown"]=22.0,["bossDamage"]=11.5,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["ColossalKick"]={["baseCooldown"]=19.0,["bossDamage"]=95.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["BlackDivider"]={["baseCooldown"]=7.0,["bossDamage"]=75.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["UnknownFire"]={["baseCooldown"]=14.0,["bossDamage"]=12.5,["startupDelay"]=0.0,["damageMultiplier"]=13.5},["ApexSeverance"]={["baseCooldown"]=8.0,["bossDamage"]=90.0,["startupDelay"]=0.0,["damageMultiplier"]=18.0},["SupersonicSmash"]={["baseCooldown"]=16.0,["bossDamage"]=30.0,["startupDelay"]=0.1,["damageMultiplier"]=20.0},["OneEyeSlam"]={["baseCooldown"]=9.0,["bossDamage"]=100.0,["startupDelay"]=0.0,["damageMultiplier"]=35.0},["SpeechPlummet"]={["baseCooldown"]=16.0,["bossDamage"]=6.5,["startupDelay"]=0.3,["damageMultiplier"]=3.0},["GaleSlashes"]={["baseCooldown"]=10.0,["bossDamage"]=10.0,["startupDelay"]=0.1,["damageMultiplier"]=4.0},["CrescentSpin"]={["baseCooldown"]=12.0,["bossDamage"]=40.0,["startupDelay"]=0.1,["damageMultiplier"]=8.0},["Gear4KongOrgan"]={["baseCooldown"]=14.0,["bossDamage"]=6.0,["startupDelay"]=0.0,["damageMultiplier"]=3.0},["Disorder"]={["baseCooldown"]=15.0,["bossDamage"]=22.5,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["TitanLeap"]={["baseCooldown"]=12.0,["bossDamage"]=95.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["RisingSunEdge"]={["baseCooldown"]=14.0,["bossDamage"]=80.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["QuakePunch"]={["baseCooldown"]=10.0,["bossDamage"]=35.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["KazeTwirl"]={["baseCooldown"]=8.0,["bossDamage"]=40.0,["startupDelay"]=0.2,["damageMultiplier"]=5.0},["Gear4KingKongGun"]={["baseCooldown"]=25.0,["bossDamage"]=110.0,["startupDelay"]=0.6,["damageMultiplier"]=28.0},["TitanSlam"]={["baseCooldown"]=15.0,["bossDamage"]=100.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["Timestop"]={["baseCooldown"]=20.0,["bossDamage"]=1.0,["startupDelay"]=0.0,["damageMultiplier"]=1.0},["ThunderSlashes"]={["baseCooldown"]=11.0,["bossDamage"]=15.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["Tenburenjin"]={["baseCooldown"]=15.0,["bossDamage"]=8.0,["startupDelay"]=0.1,["damageMultiplier"]=14.0},["RendingClaw"]={["baseCooldown"]=10.0,["bossDamage"]=85.0,["startupDelay"]=0.15,["damageMultiplier"]=16.0},["FlyingBloodSickles"]={["baseCooldown"]=0.0,["bossDamage"]=4.5,["startupDelay"]=1.25,["damageMultiplier"]=5.0},["RampantArcRampage"]={["baseCooldown"]=0.0,["bossDamage"]=4.5,["startupDelay"]=1.0,["damageMultiplier"]=5.0},["WindRain"]={["baseCooldown"]=21.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["BlackHurricane"]={["baseCooldown"]=15.0,["bossDamage"]=12.5,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["RotatingCircularSlashes"]={["baseCooldown"]=0.0,["bossDamage"]=4.5,["startupDelay"]=0.7,["damageMultiplier"]=5.0},["DoubleSlash"]={["baseCooldown"]=12.0,["bossDamage"]=55.0,["startupDelay"]=0.0,["damageMultiplier"]=6.0},["Blackhole"]={["baseCooldown"]=11.0,["bossDamage"]=6.5,["startupDelay"]=0.0,["damageMultiplier"]=8.0},["ShadowStrike"]={["baseCooldown"]=7.0,["bossDamage"]=60.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["BlackVortex"]={["baseCooldown"]=9.0,["bossDamage"]=57.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["APAuto"]={["baseCooldown"]=12.0,["bossDamage"]=6.0,["startupDelay"]=0.4,["damageMultiplier"]=9.0},["StarSmash"]={["baseCooldown"]=8.0,["bossDamage"]=80.0,["startupDelay"]=0.4,["damageMultiplier"]=14.0},["BlackMeteorite"]={["baseCooldown"]=20.0,["bossDamage"]=75.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0},["Copy"]={["baseCooldown"]=15.0,["bossDamage"]=55.0,["startupDelay"]=0.0,["damageMultiplier"]=20.0},["WaterSlash"]={["baseCooldown"]=7.0,["bossDamage"]=50.0,["startupDelay"]=0.0,["damageMultiplier"]=14.0},["FemaleTitanTransform"]={["baseCooldown"]=5.0,["bossDamage"]=0.0,["damageMultiplier"]=30.0,["Transformation"]=true},["TimeLock"]={["baseCooldown"]=25.0,["bossDamage"]=170.0,["startupDelay"]=0.0,["damageMultiplier"]=25.0},["LightSwordThrust"]={["baseCooldown"]=5.0,["bossDamage"]=70.0,["startupDelay"]=0.0,["damageMultiplier"]=15.0},["EarthborneSkewers"]={["baseCooldown"]=15.0,["bossDamage"]=22.5,["startupDelay"]=0.4,["damageMultiplier"]=10.0},["FlameFist"]={["baseCooldown"]=8.0,["bossDamage"]=28.0,["startupDelay"]=0.067,["damageMultiplier"]=10.0},["ChopCarousel"]={["baseCooldown"]=7.0,["bossDamage"]=8.0,["startupDelay"]=0.1,["damageMultiplier"]=5.0},["Bloodlust"]={["baseCooldown"]=15.0,["bossDamage"]=8.5,["startupDelay"]=0.0,["damageMultiplier"]=5.0},["SandTornado"]={["baseCooldown"]=14.0,["bossDamage"]=23.0,["startupDelay"]=0.2,["damageMultiplier"]=15.0},["SandRailgun"]={["baseCooldown"]=12.0,["bossDamage"]=40.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["SkybeamBarrage"]={["baseCooldown"]=15.0,["bossDamage"]=15.0,["startupDelay"]=0.2,["damageMultiplier"]=4.0},["GigantThor"]={["baseCooldown"]=15.0,["bossDamage"]=100.0,["startupDelay"]=0.0,["damageMultiplier"]=25.0},["WindBeam"]={["baseCooldown"]=10.0,["bossDamage"]=10.0,["startupDelay"]=0.0,["damageMultiplier"]=7.0},["Tsunami"]={["baseCooldown"]=32.0,["bossDamage"]=35.0,["startupDelay"]=0.1,["damageMultiplier"]=14.0},["TsukiyamaBarrage"]={["baseCooldown"]=6.0,["bossDamage"]=4.0,["startupDelay"]=0.0,["damageMultiplier"]=3.0},["Gust"]={["baseCooldown"]=14.0,["bossDamage"]=5.0,["startupDelay"]=0.1,["damageMultiplier"]=6.0},["MeruemRetribution"]={["baseCooldown"]=12.0,["bossDamage"]=50.0,["startupDelay"]=0.0,["damageMultiplier"]=10.0},["MeruemRock"]={["baseCooldown"]=10.0,["bossDamage"]=80.0,["startupDelay"]=0.0,["damageMultiplier"]=17.5},["MeruemDeparture"]={["baseCooldown"]=20.0,["bossDamage"]=50.0,["startupDelay"]=0.0,["damageMultiplier"]=9.0},["MeruemIttai"]={["baseCooldown"]=15.0,["bossDamage"]=60.0,["startupDelay"]=0.0,["damageMultiplier"]=12.0}},["specials"]={["Rubber"]={["Z"]={["powerId"]="RubberPistol",["levelRequirement"]=0},["X"]={["powerId"]="RubberAxe",["levelRequirement"]=10},["C"]={["powerId"]="RubberBazooka",["levelRequirement"]=20},["V"]={["powerId"]="RubberGatling",["levelRequirement"]=45}},["CrazyDiamond"]={["Z"]={["powerId"]="StandBarrage",["levelRequirement"]=0},["X"]={["powerId"]="CrazyDiamondSmash",["levelRequirement"]=10},["C"]={["powerId"]="BarringShot",["levelRequirement"]=25},["V"]={["powerId"]="CrazyDiamondHealMode",["levelRequirement"]=50}},["LightGrimoire"]={["Z"]={["powerId"]="LightSwordThrust",["levelRequirement"]=0},["X"]={["powerId"]="LightRain",["levelRequirement"]=10},["C"]={["powerId"]="SwordSkyJudgement",["levelRequirement"]=25},["V"]={["powerId"]="LightAnnihilation",["levelRequirement"]=60}},["Schrift"]={["Z"]={["powerId"]="LichtPiercer",["levelRequirement"]=0},["X"]={["powerId"]="ArrowVolley",["levelRequirement"]=15},["C"]={["powerId"]="SpiritArrow",["levelRequirement"]=30},["V"]={["powerId"]="ThousandArrows",["levelRequirement"]=60}},["OneForAll"]={["Z"]={["powerId"]="DetroitSmash",["levelRequirement"]=0},["X"]={["powerId"]="FullManchesterSmash",["levelRequirement"]=15},["C"]={["powerId"]="OFASurge",["levelRequirement"]=30},["V"]={["powerId"]="USASmash",["levelRequirement"]=60}},["SpiralBlade"]={["Z"]={["powerId"]="TsukiyamaBarrage",["levelRequirement"]=0},["X"]={["powerId"]="TsukiyamaDash",["levelRequirement"]=10},["C"]={["powerId"]="TsukiyamaSlam",["levelRequirement"]=20}},["Compass"]={["Z"]={["powerId"]="CompassNeedle",["levelRequirement"]=0},["X"]={["powerId"]="Disorder",["levelRequirement"]=15},["C"]={["powerId"]="ChaoticAfterglow",["levelRequirement"]=30},["V"]={["powerId"]="Annihilation",["levelRequirement"]=60}},["TheWorld"]={["Z"]={["powerId"]="StandBarrage",["levelRequirement"]=0},["X"]={["powerId"]="KnivesThrow",["levelRequirement"]=10},["C"]={["powerId"]="RoadRoller",["levelRequirement"]=25},["V"]={["powerId"]="Timestop",["levelRequirement"]=50}},["WaterGrimoire"]={["Z"]={["powerId"]="WaterBullet",["levelRequirement"]=0},["X"]={["powerId"]="WaterShield",["levelRequirement"]=15},["C"]={["powerId"]="WaterBomb",["levelRequirement"]=30}},["Meruem"]={["Z"]={["powerId"]="MeruemRock",["levelRequirement"]=0},["X"]={["powerId"]="MeruemRetribution",["levelRequirement"]=10},["C"]={["powerId"]="MeruemIttai",["levelRequirement"]=20},["V"]={["powerId"]="MeruemDeparture",["levelRequirement"]=30}},["Sharingan"]={["Z"]={["powerId"]="Genjutsu",["levelRequirement"]=0},["X"]={["powerId"]="Copy",["levelRequirement"]=15},["C"]={["powerId"]="PerceptionElevation",["levelRequirement"]=30}},["Explosion"]={["Z"]={["powerId"]="BlastRush",["levelRequirement"]=0},["X"]={["powerId"]="StunGrenade",["levelRequirement"]=10},["C"]={["powerId"]="APAuto",["levelRequirement"]=20},["V"]={["powerId"]="HowitzerImpact",["levelRequirement"]=40}},["BlackMoon"]={["Z"]={["powerId"]="GetsugoTensho",["levelRequirement"]=0},["X"]={["powerId"]="HollowRoar",["levelRequirement"]=15},["C"]={["powerId"]="Tenburenjin",["levelRequirement"]=30},["V"]={["powerId"]="GetsugoRush",["levelRequirement"]=60}},["Chop"]={["Z"]={["powerId"]="ChopWhirlwind",["levelRequirement"]=0},["X"]={["powerId"]="ChopCarousel",["levelRequirement"]=10},["C"]={["powerId"]="ChopGoKart",["levelRequirement"]=30}},["WaterBreathing"]={["Z"]={["powerId"]="WaterSlash",["levelRequirement"]=0},["X"]={["powerId"]="WaterfallBasin",["levelRequirement"]=10},["C"]={["powerId"]="WaterWheel",["levelRequirement"]=30}},["Larper"]={["Z"]={["powerId"]="GraniteBlast",["levelRequirement"]=0},["X"]={["powerId"]="Appetizer",["levelRequirement"]=15},["C"]={["powerId"]="YouWerentInvited",["levelRequirement"]=30},["V"]={["powerId"]="EveryLastDrop",["levelRequirement"]=45}},["Kaiju"]={["Z"]={["powerId"]="KaijuBarrage",["levelRequirement"]=0},["X"]={["powerId"]="LotusStrike",["levelRequirement"]=15},["C"]={["powerId"]="CoreBreaker",["levelRequirement"]=30},["V"]={["powerId"]="KaijuTransform",["levelRequirement"]=60}},["SunBlade"]={["Z"]={["powerId"]="Torch",["levelRequirement"]=0},["X"]={["powerId"]="RisingSunEdge",["levelRequirement"]=15},["C"]={["powerId"]="TenjiKaijin",["levelRequirement"]=30},["V"]={["powerId"]="ScorchingHell",["levelRequirement"]=50}},["WhiteSnake"]={["Z"]={["powerId"]="StandBarrage",["levelRequirement"]=0},["X"]={["powerId"]="GunShot",["levelRequirement"]=10},["C"]={["powerId"]="AcidSlam",["levelRequirement"]=25},["V"]={["powerId"]="DiscThrow",["levelRequirement"]=50}},["Rika"]={["Z"]={["powerId"]="RikaPunch",["levelRequirement"]=0},["X"]={["powerId"]="RikaRoar",["levelRequirement"]=10},["C"]={["powerId"]="CursedHell",["levelRequirement"]=30},["V"]={["powerId"]="CursedEnergyBlast",["levelRequirement"]=50}},["MadeInHeaven"]={["Z"]={["powerId"]="MadeInHeaven_Barrage",["levelRequirement"]=0},["X"]={["powerId"]="AccelerationField",["levelRequirement"]=10},["C"]={["powerId"]="StandBarrage",["levelRequirement"]=25},["V"]={["powerId"]="StandBarrage",["levelRequirement"]=50}},["Byakugan"]={["Z"]={["powerId"]="RevolvingSky",["levelRequirement"]=0},["X"]={["powerId"]="TrigramAssault",["levelRequirement"]=15},["C"]={["powerId"]="TrigramGrid",["levelRequirement"]=30}},["Centipede"]={["Z"]={["powerId"]="CentipedeSpin",["levelRequirement"]=0},["X"]={["powerId"]="CentipedeSlam",["levelRequirement"]=10},["C"]={["powerId"]="CentipedeMindBreak",["levelRequirement"]=20}},["SandBerserkMode"]={["Z"]={["powerId"]="SandBerserkModeSlam",["levelRequirement"]=0},["X"]={["powerId"]="SandBerserkModeRoar",["levelRequirement"]=10}},["TimeGrimoire"]={["Z"]={["powerId"]="ChronoBolt",["levelRequirement"]=0},["X"]={["powerId"]="ChronoBarrage",["levelRequirement"]=15},["C"]={["powerId"]="ChronoSphere",["levelRequirement"]=30},["V"]={["powerId"]="TimeLock",["levelRequirement"]=60}},["Murcielago"]={["Z"]={["powerId"]="CeroBarrido",["levelRequirement"]=0},["X"]={["powerId"]="CeroDevastacion",["levelRequirement"]=15},["C"]={["powerId"]="TormentaDeMurcielago",["levelRequirement"]=30},["V"]={["powerId"]="LanzaDelRelampago",["levelRequirement"]=60}},["Yami"]={["Z"]={["powerId"]="BlackVortex",["levelRequirement"]=0},["X"]={["powerId"]="Blackhole",["levelRequirement"]=15},["C"]={["powerId"]="Liberation",["levelRequirement"]=30},["V"]={["powerId"]="BlackMatter",["levelRequirement"]=60}},["ThunderBreathing"]={["Z"]={["powerId"]="ThunderClap",["levelRequirement"]=0},["X"]={["powerId"]="ThunderSlashes",["levelRequirement"]=10},["C"]={["powerId"]="GodlikeSpeed",["levelRequirement"]=20},["V"]={["powerId"]="Ephemeral",["levelRequirement"]=40}},["SilverChariot"]={["Z"]={["powerId"]="MultiSlash_SilverChariot",["levelRequirement"]=0},["X"]={["powerId"]="EnGarde",["levelRequirement"]=10},["C"]={["powerId"]="SilverChariot_Barrage",["levelRequirement"]=20},["V"]={["powerId"]="Mirage",["levelRequirement"]=45}},["Berserk"]={["Z"]={["powerId"]="PredatorPounce",["levelRequirement"]=0},["X"]={["powerId"]="Shredder",["levelRequirement"]=15},["C"]={["powerId"]="WrathfulOutcry",["levelRequirement"]=30},["V"]={["powerId"]="BeastCleave",["levelRequirement"]=60}},["PhoenixTransformation"]={["Z"]={["powerId"]="FlareKick",["levelRequirement"]=0},["X"]={["powerId"]="BlazingVortex",["levelRequirement"]=15},["C"]={["powerId"]="AzureInferno",["levelRequirement"]=35},["V"]={["powerId"]="RisingPhoenix",["levelRequirement"]=80}},["AntiMagicGrimoire"]={["Z"]={["powerId"]="BlackDivider",["levelRequirement"]=0},["X"]={["powerId"]="BerserkRush",["levelRequirement"]=15},["C"]={["powerId"]="BlackHurricane",["levelRequirement"]=30},["V"]={["powerId"]="BlackMeteorite",["levelRequirement"]=45}},["Overhaul"]={["Z"]={["powerId"]="OverhaulPunch",["levelRequirement"]=0},["X"]={["powerId"]="EarthRend",["levelRequirement"]=10},["C"]={["powerId"]="EarthborneSkewers",["levelRequirement"]=25},["V"]={["powerId"]="Reassemble",["levelRequirement"]=50}},["Yamori"]={["Z"]={["powerId"]="YamoriSpin",["levelRequirement"]=0},["X"]={["powerId"]="YamoriJab",["levelRequirement"]=10},["C"]={["powerId"]="YamoriGrinder",["levelRequirement"]=20}},["Electrification"]={["Z"]={["powerId"]="BreathBlast",["levelRequirement"]=0},["X"]={["powerId"]="BaranJumpSlam",["levelRequirement"]=10},["C"]={["powerId"]="LightningStrikes",["levelRequirement"]=25},["V"]={["powerId"]="SwordStrike",["levelRequirement"]=50}},["Garou"]={["Z"]={["powerId"]="GodSlayer",["levelRequirement"]=0},["X"]={["powerId"]="GreatFajin",["levelRequirement"]=15},["C"]={["powerId"]="MonstersTrail",["levelRequirement"]=30},["V"]={["powerId"]="SkyRippingFist",["levelRequirement"]=60}},["Barrier"]={["Z"]={["powerId"]="BarrierExpansion",["levelRequirement"]=0},["X"]={["powerId"]="BarrierRush",["levelRequirement"]=10},["C"]={["powerId"]="BarrierSlam",["levelRequirement"]=25},["V"]={["powerId"]="BarrierSurge",["levelRequirement"]=50}},["ColossalTitan"]={["Z"]={["powerId"]="ColossalStomp",["levelRequirement"]=0},["X"]={["powerId"]="ColossalSteamBurst",["levelRequirement"]=20},["C"]={["powerId"]="ColossalKick",["levelRequirement"]=40},["V"]={["powerId"]="ColossalNuke",["levelRequirement"]=60}},["PerfectSusanoo"]={["Z"]={["powerId"]="DoubleSlash",["levelRequirement"]=0},["X"]={["powerId"]="GroundStab",["levelRequirement"]=15},["C"]={["powerId"]="TwinBladeDance",["levelRequirement"]=30},["V"]={["powerId"]="TornadoSlash",["levelRequirement"]=60}},["Magma"]={["Z"]={["powerId"]="MoltenCore",["levelRequirement"]=0},["X"]={["powerId"]="MagmaFist",["levelRequirement"]=15},["C"]={["powerId"]="MagmaEruption",["levelRequirement"]=35},["V"]={["powerId"]="MagmaShower",["levelRequirement"]=80}},["WeaponSpecialist"]={["Z"]={["powerId"]="HeavenlyVolley",["levelRequirement"]=0},["X"]={["powerId"]="ThousandSlashes",["levelRequirement"]=10},["C"]={["powerId"]="SoulSplitter",["levelRequirement"]=25},["V"]={["powerId"]="SupersonicSmash",["levelRequirement"]=40}},["GonUnawakened"]={["Z"]={["powerId"]="GonRock",["levelRequirement"]=0},["X"]={["powerId"]="GonScissors",["levelRequirement"]=10},["C"]={["powerId"]="GonPaper",["levelRequirement"]=20}},["HalfHotHalfCold"]={["Z"]={["powerId"]="IceSpikes",["levelRequirement"]=0},["X"]={["powerId"]="IceSurf",["levelRequirement"]=15},["C"]={["powerId"]="FlashfireJetKindle",["levelRequirement"]=30},["V"]={["powerId"]="FlashfreezeHeatwave",["levelRequirement"]=60}},["Insect"]={["Z"]={["powerId"]="InsectAssault",["levelRequirement"]=0},["X"]={["powerId"]="InsectEruption",["levelRequirement"]=15},["C"]={["powerId"]="InsectTornado",["levelRequirement"]=30}},["TrueBankai"]={["Z"]={["powerId"]="TrueBankaiBarrage",["levelRequirement"]=0},["X"]={["powerId"]="BlackMoon",["levelRequirement"]=15},["C"]={["powerId"]="FinalCero",["levelRequirement"]=30},["V"]={["powerId"]="FinalGetsugoTensho",["levelRequirement"]=60}},["GonAwakened"]={["Z"]={["powerId"]="GonRock",["levelRequirement"]=0},["X"]={["powerId"]="GonRetribution",["levelRequirement"]=10},["C"]={["powerId"]="Ittai",["levelRequirement"]=20},["V"]={["powerId"]="GonDeparture",["levelRequirement"]=30}},["OneEye"]={["Z"]={["powerId"]="OneEyeBarrage",["levelRequirement"]=0},["X"]={["powerId"]="OneEyeSlam",["levelRequirement"]=10},["C"]={["powerId"]="OneEyeRoar",["levelRequirement"]=20}},["SandBeastMode"]={["Z"]={["powerId"]="SandBeastModeSlam",["levelRequirement"]=0},["X"]={["powerId"]="SandBeastModeRoar",["levelRequirement"]=10},["C"]={["powerId"]="SandBeastModeBeastBomb",["levelRequirement"]=20}},["StarPlatinum"]={["Z"]={["powerId"]="StarSmash",["levelRequirement"]=0},["X"]={["powerId"]="StarFinger",["levelRequirement"]=10},["C"]={["powerId"]="StandBarrage",["levelRequirement"]=25},["V"]={["powerId"]="Timestop",["levelRequirement"]=50}},["AttackTitan"]={["Z"]={["powerId"]="TitanLeap",["levelRequirement"]=0},["X"]={["powerId"]="TitanRampage",["levelRequirement"]=15},["C"]={["powerId"]="TitanHeal",["levelRequirement"]=30},["V"]={["powerId"]="TitanRage",["levelRequirement"]=50}},["Gear4"]={["Z"]={["powerId"]="Gear4Barrage",["levelRequirement"]=0},["X"]={["powerId"]="Gear4KongOrgan",["levelRequirement"]=25},["C"]={["powerId"]="Gear4Bazooka",["levelRequirement"]=45},["V"]={["powerId"]="Gear4KingKongGun",["levelRequirement"]=70}},["Phoenix"]={["Z"]={["powerId"]="FlareKick",["levelRequirement"]=0},["X"]={["powerId"]="BlazingVortex",["levelRequirement"]=15},["C"]={["powerId"]="AzureInferno",["levelRequirement"]=35},["V"]={["powerId"]="RisingPhoenix",["levelRequirement"]=80}},["Gravity"]={["Z"]={["powerId"]="GravityCrush",["levelRequirement"]=0},["X"]={["powerId"]="GravityChamber",["levelRequirement"]=15},["C"]={["powerId"]="Asteroid",["levelRequirement"]=30},["V"]={["powerId"]="GravityMeteorShower",["levelRequirement"]=60}},["RedScale"]={["Z"]={["powerId"]="KanekiJab",["levelRequirement"]=0},["X"]={["powerId"]="KanekiBarrage",["levelRequirement"]=10},["C"]={["powerId"]="KanekiLeap",["levelRequirement"]=20}},["FemaleTitan"]={["Z"]={["powerId"]="Screech",["levelRequirement"]=0},["X"]={["powerId"]="HardenFist",["levelRequirement"]=15},["C"]={["powerId"]="SpinAttack",["levelRequirement"]=30}},["Limitless"]={["Z"]={["powerId"]="ReversalRed",["levelRequirement"]=0},["X"]={["powerId"]="LapseBlue",["levelRequirement"]=25},["C"]={["powerId"]="HollowPurple",["levelRequirement"]=50},["V"]={["powerId"]="InfiniteVoid",["levelRequirement"]=60}},["Ratio"]={["Z"]={["powerId"]="RatioPunch",["levelRequirement"]=0},["X"]={["powerId"]="RatioSmash",["levelRequirement"]=15},["C"]={["powerId"]="RatioCut",["levelRequirement"]=25}},["ShadowMonarch"]={["Z"]={["powerId"]="ShadowCross",["levelRequirement"]=0},["X"]={["powerId"]="AbyssalSeverance",["levelRequirement"]=10},["C"]={["powerId"]="DevouringClaw",["levelRequirement"]=25},["V"]={["powerId"]="RulersAuthority",["levelRequirement"]=50}},["Psychic"]={["Z"]={["powerId"]="PsychicPull",["levelRequirement"]=0},["X"]={["powerId"]="WhirlWindStorm",["levelRequirement"]=15},["C"]={["powerId"]="RockBarrage",["levelRequirement"]=30},["V"]={["powerId"]="PsychicRicochet",["levelRequirement"]=60}},["WhiteTiger"]={["Z"]={["powerId"]="KingsRupture",["levelRequirement"]=0},["X"]={["powerId"]="RendingClaw",["levelRequirement"]=10},["C"]={["powerId"]="FeralCleave",["levelRequirement"]=25},["V"]={["powerId"]="WhiteTigerTransform",["levelRequirement"]=50}},["WindGrimoire"]={["Z"]={["powerId"]="WindBullet",["levelRequirement"]=0},["X"]={["powerId"]="WindBeam",["levelRequirement"]=15},["C"]={["powerId"]="GrimoireWhirlWindStorm",["levelRequirement"]=30},["V"]={["powerId"]="WindRain",["levelRequirement"]=50}},["ArmoredTitan"]={["Z"]={["powerId"]="TitanRun",["levelRequirement"]=0},["X"]={["powerId"]="TitanThrow",["levelRequirement"]=10},["C"]={["powerId"]="TitanSlam",["levelRequirement"]=10}},["Sand"]={["Z"]={["powerId"]="SandRailgun",["levelRequirement"]=0},["X"]={["powerId"]="SandCoffin",["levelRequirement"]=10},["C"]={["powerId"]="SandTornado",["levelRequirement"]=20},["V"]={["powerId"]="SandSpada",["levelRequirement"]=40}},["GodSpeed"]={["Z"]={["powerId"]="LightningCharge",["levelRequirement"]=0},["X"]={["powerId"]="LightningBarrage",["levelRequirement"]=10},["C"]={["powerId"]="LightningThrow",["levelRequirement"]=20}},["DualDaggers"]={["Z"]={["powerId"]="ShadowStrike",["levelRequirement"]=0},["X"]={["powerId"]="ShadowBarrage",["levelRequirement"]=10},["C"]={["powerId"]="Bloodlust",["levelRequirement"]=25}},["Quake"]={["Z"]={["powerId"]="ShockPunch",["levelRequirement"]=0},["X"]={["powerId"]="BlastClutcher",["levelRequirement"]=15},["C"]={["powerId"]="QuakePunch",["levelRequirement"]=25},["V"]={["powerId"]="Tsunami",["levelRequirement"]=50}},["Wind"]={["Z"]={["powerId"]="KazeTwirl",["levelRequirement"]=0},["X"]={["powerId"]="GaleSlashes",["levelRequirement"]=10},["C"]={["powerId"]="Gust",["levelRequirement"]=20}},["ThousandBlossoms"]={["Z"]={["powerId"]="Senbonzakura",["levelRequirement"]=0},["X"]={["powerId"]="IkkaSenjekai",["levelRequirement"]=15},["C"]={["powerId"]="YojunSenka",["levelRequirement"]=30},["V"]={["powerId"]="Gokei",["levelRequirement"]=45}},["MangekyouSharingan"]={["Z"]={["powerId"]="Amaterasu",["levelRequirement"]=0},["X"]={["powerId"]="ArmoredArrow",["levelRequirement"]=15},["C"]={["powerId"]="ArmoredRain",["levelRequirement"]=30},["V"]={["powerId"]="ArmoredSusanoo",["levelRequirement"]=60}},["Flame"]={["Z"]={["powerId"]="FlameFist",["levelRequirement"]=0},["X"]={["powerId"]="FireFly",["levelRequirement"]=15},["C"]={["powerId"]="FlamePillar",["levelRequirement"]=25},["V"]={["powerId"]="Enkai",["levelRequirement"]=60}},["Starrk"]={["Z"]={["powerId"]="RegularCero",["levelRequirement"]=0},["X"]={["powerId"]="CeroSierra",["levelRequirement"]=15},["C"]={["powerId"]="CeroDespiadada",["levelRequirement"]=30},["V"]={["powerId"]="StarrkWolves",["levelRequirement"]=40}},["KillerQueen"]={["Z"]={["powerId"]="StandBarrage",["levelRequirement"]=0},["X"]={["powerId"]="Detonate",["levelRequirement"]=10},["C"]={["powerId"]="SheerHeartAttack",["levelRequirement"]=25},["V"]={["powerId"]="BitesTheDust",["levelRequirement"]=50}},["CursedSpeech"]={["Z"]={["powerId"]="SpeechBlastAway",["levelRequirement"]=0},["X"]={["powerId"]="SpeechExplode",["levelRequirement"]=10},["C"]={["powerId"]="SpeechDontMove",["levelRequirement"]=20},["V"]={["powerId"]="SpeechPlummet",["levelRequirement"]=30}},["Beru"]={["Z"]={["powerId"]="ApexSeverance",["levelRequirement"]=0},["X"]={["powerId"]="VoidSteps",["levelRequirement"]=10},["C"]={["powerId"]="KingsDescent",["levelRequirement"]=25},["V"]={["powerId"]="SovereignJudgment",["levelRequirement"]=50}},["Shrine"]={["Z"]={["powerId"]="CleaveDismantle",["levelRequirement"]=0},["X"]={["powerId"]="CrimsonFault",["levelRequirement"]=10},["C"]={["powerId"]="Fuga",["levelRequirement"]=25},["V"]={["powerId"]="ShrineDomainExpansionPlayer",["levelRequirement"]=50}},["Vasto"]={["Z"]={["powerId"]="CeroBala",["levelRequirement"]=0},["X"]={["powerId"]="DescensoDelCero",["levelRequirement"]=20},["C"]={["powerId"]="RugidoDelVacio",["levelRequirement"]=40},["V"]={["powerId"]="GranCeroOscuras",["levelRequirement"]=60}},["SandSageMode"]={["Z"]={["powerId"]="SandSageModeSlam",["levelRequirement"]=0},["X"]={["powerId"]="SandSageModeRoar",["levelRequirement"]=10},["C"]={["powerId"]="SandSageModeBeastBomb",["levelRequirement"]=25},["V"]={["powerId"]="SandSageModeSandShuriken",["levelRequirement"]=50}},["Debug"]={["Z"]={["powerId"]="FlyingBloodSickles",["levelRequirement"]=0},["X"]={["powerId"]="DebugCutscene",["levelRequirement"]=0},["C"]={["powerId"]="KillEntitiesInRadius",["levelRequirement"]=0},["V"]={["powerId"]="KillAllEntities",["levelRequirement"]=0}},["RadiantBlade"]={["Z"]={["powerId"]="PhantomCut",["levelRequirement"]=0},["X"]={["powerId"]="CrescentSpin",["levelRequirement"]=10},["C"]={["powerId"]="Guillotine",["levelRequirement"]=20},["V"]={["powerId"]="RadiantFault",["levelRequirement"]=25}},["Rinnegan"]={["Z"]={["powerId"]="AlmightyPush",["levelRequirement"]=0},["X"]={["powerId"]="AlmightyPull",["levelRequirement"]=20},["C"]={["powerId"]="PlanetaryDevastation",["levelRequirement"]=40}},["Cream"]={["Z"]={["powerId"]="StandBarrage",["levelRequirement"]=0}},["SoundBreathing"]={["Z"]={["powerId"]="ExplosiveBeads",["levelRequirement"]=0},["X"]={["powerId"]="SoundBreathingRoar",["levelRequirement"]=10},["C"]={["powerId"]="ConstantResounding",["levelRequirement"]=25},["V"]={["powerId"]="StringPerformance",["levelRequirement"]=50}},["TheHand"]={["Z"]={["powerId"]="Erasure",["levelRequirement"]=0},["X"]={["powerId"]="EraseAcceleration",["levelRequirement"]=10},["C"]={["powerId"]="StandBarrage",["levelRequirement"]=20},["V"]={["powerId"]="SpaceErasure",["levelRequirement"]=30}},["FlameBreathing"]={["Z"]={["powerId"]="BlazingUniverse",["levelRequirement"]=0},["X"]={["powerId"]="UnknownFire",["levelRequirement"]=15},["C"]={["powerId"]="FlameTiger",["levelRequirement"]=30},["V"]={["powerId"]="Rengoku",["levelRequirement"]=60}},["Buddha"]={["Z"]={["powerId"]="HeavenlyImpact",["levelRequirement"]=0},["X"]={["powerId"]="DivineRetribution",["levelRequirement"]=15},["C"]={["powerId"]="TwilightOfTheGods",["levelRequirement"]=35}},["Light"]={["Z"]={["powerId"]="LightKick",["levelRequirement"]=0},["X"]={["powerId"]="LightSaber",["levelRequirement"]=10},["C"]={["powerId"]="ReflectionKick",["levelRequirement"]=25},["V"]={["powerId"]="SkybeamBarrage",["levelRequirement"]=50}},["Hit"]={["Z"]={["powerId"]="AssassinsArt",["levelRequirement"]=0},["X"]={["powerId"]="IcyGlare",["levelRequirement"]=15},["C"]={["powerId"]="TimeMolotov",["levelRequirement"]=30},["V"]={["powerId"]="TidesOfTime",["levelRequirement"]=60}},["GreatApe"]={["Z"]={["powerId"]="GreatApeAerialSlam",["levelRequirement"]=0},["X"]={["powerId"]="GreatApeDeathBeam",["levelRequirement"]=10}},["MagicianRed"]={["Z"]={["powerId"]="FlamingKick",["levelRequirement"]=0},["X"]={["powerId"]="FireShots",["levelRequirement"]=10},["C"]={["powerId"]="StandBarrage",["levelRequirement"]=20},["V"]={["powerId"]="CrossHurricane",["levelRequirement"]=45}},["MoonBreathing"]={["Z"]={["powerId"]="MoonDragon",["levelRequirement"]=0},["X"]={["powerId"]="MirrorOfMisfortune",["levelRequirement"]=15},["C"]={["powerId"]="MoonGazing",["levelRequirement"]=30},["V"]={["powerId"]="LoathsomeMoon",["levelRequirement"]=60}},["Ice"]={["Z"]={["powerId"]="IcePartisan",["levelRequirement"]=0},["X"]={["powerId"]="GlacialSurge",["levelRequirement"]=10},["C"]={["powerId"]="PheasantBeak",["levelRequirement"]=25},["V"]={["powerId"]="IceAwakening",["levelRequirement"]=50}}},["specialIcons"]={["rbxassetid://115844502209164"]="Rubber",["rbxassetid://114867242175089"]="CrazyDiamond",["rbxassetid://89252400277033"]="LightGrimoire",["rbxassetid://125918606094526"]="Schrift",["rbxassetid://137741625918049"]="OneForAll",["rbxassetid://122501836641656"]="SpiralBlade",["rbxassetid://80056366131913"]="Compass",["rbxassetid://90640010746810"]="TheWorld",["rbxassetid://135363203776383"]="WaterGrimoire",["rbxassetid://126857712999058"]="Meruem",["rbxassetid://110560070297105"]="Sharingan",["rbxassetid://84405555916118"]="Explosion",["rbxassetid://83761455654184"]="BlackMoon",["rbxassetid://106882370311126"]="Chop",["rbxassetid://135949206150312"]="WaterBreathing",["rbxassetid://115054457543623"]="Larper",["rbxassetid://109435222485809"]="Kaiju",["rbxassetid://94237129507055"]="SunBlade",["rbxassetid://108001425929076"]="WhiteSnake",["rbxassetid://126703671628765"]="Rika",["rbxassetid://textures/ui/GuiImagePlaceholder.png"]="Cream",["rbxassetid://139835429838768"]="Byakugan",["rbxassetid://119711349638355"]="Centipede",["rbxassetid://103631675839016"]="SandBerserkMode",["rbxassetid://138370184634272"]="TimeGrimoire",["rbxassetid://129454080989580"]="Murcielago",["rbxassetid://129205019095395"]="Yami",["rbxassetid://127673104816564"]="ThunderBreathing",["rbxassetid://82041376885821"]="SilverChariot",["rbxassetid://78986043559458"]="Berserk",["rbxassetid://138769909148632"]="PhoenixTransformation",["rbxassetid://94986677076223"]="AntiMagicGrimoire",["rbxassetid://125039638163910"]="Overhaul",["rbxassetid://79678180244430"]="Yamori",["rbxassetid://77707235570198"]="Electrification",["rbxassetid://116902110004187"]="Garou",["rbxassetid://82884077799946"]="Barrier",["rbxassetid://127375299682851"]="ColossalTitan",["rbxassetid://124510588303556"]="PerfectSusanoo",["rbxassetid://104317841471904"]="Magma",["rbxassetid://121927603932213"]="WeaponSpecialist",["rbxassetid://114643350252113"]="GonUnawakened",["rbxassetid://86985021704004"]="HalfHotHalfCold",["rbxassetid://120599244350276"]="Insect",["rbxassetid://85420742058314"]="TrueBankai",["rbxassetid://131339681235475"]="GonAwakened",["rbxassetid://106627032129203"]="OneEye",["rbxassetid://70615823940317"]="SandBeastMode",["rbxassetid://83307364036468"]="StarPlatinum",["rbxassetid://116258582807441"]="AttackTitan",["rbxassetid://80816177120245"]="Phoenix",["rbxassetid://109513038802234"]="Gravity",["rbxassetid://89641720065792"]="RedScale",["rbxassetid://121712814424246"]="FemaleTitan",["rbxassetid://105421310291188"]="Limitless",["rbxassetid://126953759458469"]="Ratio",["rbxassetid://111630746201996"]="ShadowMonarch",["rbxassetid://95871558934989"]="Psychic",["rbxassetid://134699657896890"]="WhiteTiger",["rbxassetid://81741378882357"]="WindGrimoire",["rbxassetid://81360796594950"]="Sand",["rbxassetid://128848640955110"]="GodSpeed",["rbxassetid://71647239682665"]="DualDaggers",["rbxassetid://84421401351165"]="Quake",["rbxassetid://127217938252842"]="ThousandBlossoms",["rbxassetid://121221457976169"]="MangekyouSharingan",["rbxassetid://77120791048324"]="Flame",["rbxassetid://99608086345165"]="Starrk",["rbxassetid://84803347453069"]="KillerQueen",["rbxassetid://108553235454692"]="CursedSpeech",["rbxassetid://89352129735814"]="Beru",["rbxassetid://75393925116236"]="Shrine",["rbxassetid://119189716335249"]="Vasto",["rbxassetid://76143425824771"]="SandSageMode",["rbxassetid://100196980032121"]="Debug",["rbxassetid://137929436070211"]="RadiantBlade",["rbxassetid://82367093896730"]="Rinnegan",["rbxassetid://121769700196993"]="SoundBreathing",["rbxassetid://125153591492494"]="TheHand",["rbxassetid://104144894060170"]="FlameBreathing",["rbxassetid://126764603873611"]="Buddha",["rbxassetid://95652192933261"]="Light",["rbxassetid://136327424655005"]="Hit",["rbxassetid://73457221757094"]="MagicianRed",["rbxassetid://96230004182016"]="MoonBreathing",["rbxassetid://122557719313485"]="Ice"},["badges"]={["Welcome"]=1,["Reach1KPower"]=2,["Reach10KPower"]=3,["Reach100KPower"]=4,["Reach1MPower"]=5,["Reach1BPower"]=6,["Reach1TPower"]=7,["Reach100TPower"]=8,["Reach1QdPower"]=9,["Reach100QdPower"]=10,["Reach1QnPower"]=11,["Reach100QnPower"]=12,["Reach1SxPower"]=13,["Reach100SxPower"]=14,["Reach1SpPower"]=15,["Reach100SpPower"]=16,["Reach1OcTotalPower"]=17,["Reach100OcTotalPower"]=18,["DefeatDemonFox"]=19,["DefeatGreatApe"]=20,["DefeatArmoredTitan"]=21,["DefeatPuya"]=22,["DefeatAlligator"]=23,["DefeatCurseKing"]=24,["DefeatIgros"]=25,["DefeatAgony"]=26,["DefeatMada"]=27,["DefeatHandDemon"]=28,["DefeatBroly"]=29,["DefeatSeaKing"]=30,["DefeatShukaku"]=31,["DefeatBerserk"]=32,["DefeatKokushibo"]=33,["Defeat500Skeletons"]=34,["Complete5Quests"]=35,["Complete10Quests"]=36,["Complete25Quests"]=37,["Complete50Quests"]=38,["Complete75Quests"]=39,["Complete150Quests"]=40,["Roll1LegendaryChampion"]=41,["Roll1MythicChampion"]=42,["Roll1SecretChampion"]=43,["Roll1SovereignChampion"]=44,["Summon5Champions"]=45,["Summon10Champions"]=46,["Summon25Champions"]=47,["Summon50Champions"]=48,["Summon100Champions"]=49,["Summon250Champions"]=50,["Summon500Champions"]=51,["Summon1000Champions"]=52,["Summon1750Champions"]=53,["Summon3000Champions"]=54,["Summon5000Champions"]=55,["Summon7500Champions"]=56,["Summon10000Champions"]=57,["Summon25000Champions"]=58,["Summon75000Champions"]=59,["CompleteJejuIslandEasy"]=60,["CompleteJejuIslandMedium"]=61,["CompleteJejuIslandHard"]=62,["CompleteLimboEasy"]=63,["CompleteLimboMedium"]=64,["CompleteLimboHard"]=65,["CompleteLimboNightmare"]=66,["ReachTowerFloor25"]=67,["ReachTowerFloor50"]=68,["ReachTowerFloor75"]=69,["ReachTowerFloor100"]=70,["ReachTowerFloor150"]=71},["itemSources"]={["FinalResolve"]={"FoundingTitan","HandDemon","Shukaku","SeaBeast","LightElf","Meruem","DemonLord"},["Liberator"]={"FoundingTitan"},["ScoutCape"]={"FoundingTitan"},["ShiftingSerum"]={"FoundingTitan","TripleT"},["CrocodileCape"]={"Crocodile"},["CrocodileMount"]={"Crocodile"},["Sand"]={"Crocodile"},["TraitReroll"]={"Crocodile","ArmoredTitan","GreatApe","Kurama","Brole","CurseKing","Puya","Igros","Byakuya","HandDemon","Shukaku","SeaBeast","CurseHunter","Mada","SpecialGrade","Lieve","LightElf","BerserkBoss","Kokushibo"},["ArmoredPlate"]={"ArmoredTitan"},["MarleysShield"]={"ArmoredTitan"},["TitanSerum"]={"ArmoredTitan"},["WallFragment"]={"ArmoredTitan"},["ApeFang"]={"GreatApe"},["ApeFur"]={"GreatApe"},["ApeTail"]={"GreatApe"},["NimbusMount"]={"GreatApe"},["PrimalInstinct"]={"GreatApe"},["RageCrystal"]={"GreatApe"},["Scouter"]={"GreatApe"},["TemporaryServerBoost"]={"Kurama","Brole","Lieve","TripleT"},["LegendaryPelt"]={"Brole"},["LegendarySaiyan"]={"Brole"},["CurseKing"]={"CurseKing"},["CurseKingsFinger"]={"CurseKing"},["CursedEssence"]={"CurseKing"},["HeartFragment"]={"CurseKing"},["CopyFragment"]={"Puya"},["CurseResidue"]={"Puya"},["MalevolentKey"]={"Puya","CurseHunter","SpecialGrade"},["Puya"]={"Puya"},["PuyaRing"]={"Puya"},["Talisman"]={"Puya"},["Igros"]={"Igros"},["JejuIslandKey"]={"Igros"},["CaptainsCape"]={"Byakuya"},["DivisionCaptain"]={"Byakuya"},["Kuya"]={"Byakuya"},["LimboKey"]={"Byakuya"},["DevourerTitle"]={"HandDemon"},["WardingMask"]={"HandDemon"},["SandBerserkMode"]={"Shukaku"},["SandGourd"]={"Shukaku"},["FruitRoll"]={"SeaBeast"},["SeaEmperor"]={"SeaBeast"},["ToothNecklace"]={"SeaBeast"},["CurseHunter"]={"CurseHunter"},["InvertedSpearOfHeaven"]={"CurseHunter"},["ArmorFragment"]={"Mada"},["ChakraBlade"]={"Mada"},["MadaReincarnated"]={"Mada"},["Ribcage"]={"Mada"},["SpecialGrade"]={"SpecialGrade"},["Agony"]={"Pain"},["AkatsukiRobe"]={"Pain"},["MadaraKey"]={"Pain"},["DevilWings"]={"Lieve"},["Psychic"]={"WildPsychic"},["WildPsychic"]={"WildPsychic"},["LightElf"]={"LightElf"},["LightGrimoire"]={"LightElf"},["ChimeraCocoon"]={"Meruem"},["LimitationFragment"]={"Meruem"},["Meruem"]={"Meruem"},["DemonLord"]={"DemonLord"},["Slime"]={"DemonLord"},["TripleT"]={"TripleT"},["Berserk"]={"BerserkBoss"},["TrickOrTreatBag"]={"BerserkBoss","Kokushibo"},["CrescentShard"]={"Kokushibo"},["FleshBlade"]={"Kokushibo"},["Kokushibo"]={"Kokushibo"},["KokushiboEye"]={"Kokushibo"}},["powerSources"]={["BijuuBombPlayer"]={"Kurama"},["MultiShuriken"]={"Kurama"},["Rasenshuriken"]={"Kurama"},["SixPaths"]={"Kurama"},["BrolyRush"]={"Brole"},["ExplosiveWave"]={"Brole"},["GiganticRoar"]={"Brole"},["LSSJ"]={"Brole"},["LegendaryKiBlasts"]={"Brole"},["MeteorShower"]={"Brole"},["DevilUnion"]={"Lieve"},["Beelzebub"]={"DemonLord"},["BlackLightning"]={"DemonLord"},["HellFlare"]={"DemonLord"},["MegiddoInfernus"]={"DemonLord"}},["specialOverrides"]={["CrazyDiamond"]={["StandBarrage"]={["baseCooldown"]=10.0,["bossDamage"]=6.0,["damageMultiplier"]=9.0}},["TheWorld"]={["StandBarrage"]={["baseCooldown"]=12.0,["bossDamage"]=5.5,["damageMultiplier"]=8.0}},["WhiteSnake"]={["StandBarrage"]={["baseCooldown"]=7.0,["bossDamage"]=4.5,["damageMultiplier"]=6.0}},["GonAwakened"]={["GonRock"]={["baseCooldown"]=10.0,["bossDamage"]=80.0,["damageMultiplier"]=17.5}},["StarPlatinum"]={["StandBarrage"]={["baseCooldown"]=10.0,["bossDamage"]=5.5,["damageMultiplier"]=6.0}},["KillerQueen"]={["StandBarrage"]={["baseCooldown"]=7.0,["bossDamage"]=4.5,["damageMultiplier"]=6.0}},["Debug"]={["StandBarrage"]={["baseCooldown"]=5.0,["bossDamage"]=1e+50,["damageMultiplier"]=1e+50}},["TheHand"]={["StandBarrage"]={["baseCooldown"]=6.0,["bossDamage"]=4.0,["damageMultiplier"]=4.0}},["MagicianRed"]={["StandBarrage"]={["baseCooldown"]=6.0,["bossDamage"]=3.5,["damageMultiplier"]=5.0}}}}

local combat={cooldowns={},pending={},nextCast=0,nextEquip=0,slotCursor=0,casts=0,aims={},held={}}
-- Native entity targeting uses the bounding-box _AimHitbox, which can be above the pivot/feet.
function combat.TargetPoint(target)
    if target.name=="FoundingTitan" and mobs.ResolveModel(target) then return mobPosition(target) end
    local model=target.model
    if not target.player and (not model or not model.Parent) and os.clock()>=(target.nextModelScan or 0) then
        target.nextModelScan=os.clock()+0.5
        local folder=workspace:FindFirstChild("ClientEntities")
        for _,candidate in ipairs(folder and folder:GetChildren() or {}) do
            if candidate:GetAttribute("entityId")==target.id then model=candidate target.model=candidate break end
        end
    end
    local box=model and model.Parent and model:FindFirstChild("_AimHitbox",true)
    if box and box:IsA("BasePart") then return box.Position end
    return mobPosition(target)
end
-- Reviewed shared damage/trajectory properties, not visual mesh sizes.
do
local profiles={["ConquerorsHaki"]={["kind"]="radial",["startup"]=0.0,["delay"]=0,["radius"]=75.0},["SpiritualPressure"]={["kind"]="radial",["startup"]=0.0,["delay"]=0,["radius"]=50.0},["InfiniteVoid"]={["kind"]="radial",["startup"]=0.0,["delay"]=0,["radius"]=60.0,["offset"]=0.0},["Timestop"]={["kind"]="radial",["startup"]=0.0,["delay"]=1.0,["radius"]=75.0},["ExplosiveWave"]={["kind"]="radial",["startup"]=0.0,["delay"]=0,["radius"]=70.0},["MultiSlash"]={["kind"]="offset",["startup"]=0.1,["delay"]=0.1,["radius"]=9.0,["offset"]=8.0},["ArmoredSusanoo"]={["kind"]="offset",["startup"]=0.0,["delay"]=0.6,["radius"]=75.0,["offset"]=80.0},["Amaterasu"]={["kind"]="target",["startup"]=0.0,["delay"]=0.75,["range"]=150.0,["radius"]=30.0},["ArmoredRain"]={["kind"]="target",["startup"]=0.0,["delay"]=0.483,["range"]=200.0,["radius"]=90.0},["BlackLightning"]={["kind"]="target",["startup"]=0.0,["delay"]=0,["range"]=100.0,["radius"]=40.0},["ReversalRed"]={["kind"]="target",["startup"]=0.0,["delay"]=0.6,["range"]=150.0,["radius"]=20.0},["RoadRoller"]={["kind"]="target",["startup"]=0.7,["delay"]=0,["range"]=75.0,["radius"]=15.0},["EnergyBlast"]={["kind"]="line",["startup"]=0.7,["delay"]=0,["range"]=140.0,["speed"]=300.0},["FlyingSlash"]={["kind"]="line",["startup"]=0.2,["delay"]=0,["range"]=200.0,["speed"]=140.0},["SeriousTableFlip"]={["kind"]="line",["startup"]=0.15,["delay"]=0,["range"]=140.0,["speed"]=300.0},["DragonsBreath"]={["kind"]="line",["startup"]=0.1,["delay"]=0,["range"]=80.0},["BijuuBombPlayer"]={["kind"]="line",["startup"]=0.3,["delay"]=1.0,["range"]=300.0,["width"]=25.0,["speed"]=300.0},["KiBlasts"]={["kind"]="line",["startup"]=0.0,["delay"]=0,["width"]=5.0,["speed"]=220.0,["range"]=1100.0},["KnivesThrow"]={["kind"]="line",["startup"]=0.95,["delay"]=0,["range"]=120.0,["width"]=3.5,["speed"]=300.0},["HollowPurple"]={["kind"]="line",["startup"]=0.3,["delay"]=0.5,["range"]=600.0,["width"]=25.0,["speed"]=200.0,["offset"]=7.0},["Zoltraak"]={["kind"]="line",["startup"]=0.0,["delay"]=1.0,["range"]=180.0,["width"]=16.0},["BigBangKamehameha"]={["kind"]="line",["startup"]=0.0,["delay"]=0.4,["range"]=100.0,["width"]=15.0},["GiganticRoar"]={["kind"]="line",["startup"]=0.0,["delay"]=0.1,["range"]=100.0,["width"]=15.0},["Beelzebub"]={["kind"]="line",["startup"]=0.0,["delay"]=0.45,["range"]=75.0,["width"]=17.5},["Torch"]={["kind"]="line",["startup"]=0.0,["delay"]=0.1,["range"]=40.0},["RisingSunEdge"]={["kind"]="line",["startup"]=0.0,["delay"]=0.3,["range"]=120.0},["RapidPunch"]={["kind"]="melee",["startup"]=0.45,["delay"]=0,["range"]=13.0},["RapidPunchRework"]={["kind"]="melee",["startup"]=0.0,["delay"]=0,["range"]=13.0},["StandBarrage"]={["kind"]="melee",["startup"]=0.0,["delay"]=0.6,["range"]=20.0},["BlackFlash"]={["kind"]="melee",["startup"]=0.15,["delay"]=0,["range"]=6.0},["MoltenCore"]={["kind"]="dash",["startup"]=0.15,["delay"]=0,["range"]=50.0,["speed"]=300.0},["NightKickGuy"]={["kind"]="dash",["startup"]=0.0,["delay"]=0,["range"]=75.0,["speed"]=80.0},["HandDemonEnragedCharge"]={["kind"]="dash",["startup"]=0.0,["delay"]=0,["range"]=130.0,["speed"]=40.0},["MagmaFist"]={["kind"]="arc",["startup"]=0.175,["delay"]=0,["range"]=200,["radius"]=25.0,["speed"]=150.0,["arcRise"]=0.3333333333333333},["MagmaShower"]={["kind"]="arc",["startup"]=0.0,["delay"]=0,["range"]=100.0,["radius"]=15.0,["speed"]=300,["spread"]=3,["arcRise"]=0.3333333333333333},["TenjiKaijin"]={["kind"]="line",["startup"]=0.167,["delay"]=0.0,["range"]=300.0,["width"]=15.0,["speed"]=300.0},["ScorchingHell"]={["kind"]="radial",["startup"]=0.0,["delay"]=0,["radius"]=15.0},["SpecialM1"]={["kind"]="melee",["range"]=6,["startup"]=0,["delay"]=0,["specials"]={["CrazyDiamond"]=true,["TheWorld"]=true,["WhiteSnake"]=true,["Rika"]=true,["Centipede"]=true,["SilverChariot"]=true,["PhoenixTransformation"]=true,["Yamori"]=true,["ColossalTitan"]=true,["PerfectSusanoo"]=true,["Gear4"]=true,["AttackTitan"]=true,["StarPlatinum"]=true,["FemaleTitan"]=true,["Phoenix"]=true,["RedScale"]=true,["MadeInHeaven"]=true,["Cream"]=true,["ArmoredTitan"]=true,["TheHand"]=true,["Buddha"]=true,["SpiralBlade"]=true,["KillerQueen"]=true,["Debug"]=true,["OneEye"]=true,["GreatApe"]=true,["MagicianRed"]=true}},["BasicM1"]={["kind"]="melee",["range"]=6.5,["startup"]=0,["delay"]=0}}

local hit={motion={},attributes={},skipped=0,lastReason="—",perPower={},latency=0.1,nextPing=0}
combat.Hit=hit
hit.profiles=profiles
function hit.Sample(id,position,now,source)
    if typeof(position)~="Vector3" then return end
    local old=hit.motion[id]
    source=source or "replica"
    if old and old.source~=source then old=nil end
    if old and now-old.time<=0.015 then return end
    local sample={position=position,time=now,velocity=Vector3.zero,acceleration=0,samples=1,source=source}
    if old then
        local dt=now-old.time
        if dt>0.015 and dt<0.5 then
            local velocity=(position-old.position)/dt
            if velocity.Magnitude<=140 then
                sample.velocity=velocity*0.65+old.velocity*0.35
                sample.acceleration=math.min(160,(sample.velocity-old.velocity).Magnitude/dt)
                sample.samples=old.samples+1
            else sample.unstableUntil=now+0.3 end
        end
    end
    hit.motion[id]=sample
end
observe("replicateEntities",function(data)
    for i,id in ipairs(data.ids or {}) do hit.Sample(id,data.positions[i],os.clock()) end
end)
observe("spawnEntities",function(ids,names,models,positions)
    for i,id in ipairs(ids) do hit.motion[id]=nil hit.attributes[id]=nil hit.Sample(id,positions[i],os.clock()) end
end)
observe("replicateEntityAttributes",function(ids,attributes)
    for i,id in ipairs(ids) do hit.attributes[id]=attributes[i] end
end)
observe("despawnEntities",function(ids)
    for _,id in ipairs(ids) do hit.motion[id]=nil hit.attributes[id]=nil end
end)
function hit.Skip(id,reason)
    local old=hit.perPower[id]
    if not old or os.clock()-old.time>0.25 or old.reason~=reason then
        hit.skipped+=1 hit.perPower[id]={reason=reason,time=os.clock()}
    end
    hit.lastReason=id..": "..reason
    return false,reason
end
-- Solve |relative + velocity*t| = speed*t. No positive root means no intercept.
function hit.Intercept(relative,velocity,speed)
    if not speed or speed<=0 then return 0 end
    local a=velocity:Dot(velocity)-speed*speed
    local b=2*relative:Dot(velocity)
    local c=relative:Dot(relative)
    if c<0.001 then return 0 end
    if math.abs(a)<0.001 then return b<0 and -c/b or nil end
    local discriminant=b*b-4*a*c
    if discriminant<0 then return nil end
    local square=math.sqrt(discriminant)
    local x,y=(-b-square)/(2*a),(-b+square)/(2*a)
    if x>=0 and y>=0 then return math.min(x,y) end
    return x>=0 and x or (y>=0 and y or nil)
end
function hit.Geometry(profile,frame,position,velocity,body,latency,acceleration,remainingHold)
    local hold=remainingHold or math.clamp((profile.startup or 0)+0.05,0.1,2)
    local lead=hold+(profile.delay or 0)+(latency or 0.1)
    local relative=position+velocity*lead-frame.Position
    local flight=hit.Intercept(relative,velocity,profile.speed)
    if flight==nil then return false,"Projectile cannot catch target" end
    local arrival=lead+flight
    if velocity.Magnitude>1 and arrival>2.5 then return false,"Prediction is too long and uncertain" end
    local predicted=position+velocity*arrival
    local delta=predicted-frame.Position
    local distance=delta.Magnitude
    local uncertainty=0.5+velocity.Magnitude*(latency or 0.1)*0.5+math.min(24,(acceleration or 0)*arrival*arrival*0.15)
    local margin=uncertainty+(profile.spread or 0)
    if profile.range and distance+uncertainty>profile.range then return false,"Out of range ("..math.ceil(distance).." / "..profile.range..")" end
    if profile.kind=="radial" or profile.kind=="offset" then
        local center=frame.Position+frame.LookVector*(profile.offset or 0)
        if (predicted-center).Magnitude+margin>profile.radius then return false,"Outside hit area" end
    elseif profile.kind=="melee" then
        local localPoint=frame:PointToObjectSpace(predicted)
        if localPoint.Z>0 or math.abs(localPoint.X)+margin>body+1.5 or math.abs(localPoint.Y)+margin>body+2 then
            return false,"Target is outside attack alignment"
        end
    else
        if margin>body+(profile.width or profile.radius or 0) then return false,"Target movement is too uncertain" end
        if delta.Magnitude<0.01 then return false,"Invalid aim direction" end
    end
    return true,{point=predicted,arrival=arrival,distance=distance,uncertainty=uncertainty,profile=profile}
end
function hit.ClearPath(origin,point,profile)
    local params=RaycastParams.new()
    params.FilterType=Enum.RaycastFilterType.Include
    local include={workspace.Terrain}
    local map=workspace:FindFirstChild("Map") if map then table.insert(include,map) end
    params.FilterDescendantsInstances=include params.RespectCanCollide=true
    if profile.kind=="radial" or profile.kind=="offset" then return true end
    local previous=origin
    local control=(origin+point)/2+Vector3.new(0,(point-origin).Magnitude*(profile.arcRise or 0),0)
    local steps=profile.kind=="arc" and 12 or 1
    for i=1,steps do
        local t=i/steps
        local nextPoint=profile.kind=="arc" and ((1-t)^2*origin+2*(1-t)*t*control+t*t*point) or point
        local segment=nextPoint-previous
        if segment.Magnitude>0.01 then
            local collision=workspace:Raycast(previous,segment,params)
            if collision then return false,"Obstacle in path: "..collision.Instance.Name end
        end
        previous=nextPoint
    end
    return true
end
function hit.CanCast(id,target,definition,remainingHold)
    local profile=profiles[id]
    local _,_,root=character()
    if not root or not target or mobs.dead[target.id] or (target.hp and target.hp<=0)
        or (not target.player and mobs.entities[target.id]~=target) then return hit.Skip(id,"No valid living target") end
    if definition and definition.Transformation then return true,{buff=true,profile={startup=definition.startupDelay or 0}} end
    if not profile then return hit.Skip(id,"Ability geometry is unverified") end
    if id=="SpecialM1" and not profile.specials[player.Character:GetAttribute("specialEquipped")] then
        return hit.Skip(id,"Equipped Special has no verified M1")
    end
    local attributes=hit.attributes[target.id]
    if (attributes and attributes.isInvulnerable==true) or (target.model and target.model:GetAttribute("isInvulnerable")==true) then
        return hit.Skip(id,"Target is invulnerable")
    end
    if os.clock()>=hit.nextPing then
        hit.nextPing=os.clock()+2
        local ok,ping=pcall(player.GetNetworkPing,player)
        if ok and type(ping)=="number" then hit.latency=math.clamp(ping,0.03,0.25) end
    end
    local position=mobPosition(target)
    if not position then return hit.Skip(id,"Target position is not loaded") end
    local sample=hit.motion[target.id]
    local pollAfter=sample and sample.source=="model" and 0.045 or 0.15
    if target.model and target.model:IsDescendantOf(workspace) and (not sample or os.clock()-sample.time>pollAfter) then
        -- Native render motion is a fallback when unchanged positions are not sent in replica packets.
        -- Switching sources resets velocity instead of combining simulation and interpolation coordinates.
        hit.Sample(target.id,position,os.clock(),"model")
        sample=hit.motion[target.id]
    end
    if not sample then hit.Sample(target.id,position,os.clock()) return hit.Skip(id,"Waiting for target movement samples") end
    if sample.unstableUntil and os.clock()<sample.unstableUntil then return hit.Skip(id,"Target just moved") end
    if os.clock()-sample.time>0.35 then
        -- A replica stream must remain current; never extrapolate a stale moving boss.
        return hit.Skip(id,"Stale movement replication")
    end
    if sample.samples<2 then return hit.Skip(id,"Waiting for second movement sample") end
    local body=1
    local model=target.model
    local box=model and model:FindFirstChild("_AimHitbox")
    if box and box:IsA("BasePart") then body=math.clamp(math.min(box.Size.X,box.Size.Y,box.Size.Z)*0.3,1,30) end
    local accepted,result=hit.Geometry(profile,root.CFrame,position,sample.velocity,body,hit.latency,sample.acceleration,remainingHold)
    if not accepted then return hit.Skip(id,result) end
    local clear,reason=hit.ClearPath(root.Position,result.point,profile)
    if not clear then return hit.Skip(id,reason) end
    if profile.kind=="dash" then
        if defense.point then return hit.Skip(id,"Movement ability during dodge") end
        local zone=defense.ArenaFor(target)
        if not zone then return hit.Skip(id,"Arena not verified for movement ability") end
        local direction=(result.point-root.Position).Unit
        for i=1,math.ceil(profile.range/6) do
            local p=root.Position+direction*math.min(profile.range,i*6)
            local safe=defense.Safety.Validate(p,zone,true)
            if not safe or (safe-p).Magnitude>1.5 then return hit.Skip(id,"Ability crosses unsafe ground") end
        end
    end
    return true,result
end
-- Casting is deliberately independent of hit admission; geometry only improves aim.
function hit.CastPlan(id,target,definition,remainingHold)
    local _,_,root=character()
    if not root or not target or mobs.dead[target.id] or (target.hp and target.hp<=0)
        or (not target.player and mobs.entities[target.id]~=target) then return false end
    local position=combat.TargetPoint(target)
    if not position then return false end
    local pivot=mobPosition(target)
    local now=os.clock()
    local old=hit.motion[target.id]
    if pivot and (not old or now-old.time>0.1) then hit.Sample(target.id,pivot,now,"model") end
    if definition and definition.Transformation then return true,{buff=true} end
    local point=position
    local profile=profiles[id]
    local sample=hit.motion[target.id]
    -- Unknown geometry still follows fresh target motion; never reuse a stale launch point.
    if sample and sample.samples>=2 and now-sample.time<=0.35
        and not (sample.unstableUntil and now<sample.unstableUntil) then
        local hold=remainingHold~=nil and math.max(0,remainingHold) or ((definition and definition.startupDelay) or 0)
        point=position+sample.velocity*(hold+hit.latency)
    end
    if profile and sample and sample.samples>=2 and os.clock()-sample.time<=0.35
        and not (sample.unstableUntil and os.clock()<sample.unstableUntil) then
        local ok,prediction=hit.Geometry(profile,root.CFrame,position,sample.velocity,1,hit.latency,sample.acceleration,remainingHold~=nil and remainingHold or math.max((definition and definition.startupDelay) or 0,profile.startup or 0))
        if ok then point=prediction.point else
            local lead=(remainingHold~=nil and math.max(0,remainingHold) or math.max((definition and definition.startupDelay) or 0,profile.startup or 0))+(profile.delay or 0)+hit.latency
            local ahead=position+sample.velocity*lead
            local flight=profile.speed and hit.Intercept(ahead-root.Position,sample.velocity,profile.speed) or 0
            if flight and lead+flight<=3 then point=ahead+sample.velocity*flight end
        end
    end
    hit.lastReason="Auto Cast · all ready abilities"
    return true,{point=point,profile=profile}
end
function defense.OffenseScore(point,target)
    local now=os.clock()
    local cache=hit.positionPowers
    local equipped=player.Character and player.Character:GetAttribute("specialEquipped")
    if not cache or now>=cache.expires or cache.equipped~=equipped then
        local ids={}
        if config.castPowers and api.AvailablePowers then
            for _,entry in ipairs(api.AvailablePowers()) do
                if not entry.definition.Transformation then ids[entry.id]=true end
            end
        end
        if config.castSpecials then
            local level=combat.SpecialLevel and combat.SpecialLevel(equipped) or 0
            for _,entry in pairs(combatMetadata.specials[equipped] or {}) do
                if type(entry)=="table" and entry.powerId and level>=(entry.levelRequirement or 0) then ids[entry.powerId]=true end
            end
        end
        cache={ids=ids,expires=now+0.5,equipped=equipped} hit.positionPowers=cache
    end
    local position=mobPosition(target)
    if not position or (position-point).Magnitude<0.01 then return 0 end
    local sample=hit.motion[target.id]
    local frame=CFrame.lookAt(point,position)
    local count=0
    for id in pairs(cache.ids) do
        local profile=profiles[id]
        if profile and profile.kind~="dash" and (combat.cooldowns[id] or 0)<=now then
            local ok,result=hit.Geometry(profile,frame,position,sample and sample.velocity or Vector3.zero,1,hit.latency,sample and sample.acceleration or 0)
            if ok and hit.ClearPath(point,result.point,profile) then count+=1 end
        end
    end
    return count
end
end -- hit prediction scope

local function combatActive()
    return state.alive and not state.fruitBusy and (flags.AutoDungeon or flags.MobFarm or flags.BossFarm or flags.AutoQuest or flags.KillAllPlayers or flags.KillSelectedPlayer) and mobs.CanAttack(mobs.target)
end
-- Stat equipment is independent of Special slots and of the basic-attack toggle.
-- Reconfirm it after server unequip/stun without waiting on a training RPC.
function combat.EnsureWeapon(c,weapon,token)
    if not valid(token) or not c or player.Character~=c then return false end
    if c:GetAttribute("statEquipped")==weapon then
        combat.weaponStatus=weapon.." confirmed"
        return true
    end
    local pending=combat.weaponEquip
    if not pending or pending.character~=c or pending.weapon~=weapon or pending.token~=token
        or os.clock()>=pending.retryAt then
        combat.weaponEquip={character=c,weapon=weapon,token=token,retryAt=os.clock()+0.75}
        local ok,why=fire("equipStat",{state=true,statType=weapon})
        combat.weaponStatus=ok and "Waiting for equip: "..weapon or tostring(why)
    end
    return false
end
local function releaseOneCast(id,held)
    if combat.held[id]~=held then return end
    combat.held[id]=nil
    if combat.Aim then
        for identifier,entry in pairs(combat.aims) do
            if entry.powerId==id and entry.target==mobs.target then combat.Aim(identifier,entry.target,true) end
        end
    end
    if held.key then fire("requestSpecialReleased",held.key)
    else fire("setServerPowerReleased",held.id) end
end
local function releaseCast()
    for id,held in pairs(combat.held) do releaseOneCast(id,held) end
end
function mobs.SuspendCombat()
    local waiting
    if flags.AutoDungeon and dungeon.Active() and defense.hover and not state.move then
        local _,_,root=character()
        if root and defense.Safety.Air(root.Position) then waiting=root.CFrame end
    end
    releaseCast() table.clear(combat.aims) table.clear(combat.pending)
    if combat.plans then table.clear(combat.plans) end
    combat.equipJob=nil
    defense.point=nil defense.target=nil defense.hover=waiting and true or nil defense.waitPoint=waiting
end
-- One cleanup path for death, despawn, cancellation and segment failures.
function mobs.ReleaseTarget(target)
    if not target or mobs.target~=target then return end
    local waiting
    if flags.AutoDungeon and dungeon.Active() and defense.hover then
        local _,_,root=character()
        if root and defense.Safety.Air(root.Position) then waiting=root.CFrame end
    end
    mobs.target=nil mobs.targetToken=nil
    combat.equipJob=nil
    combat.weapon=nil combat.weaponEquip=nil
    releaseCast()
    table.clear(combat.aims) table.clear(combat.pending)
    if combat.plans then table.clear(combat.plans) end
    defense.point=nil defense.target=nil defense.hover=waiting and true or nil defense.waitPoint=waiting
    defense.status=waiting and "Dungeon · holding between targets" or "Waiting for boss"
end
local function aimPower(identifier,target,force)
    local _,_,root=character()
    local entry=combat.aims[identifier]
    if not root or not combatActive() or not mobs.IsLive(target) or not entry or entry.target~=target or not valid(entry.token) then return end
    local now=os.clock()
    if not force and now<(entry.nextAim or 0) then return end
    entry.nextAim=now+1/60
    local allowed,prediction=combat.Hit.CastPlan(entry.powerId,target,combatMetadata.powers[entry.powerId],math.max(0,(entry.releaseAt or 0)-os.clock()))
    if allowed and not prediction.buff then entry.point=prediction.point end
    local point=entry.point
    if not point then return end
    local direction=point-root.Position
    if direction.Magnitude<0.001 then return end
    fire("setServerAimInfo",{identifier=identifier,aimInfo={direction=direction.Unit,position=point,holdDuration=math.max(0,math.min(now,entry.releaseAt or now)-(entry.startedAt or now))}})
    combat.aimUpdates=(combat.aimUpdates or 0)+1
end
combat.Aim=aimPower
-- A release sent before the server created the power may be ignored. Confirm it
-- again after acknowledgement, without releasing a newer cast or a different slot.
function combat.ReleaseAcknowledged(id,plan)
    local delay=math.max(0,(plan.releaseAt or 0)-os.clock())
    task.delay(delay,function()
        if not valid(plan.token) or plan.target~=mobs.target or not mobs.IsLive(plan.target) or plan.character~=player.Character then return end
        local current=combat.held[id]
        if current and current~=plan.held then return end
        if plan.key and player.Character:GetAttribute("specialEquipped")~=plan.special then return end
        if plan.ackReleased then return end
        plan.ackReleased=true
        if current then releaseOneCast(id,current) else
            for identifier,entry in pairs(combat.aims) do
                if entry.powerId==id and entry.target==plan.target then aimPower(identifier,plan.target,true) end
            end
            if plan.key then fire("requestSpecialReleased",plan.key) else fire("setServerPowerReleased",id) end
        end
        combat.confirmedReleases=(combat.confirmedReleases or 0)+1
    end)
end
observe("syncPowerCooldown",function(info)
    if type(info)=="table" and info.powerId then
        combat.cooldowns[info.powerId]=os.clock()+math.max(0,info.remaining or 0)
        local plan=combat.plans and combat.plans[info.powerId]
        if plan then plan.cooldownSynced=true end
    end
end)
observe("createClientPower",function(info)
    if not combatActive() or info.owner~=player.Character then return end
    if not combat.pending[info.powerId] or combat.pending[info.powerId]<os.clock() then return end
    local plan=combat.plans and combat.plans[info.powerId]
    if not plan or not valid(plan.token) or plan.character~=player.Character or plan.target~=mobs.target then return end
    if not plan.accepted then
        plan.accepted=true combat.acceptedCasts=(combat.acceptedCasts or 0)+1
        if not plan.cooldownSynced then
            local d=combat.PowerDefinition(info.powerId,plan.special)
            combat.cooldowns[info.powerId]=os.clock()+math.max(1,d and d.baseCooldown or 5)
        end
    end
    combat.aims[info.identifier]={token=plan.token,target=plan.target,powerId=info.powerId,point=plan.point,releaseAt=plan.releaseAt,startedAt=plan.startedAt,expires=os.clock()+math.max(8,(combat.Hit.profiles[info.powerId] and combat.Hit.profiles[info.powerId].range or 0)/math.max(1,combat.Hit.profiles[info.powerId] and combat.Hit.profiles[info.powerId].speed or 60)+4)}
    aimPower(info.identifier,mobs.target)
    combat.ReleaseAcknowledged(info.powerId,plan)
end)
observe("destroyClientPower",function(id) combat.aims[id]=nil end)
do
function combat.WarmPowerList()
    if combat.powerWarmBusy or os.clock()<(combat.nextPowerWarm or 0) or not combatActive() then return end
    local page=path(player.PlayerGui,"Main.Pages.Powers")
    local button=path(player.PlayerGui,"Main.HUD.PageButtons.Tabs.List.Powers")
    if not page or page.Visible or not button or not button:IsA("GuiButton") then return end
    combat.powerWarmBusy=true combat.nextPowerWarm=os.clock()+15
    local token=state.generation
    task.spawn(function()
        local function click(control)
            if not valid(token) or not control or not control:IsA("GuiButton") or control.AbsoluteSize.X<=0 then return false end
            local point=control.AbsolutePosition+control.AbsoluteSize/2
            local inset=game:GetService("GuiService"):GetGuiInset()
            return pcall(function()
                local input=game:GetService("VirtualInputManager")
                input:SendMouseButtonEvent(point.X,point.Y+inset.Y,0,true,game,0)
                input:SendMouseButtonEvent(point.X,point.Y+inset.Y,0,false,game,0)
            end)
        end
        if click(button) then
            task.wait(0.35)
            if valid(token) and page.Visible then click(path(page,"Page.CloseButton")) end
        end
        combat.powerWarmBusy=false
    end)
end
end -- native power list warmup scope
function combat.PowerDefinition(id,special)
    local base=combatMetadata.powers[id]
    local overrides=special and combatMetadata.specialOverrides[special]
    local override=overrides and overrides[id]
    if not base or not override then return base end
    local result=table.clone(base)
    for key,value in pairs(override) do result[key]=value end
    return result
end
local function availablePowers()
    local found={}
    for id in pairs(combat.observedPowers or {}) do found[id]=true end
    for id,q in pairs(quests.known) do
        local definition=quests.catalog[id]
        if q.Redeemed and definition then
            for _,reward in ipairs(definition.Rewards and definition.Rewards.Power or {}) do
                if reward.Id then found[reward.Id]=true end
            end
        end
    end
    local owned=dataAt("Powers")
    if type(owned)=="table" then for _,id in pairs(owned) do found[id]=true end end
    local list=path(player.PlayerGui,"Main.Pages.Powers.Page.Main.Bottom.List")
    if list then for _,row in ipairs(list:GetChildren()) do
        local locked=row:FindFirstChild("Locked",true)
        if row:IsA("GuiObject") and row.Name~="Template" and locked and not locked.Visible then found[row.Name]=true end
    end end
    combat.observedPowers=combat.observedPowers or {}
    for id in pairs(found) do combat.observedPowers[id]=true end
    if next(found)==nil then combat.WarmPowerList() end
    if config.powerMode=="Equipped Only" and not (flags.AutoDungeon or flags.KillAllPlayers or flags.KillSelectedPlayer) then
        local bound=dataAt("PowerKeybinds") or {}
        local skillset=dataAt("PowerSkillset1") or {}
        for id in pairs(found) do if not bound[id] and not table.find(skillset,id) then found[id]=nil end end
    end
    local assigned=path(player.PlayerGui,"Main.Pages.Powers.Page.Main.AssignedList")
    local equipped={}
    if assigned then for _,row in ipairs(assigned:GetChildren()) do
        if row:IsA("GuiObject") and row.Visible and combatMetadata.powers[row.Name] then found[row.Name]=true equipped[row.Name]=true end
    end end
    if config.powerMode=="Equipped Only" and not (flags.AutoDungeon or flags.KillAllPlayers or flags.KillSelectedPlayer) then
        for id in pairs(found) do if not equipped[id] and not (dataAt("PowerKeybinds") or {})[id] then found[id]=nil end end
    end
    local result={}
    for id in pairs(found) do
        local d=combatMetadata.powers[id]
        -- Movement and transformation toggles must not cancel combat or be spammed as attacks.
        if d and ((d.bossDamage or 0)>0 or d.Transformation) then table.insert(result,{id=id,definition=d}) end
    end
    table.sort(result,function(a,b)
        local x=(a.definition.bossDamage or 0)/math.max(1,a.definition.baseCooldown or 1)
        local y=(b.definition.bossDamage or 0)/math.max(1,b.definition.baseCooldown or 1)
        return x>y or (x==y and a.id<b.id)
    end)
    return result
end
local function specialSlots()
    local result={}
    local hotbar=path(player.PlayerGui,"Main.HUD.Hotbar")
    if not hotbar then return result end
    for _,row in ipairs(hotbar:GetChildren()) do
        local index=tonumber(row.Name:match("^Slot(%d+)$"))
        local icon=row:FindFirstChild("SpecialIcon",true)
        local id=icon and combatMetadata.specialIcons[icon.Image]
        if icon and not id then
            local asset=icon.Image:match("%d+$")
            if asset then for image,special in pairs(combatMetadata.specialIcons) do
                if image:match("%d+$")==asset then id=special break end
            end end
        end
        if index and row.Visible and id then
            local serverIndex=index==0 and 6 or index-4
            if serverIndex>=1 and serverIndex<=6 then table.insert(result,{index=serverIndex,hotbarIndex=index,id=id}) end
        end
    end
    local keys={Five=1,Six=2,Seven=3,Eight=4,Nine=5,Zero=6}
    for key,entry in pairs(dataAt("SlotKeybinds") or {}) do
        if type(entry)=="table" and entry.Type=="Special" and keys[key] then
            local kind=dataAt("Specials."..tostring(entry.Identifier))
            local slots=kind and kind.SpecialSlots
            local selected=kind and kind.SelectedSpecialSlot
            local slot=slots and (slots[tostring(selected)] or slots[tonumber(selected)])
            local id=slot and slot.special
            if id and combatMetadata.specials[id] then
                local exists=false for _,v in ipairs(result) do if v.index==keys[key] then exists=true break end end
                if not exists then table.insert(result,{index=keys[key],id=id}) end
            end
        end
    end
    table.sort(result,function(a,b) return a.index<b.index end)
    return result
end
local function specialLevel(id)
    local mastery=dataAt("SpecialMastery")
    if mastery and mastery[id] then return mastery[id].Level or 0 end
    local c=player.Character
    if c and c:GetAttribute("specialEquipped")==id then
        local holder=path(player.PlayerGui,"Main.HUD.SpecialKeybinds")
        local label=holder and holder:FindFirstChild("Level",true)
        if label and label:IsA("TextLabel") then return tonumber(label.Text:match("%d+")) or 0 end
    end
    return 0
end
local function castAttack(id,key,target,token)
    local d=combat.PowerDefinition(id,key and player.Character and player.Character:GetAttribute("specialEquipped"))
    if not d or combat.held[id] or (combat.cooldowns[id] or 0)>os.clock() then return false end
    -- These utility moves do no boss damage and displace the character outside the combat lease.
    if id=="Blink" or id=="FlashStep" or id=="Dash" or id=="Flight" then return false end
    if d.Transformation and player.Character and player.Character:GetAttribute("currentTransformation")==id then return false end
    local _,_,root=character()
    local position=mobPosition(target)
    if not valid(token) or not root or not position or not mobs.CanAttack(target) then return false end
    local hittable,prediction=combat.Hit.CastPlan(id,target,d)
    if not hittable then return false end
    if prediction.profile and prediction.profile.kind=="dash" and not target.player and not combat.Hit.CanCast(id,target,d) then return false end
    local previous=combat.plans and combat.plans[id]
    local failures=previous and previous.target==target and not previous.accepted and not previous.cooldownSynced and (previous.failures or 0)+1 or 0
    local ackWait=math.clamp((2*(combat.Hit.latency or 0.1)+0.15)*1.5^math.min(failures,5),0.3,2)
    combat.cooldowns[id]=os.clock()+ackWait
    combat.pending[id]=os.clock()+8
    combat.plans=combat.plans or {}
    local hold=math.max(1/60,d.startupDelay or 0)
    combat.plans[id]={startedAt=os.clock(),failures=failures,retryAt=os.clock()+ackWait,key=key,point=prediction.point,target=target,character=player.Character,token=token,releaseAt=os.clock()+hold}
    local held={id=id,key=key,character=player.Character}
    combat.held[id]=held
    combat.plans[id].held=held combat.plans[id].special=player.Character and player.Character:GetAttribute("specialEquipped")
    local ok,why
    if key then ok,why=fire("requestSpecialPressed",key) else ok,why=fire("createServerPower",id) end
    if not ok then
        combat.held[id]=nil combat.pending[id]=nil
        combat.cooldowns[id]=os.clock()+1 state.error=tostring(why)
        return false
    end
    -- Independent hold releases allow other powers, movement and defensive teleports.
    task.delay(hold,function()
        -- Stop/respawn already releases and removes this exact hold; never release a newer cast.
        if state.alive then releaseOneCast(id,held) end
    end)
    combat.casts+=1
    return true
end
local function specialReady(id)
    local level=specialLevel(id)
    for _,ability in pairs(combatMetadata.specials[id] or {}) do
        local d=combat.PowerDefinition(ability.powerId,id)
        if d and level>=(ability.levelRequirement or 0) and not combat.held[ability.powerId]
            and (combat.cooldowns[ability.powerId] or 0)<=os.clock()
            and (not d.Transformation or not player.Character or player.Character:GetAttribute("currentTransformation")~=ability.powerId) then return true end
    end
    return false
end
local function equipSpecialStep(c,token,target)
    if not valid(token) or not c or player.Character~=c then return false end
    for _,held in pairs(combat.held) do if held.key then return true end end
    if quests.requiredSpecial or os.clock()<combat.nextEquip then return true end
    local slots=specialSlots()
    if #slots==0 then
        combat.nextEquip=os.clock()+2 combat.equipStatus="No loaded Special slots"
        return false
    end
    local selected
    if config.specialMode=="Rotate All" or flags.KillAllPlayers or flags.KillSelectedPlayer then
        for offset=1,#slots do
            local index=(combat.slotCursor+offset-1)%#slots+1
            if specialReady(slots[index].id) then combat.slotCursor=index selected=slots[index] break end
        end
        if not selected then combat.nextEquip=os.clock()+0.25 return true end
    else
        for _,slot in ipairs(slots) do
            if config.specialMode=="Slot "..slot.index.." · "..slot.id then selected=slot break end
        end
    end
    if not selected then combat.equipStatus="Selected Special is no longer in a slot" return false end
    local equipped=c:GetAttribute("specialEquipped")
    if selected.id~=equipped then
        if target and (mobs.target~=target or not mobs.IsLive(target)) then return false end
        local ok,why=fire("equipSpecial",selected.index)
        if not ok then combat.equipStatus=tostring(why) combat.nextEquip=os.clock()+2 return false end
        local deadline=os.clock()+2
        repeat
            if not valid(token) or player.Character~=c or (target and (mobs.target~=target or not mobs.IsLive(target))) then return false end
            if c:GetAttribute("specialEquipped")==selected.id then break end
            if not waitFor(0.05,token) then return false end
        until os.clock()>=deadline
        if c:GetAttribute("specialEquipped")~=selected.id then
            combat.equipStatus="Server has not confirmed slot: "..selected.index.." · "..selected.id
            combat.nextEquip=os.clock()+2 return false
        end
        combat.equips=(combat.equips or 0)+1
    end
    combat.equipStatus=selected.id.." · slot "..selected.index
    combat.nextEquip=os.clock()+math.clamp(config.specialRotateSeconds or 10,3,30)
    return true
end
-- Equip confirmation may yield; powers and the defensive movement owner never wait for it.
function combat.RequestEquip(c,token,target)
    if combat.equipJob or os.clock()<combat.nextEquip or not valid(token) then return end
    for _,held in pairs(combat.held) do if held.key then return end end
    for _,plan in pairs(combat.plans or {}) do
        if plan.key and not plan.accepted and plan.target==target and os.clock()<(plan.retryAt or 0) then return end
    end
    local job={target=target,token=token}
    combat.equipJob=job
    task.spawn(function()
        local ok,err=xpcall(function() equipSpecialStep(c,token,target) end,debug.traceback)
        if combat.equipJob==job then combat.equipJob=nil end
        if not ok and valid(token) then combat.nextEquip=os.clock()+2 state.error=tostring(err) end
    end)
end
function combat.Priority(attack,target)
    local d=attack.definition
    local score=(d.bossDamage or 0)/math.max(0.1,(d.startupDelay or 0)+0.05)
    local profile=(combat.Hit.profiles or {})[attack.id]
    local _,_,root=character()
    local position=mobPosition(target)
    if profile and root and position then
        local limit=profile.range or profile.radius
        if limit and (root.Position-position).Magnitude>limit+2 then score=score*0.001 end
    end
    return score
end
local function combatStep(target,token)
    if not valid(token) or not combatActive() or not mobs.IsLive(target) then return end
    if combat.weapon and mobs.target==target and mobs.targetToken==token then
        combat.EnsureWeapon(player.Character,combat.weapon,token)
    end
    local forced=flags.AutoDungeon or (target.player and (flags.KillAllPlayers or flags.KillSelectedPlayer))
    local now=os.clock()
    if now<(combat.nextPulse or 0) then return end
    combat.nextPulse=now+1/60
    -- Bound rejected retries; a burst of ready skills is immediate, ongoing attempts
    -- are paced independently of cooldowns so they cannot flood the server or starve dodges.
    combat.requestTokens=math.min(8,(combat.requestTokens or 8)+math.max(0,now-(combat.lastBudget or now))*12)
    combat.lastBudget=now
    local c=player.Character
    local definition=mobs.catalog[target.name]
    if (config.specialMode=="Rotate All" or flags.KillAllPlayers or flags.KillSelectedPlayer) and c and not specialReady(c:GetAttribute("specialEquipped")) then
        combat.nextEquip=math.min(combat.nextEquip,now)
    end
    combat.RequestEquip(c,token,target)
    if not flags.AutoDungeon and not target.player and (not definition or not definition.isBoss) then return end
    if (config.castSpecialM1 or forced) and not combat.equipJob and c and c:GetAttribute("specialEquipped") and now>=(combat.nextM1 or 0) then
        combat.nextM1=now+1.1 fire("activateServerSpecial")
    end
    -- One ready queue across both categories: high damage/cooldown first, all ready requests in this pulse.
    local ready={}
    if config.castPowers or forced then
        if not combat.powerWarmAttempted then
            combat.WarmPowerList()
            combat.powerWarmAttempted=combat.powerWarmBusy==true
        end
        if not combat.powerList or combat.powerListMode~=config.powerMode or now>=(combat.nextPowerScan or 0) then
            combat.powerList=availablePowers() combat.powerListMode=config.powerMode combat.nextPowerScan=now+0.25
        end
        local powers=combat.powerList
        if (config.autoTransform or forced) and c and not c:GetAttribute("currentTransformation") then
            local best
            for _,power in ipairs(powers) do
                if power.definition.Transformation and (not best or (power.definition.damageMultiplier or 0)>(best.definition.damageMultiplier or 0)) then best=power end
            end
            if best then castAttack(best.id,nil,target,token) end
        end
        for _,power in ipairs(powers) do
            if not power.definition.Transformation then table.insert(ready,{id=power.id,definition=power.definition}) end
        end
    end
    if (config.castSpecials or forced) and not combat.equipJob and valid(token) and mobs.IsLive(target) then
        local equipped=c and c:GetAttribute("specialEquipped")
        local level=specialLevel(equipped)
        for _,key in ipairs({"Z","X","C","V"}) do
            local ability=equipped and combatMetadata.specials[equipped] and combatMetadata.specials[equipped][key]
            if ability and level>=(ability.levelRequirement or 0) then
                local d=combat.PowerDefinition(ability.powerId,equipped)
                if d then table.insert(ready,{id=ability.powerId,key=key,definition=d}) end
            end
        end
    end
    for _,attack in ipairs(ready) do attack.score=combat.Priority(attack,target) end
    table.sort(ready,function(a,b)
        local x=a.score
        local y=b.score
        return x>y or (x==y and a.id<b.id)
    end)
    -- Both input paths receive the initial burst, even when many normal powers are ready.
    if #ready>1 then
        local firstSpecial=ready[1].key~=nil
        for index=2,#ready do
            if (ready[index].key~=nil)~=firstSpecial then
                local other=table.remove(ready,index) table.insert(ready,2,other) break
            end
        end
    end
    for _,attack in ipairs(ready) do
        if combat.requestTokens<1 then break end
        if castAttack(attack.id,attack.key,target,token) then combat.requestTokens-=1 end
    end
end
combat.Step=combatStep
combat.SpecialLevel=specialLevel
combat.StepEquip=equipSpecialStep
api.Combat=combat
api.AvailablePowers=availablePowers
api.SpecialSlots=specialSlots

function api.StopAll()
    dungeon.farm={status="Idle"}
    if Adapter.Troll then Adapter.Troll.status="Idle" end
    config.farmBosses=false state.bossPriority=false state.bossProbe=nil state.nextBossProbe=nil
    defense.point=nil defense.target=nil defense.hover=nil defense.waitPoint=nil defense.status="Idle"
    state.generation += 1
    combat.equipJob=nil
    combat.weapon=nil combat.weaponEquip=nil
    releaseCast() table.clear(combat.aims)
    for name in pairs(flags) do flags[name]=false end
    api.CancelMove() releaseTraining() restoreCharacter() restoreVisuals() clearESP()
    mobs.target=nil mobs.acceptedQuest=nil mobs.bossRun=nil
    fruits.status="Idle" fruits.target=nil
    if dungeon.pending and workspace:GetAttribute("Place")~="Dungeon" then fire("cancelQueue") dungeon.pending=nil end
    for _,item in ipairs(toggleControls) do pcall(item.control.Set,item.control,false) end
    state.action="Idle" state.target="—" state.waiting="—"
end
function api.Unload()
    if not state.alive then return end
    api.StopAll()
    state.alive=false
    for _,disconnect in ipairs(mobs.callbacks) do pcall(disconnect) end
    table.clear(mobs.callbacks)
    for _,connection in ipairs(connections) do connection:Disconnect() end
    table.clear(connections)
    if window then window:Destroy() end
    if env.AFS==api then env.AFS=nil end
end
function api.Set(name,value)
    if not state.alive or not state.ready or flags[name]==nil then return end
    value=value==true
    if name=="AutoDungeon" and value and workspace:GetAttribute("Place")~="Dungeon" then
        state.waiting="Auto Dungeon requires an existing dungeon" return
    end
    local changed=flags[name]~=value
    local exclusive={AutoDungeon=true,AutoQuest=true,QuestScan=true,Train=true,MobFarm=true,BossFarm=true,KillAllPlayers=true,KillSelectedPlayer=true,Fly=true}
    if exclusive[name] or (name=="TargetMainQuest" and changed and (flags.AutoQuest or flags.QuestScan)) then
        state.generation+=1 api.CancelMove() releaseTraining() mobs.ReleaseTarget(mobs.target) releaseCast()
        defense.waitPoint=nil defense.hover=nil
        mobs.target=nil mobs.acceptedQuest=nil
        if name=="TargetMainQuest" then quests.current=nil quests.requiredSpecial=nil end
        if value and exclusive[name] then
            if name~="AutoQuest" and name~="QuestScan" and not (name=="BossFarm" and flags.AutoQuest) then quests.requiredSpecial=nil quests.current=nil end
            for other in pairs(exclusive) do
                local shared=(name=="AutoQuest" and other=="BossFarm") or (name=="BossFarm" and other=="AutoQuest")
                if other~=name and not shared then flags[other]=false end
            end
        end
        if dungeon.pending and workspace:GetAttribute("Place")~="Dungeon" then fire("cancelQueue") dungeon.pending=nil end
    end
    if name=="FruitSnipe" or name=="AutoJoinBoss" then
        state.generation+=1 api.CancelMove() releaseTraining() mobs.target=nil
        if name=="FruitSnipe" then
            fruits.status=value and "Scanning map..." or "Idle"
            if value then flags.Fly=false end
        elseif not value and dungeon.pending and workspace:GetAttribute("Place")~="Dungeon" then
            fire("cancelQueue") dungeon.pending=nil
        end
    end
    if name=="Fly" and value and flags.FruitSnipe then api.Set("FruitSnipe",false) end
    if value and (name=="AutoDungeon" or name=="KillAllPlayers" or name=="KillSelectedPlayer") then
        flags.FruitSnipe=false fruits.status="Idle"
    end
    flags[name]=value
    if name=="AutoDungeon" then
        defense.waitPoint=nil defense.hover=nil
        dungeon.farm={status=value and "Finding dungeon enemies" or "Idle",job=value and game.JobId or nil,lastScan=0,emptySince=os.clock()}
        if value then combat.powerList=nil combat.nextPowerScan=0 combat.nextEquip=0 end
    end
    if Adapter.Troll and (name=="KillAllPlayers" or name=="KillSelectedPlayer") then Adapter.Troll.status=value and "Finding eligible players..." or "Idle" end
    config.farmBosses=flags.BossFarm
    if not flags.BossFarm then mobs.bossRun=nil
    elseif name=="BossFarm" and value and (changed or not mobs.bossRun) then
        mobs.bossRun={selected=table.clone(config.bosses),served={},round=1}
    end
    if exclusive[name] then
        if value then
            local c=character()
            state.trainingSnapshot=c and {character=c,stat=c:GetAttribute("statEquipped")} or nil
        else state.action="Idle" state.target="—" state.waiting="Stopped" end
    end
    for _,item in ipairs(toggleControls) do pcall(item.control.Set,item.control,flags[item.name]) end
    if not value and name=="ESP" then clearESP() end
    if not value and (name=="FOV" or name=="Fullbright") then restoreVisuals(name) end
    applyPlayer()
end
function api.CancelAutomationMovement()
    for _,name in ipairs({"AutoQuest","QuestScan","AutoDungeon","FruitSnipe","AutoJoinBoss","MobFarm","BossFarm","KillAllPlayers","KillSelectedPlayer","Train","Fly"}) do
        if flags[name] then api.Set(name,false) end
    end
    state.generation+=1
    api.CancelMove() releaseTraining() mobs.ReleaseTarget(mobs.target) releaseCast()
    state.bossPriority=false state.bossProbe=nil state.nextBossProbe=nil
    defense.point=nil defense.target=nil defense.waitPoint=nil defense.hover=nil
    state.action="Idle" state.target="—" state.waiting="Movement cancelled"
end
local trainingStats={"Strength","Durability","Chakra","Sword","Speed / Agility"}
local function nextStat(index)
    if not config.cycle then return config.stat,index end
    index=index%#trainingStats+1
    return trainingStats[index],index
end

do
-- Verified Accessories.Leg definitions; the native dictionary may be unavailable in executors.
local gear={status="Idle",busy=false,retryAt=0}
Adapter.TrainingGear=gear
local fallback={
    HeavyLegWeights={Boosts={StatGainMultiplier={Speed=33.5,Agility=33.5}}},
    MediumLegWeights={Boosts={StatGainMultiplier={Speed=7,Agility=7}}},
    LightLegWeights={Boosts={StatGainMultiplier={Speed=3.5,Agility=3.5}}},
}
local definitions=module("Configs.Accessories")
function gear.Candidates(stat)
    local catalog=fallback
    if definitions and type(definitions.getAll)=="function" then
        local ok,all=pcall(definitions.getAll) if ok and type(all)=="table" then catalog=all end
    end
    local choices={}
    for id,d in pairs(catalog) do
        local gains=d.Boosts and d.Boosts.StatGainMultiplier
        local score=type(gains)=="table" and gains[stat]
        if type(score)=="number" and score>1 then
            local amount=itemAmount(id)
            -- Unknown ownership is resolved by this non-consuming equip action and replicated acknowledgement.
            if amount==nil or amount>0 then table.insert(choices,{id=id,score=score}) end
        end
    end
    table.sort(choices,function(a,b) return a.score>b.score or (a.score==b.score and a.id<b.id) end)
    return choices
end
function gear.Restore(lease)
    if gear.lease~=lease then return end
    if player.Character~=lease.character then
        gear.lease=nil
        if env.AFS_GEAR_RESTORE==lease then env.AFS_GEAR_RESTORE=nil end
        return
    end
    local current=lease.character:GetAttribute("accessoryKind")
    if lease.gear and current==lease.gear and current~=lease.original then
        gear.busy=true
        env.AFS_GEAR_RESTORE=lease
        gear.status="Restoring previous gear..."
        fire("equipAccessoryDirect",lease.original or lease.gear)
        task.spawn(function()
            local deadline=os.clock()+2
            while player.Character==lease.character and lease.character:GetAttribute("accessoryKind")~=lease.original and os.clock()<deadline do task.wait(0.05) end
            if player.Character==lease.character and lease.character:GetAttribute("accessoryKind")~=lease.original then
                gear.status="Gear restore not confirmed"
                state.error=gear.status
            else gear.status="Previous gear restored" end
            gear.busy=false
            if gear.lease==lease then gear.lease=nil end
            if env.AFS_GEAR_RESTORE==lease then env.AFS_GEAR_RESTORE=nil end
        end)
    else
        gear.lease=nil gear.status="Idle"
        if env.AFS_GEAR_RESTORE==lease then env.AFS_GEAR_RESTORE=nil end
    end
end
function gear.Release()
    local lease=gear.lease
    if not lease then return end
    lease.cancelled=true
    if not gear.busy then gear.Restore(lease) end
end
function gear.Begin(stat,token)
    if gear.busy or env.AFS_GEAR_RESTORE then state.waiting="Waiting for previous gear operation" return false end
    local c=player.Character
    if not c or not valid(token) then return false end
    local previous=gear.lease
    if previous and not previous.cancelled and previous.character==c and c:GetAttribute("accessoryKind")==previous.gear then return true end
    if previous then gear.Release() if gear.busy then return false end end
    if os.clock()<gear.retryAt then return true end
    local lease={character=c,original=c:GetAttribute("accessoryKind")}
    gear.lease=lease gear.busy=true env.AFS_GEAR_RESTORE=lease
    for _,choice in ipairs(gear.Candidates(stat)) do
        if not valid(token) or lease.cancelled or player.Character~=c then break end
        lease.gear=choice.id
        if c:GetAttribute("accessoryKind")~=choice.id then
            gear.status="Equipping "..choice.id.." · x"..choice.score
            local ok=fire("equipAccessoryDirect",choice.id)
            local deadline=os.clock()+1.2
            while ok and player.Character==c and c:GetAttribute("accessoryKind")~=choice.id and os.clock()<deadline do task.wait(0.05) end
        end
        if player.Character==c and c:GetAttribute("accessoryKind")==choice.id then
            gear.busy=false
            if lease.cancelled or not valid(token) then gear.Restore(lease) return false end
            gear.status=choice.id.." · x"..choice.score.." · server confirmed"
            if env.AFS_GEAR_RESTORE==lease then env.AFS_GEAR_RESTORE=nil end
            return true
        end
    end
    gear.busy=false
    if lease.cancelled or not valid(token) then gear.Restore(lease) return false end
    gear.lease=nil gear.retryAt=os.clock()+30 gear.status="No owned training gear confirmed"
    if env.AFS_GEAR_RESTORE==lease then env.AFS_GEAR_RESTORE=nil end
    return true
end
end -- training gear lease

-- Training areas provide their own passive gains: arrival never synthesizes input.
function Adapter.trainingMotion(stat,inArea)
    if inArea then return "Idle" end
    return stat=="Agility" and "Walk" or (stat=="Speed" and "Jump" or "Active")
end
function Adapter.currentTrainingArea(root)
    for _,area in ipairs(state.zones) do
        if zoneContains(area,root) then return area end
    end
end
local function trainSegment(stat,token,questOwned)
    local c,h,r=character()
    if not c then state.waiting="Waiting for respawn" return end
    if flags.Fly then state.waiting="Disable Fly to train" return end
    if not state.trainingSnapshot or state.trainingSnapshot.character~=c then
        state.trainingSnapshot={character=c,stat=c:GetAttribute("statEquipped")}
    end
    local combined=stat=="Speed / Agility"
    if combined then stat=state.movementTrainStat or "Agility" end
    local zoneStat=stat
    if config.swordDurability and (stat=="Sword" or stat=="Durability") then
        stat="Sword" zoneStat="Durability"
    end
    local movementStat=stat=="Speed" or stat=="Agility"
    if not movementStat then Adapter.TrainingGear.Release() end
    local zone,multiplier=Adapter.best(zoneStat)
    state.action="Training "..(combined and "Speed / Agility" or stat)
    state.target=zone and zone.displayName.." · x"..multiplier or "Current position"
    if (questOwned or config.bestZone or config.swordDurability and zoneStat=="Durability") and zone and not zoneContains(zone,r) then
        state.action="Teleporting to "..stat
        h:Move(Vector3.zero,false) h.Jump=false
        local moved,reason=zoneTravel(zone,zoneStat,token)
        if not valid(token) then return end
        if not moved then state.waiting=tostring(reason) waitFor(3,token) return end
    end
    if not valid(token) or not (flags.Train or (questOwned and flags.AutoQuest)) then return end
    if state.trainStat and state.trainStat~=stat and activeStats[state.trainStat] then
        fire("equipStat",{state=false,statType=state.trainStat})
    end
    state.trainStat=stat
    if movementStat and not Adapter.TrainingGear.Begin(stat,token) then waitFor(0.2,token) return end
    if not activeStats[stat] then
        local equipped=c:GetAttribute("statEquipped")
        if activeStats[equipped] then
            fire("equipStat",{state=false,statType=equipped})
            if not waitFor(0.4,token) then return end
        end
    else
        local ok,err=true,nil
        if c:GetAttribute("statEquipped")~=stat then ok,err=fire("equipStat",{state=true,statType=stat}) end
        if not ok then state.error=tostring(err) api.Set("Train",false) return end
        if not waitFor(0.7,token) then return end
        if player.Character~=c or c:GetAttribute("statEquipped")~=stat then
            state.waiting="Server has not confirmed equip: "..stat waitFor(2,token) return
        end
    end
    local beforeStats=Adapter.stats()
    local started,lastAction=os.clock(),0
    local origin=r.Position
    local axis=r.CFrame.RightVector
    local direction=1
    local walkTarget=origin+axis*8
    -- One combined rotation slot trains both stats for half of its configured duration.
    local duration=combined and config.cycleSeconds/2 or (config.cycle and config.cycleSeconds or 3)
    state.action="Training "..(combined and "Speed / Agility · "..stat or stat)
    while valid(token) and (flags.Train or (questOwned and flags.AutoQuest)) and player.Character==c and h.Health>0 and os.clock()-started<duration do
        if questOwned and quests.current and not objectivePending(quests.current.id,quests.current.index) then break end
        local area=movementStat and Adapter.currentTrainingArea(r)
        local motion=Adapter.trainingMotion(stat,area~=nil)
        if movementStat then
            if motion=="Idle" then
                h:Move(Vector3.zero,false) h.Jump=false
                state.waiting="Passive area training · no movement or jumping"
            elseif zone and (questOwned or config.bestZone) then
                h:Move(Vector3.zero,false) h.Jump=false
                state.waiting="Outside training area; returning on next segment"
                break
            elseif motion=="Walk" then
                if (r.Position-walkTarget).Magnitude<2 then
                    direction=-direction walkTarget=origin+axis*direction*8
                end
                h:MoveTo(walkTarget)
                state.waiting="Agility · short left / right route"
            else
                h:Move(Vector3.zero,false)
                state.waiting="Speed · jumping in place"
            end
        end
        if os.clock()-lastAction>=math.max(config.interval,cooldowns[stat] or 1) then
            lastAction=os.clock()
            if movementStat then
                if motion=="Jump" and not (zone and (questOwned or config.bestZone)) then h.Jump=true end
            elseif stat~="Chakra" then
                local ok,accepted=request("trainActiveStat",token)
                if not valid(token) then return end
                if ok and accepted==true then state.confirmed+=1
                elseif ok then state.rejected+=1 else state.error=tostring(accepted) end
            end
        end
        local afterStats=Adapter.stats()
        local before,after=beforeStats[stat],afterStats[stat]
        if type(before)=="number" and type(after)=="number" and after>before then
            state.result=stat.." +"..tostring(after-before).." · replicated stat gain"
        end
        task.wait(0.1)
    end
    if valid(token) and player.Character==c then
        h:Move(Vector3.zero,false) h.Jump=false
        if combined then state.movementTrainStat=stat=="Agility" and "Speed" or "Agility" end
    end
end
-- Exactly one training scheduler exists; off/on invalidates its current segment.
task.spawn(function()
    local index,lastCycleStat=0,nil
    while state.alive do
        if state.ready and (flags.Train) and not flags.AutoQuest and not flags.QuestScan and not state.fruitBusy then
            local stat
            stat,index=nextStat(index)
            if not config.cycle and lastCycleStat~=stat then index=0 end
            lastCycleStat=stat
            local token=state.generation
            local ok,err=xpcall(function()
                trainSegment(stat,token)
                if stat=="Speed / Agility" and config.cycle and valid(token) then trainSegment(stat,token) end
            end,debug.traceback)
            if not ok and valid(token) then state.error=tostring(err) api.Set("Train",false) end
        end
        task.wait(0.2)
    end
end)
local function questNPC(quest)
    for _,npc in ipairs(CS:GetTagged("isQuest")) do
        if npc:IsDescendantOf(workspace) and npc:GetAttribute("Dialogue")=="RepeatableQuests"
            and npc:GetAttribute("QuestKey")==quest.area then return npc end
    end
end
function Adapter.foundingProbePoints()
    local event=path(workspace,"Map.RumblingEvent")
    if not event or event:GetAttribute("Active")~=true then return {} end
    local start,finish=event:FindFirstChild("Start"),event:FindFirstChild("End")
    if not start or not finish or not start:IsA("BasePart") or not finish:IsA("BasePart") then return {} end
    local points={}
    local steps=math.clamp(math.ceil((finish.Position-start.Position).Magnitude/600),1,32)
    for i=0,steps do
        local point=start.Position:Lerp(finish.Position,i/steps)+Vector3.new(0,defense.FoundingHeight(),0)
        if defense.Safety.Air(point) then table.insert(points,CFrame.new(point)) end
    end
    return points
end
local function spawnPoint(name)
    if name=="FoundingTitan" then return Adapter.foundingProbePoints()[1] end
    local _,_,root=character()
    local best,distance
    for _,spawner in ipairs(CS:GetTagged("isSpawner")) do
        if spawner:IsDescendantOf(workspace) and spawner:GetAttribute("entityName")==name then
            local cf=objectFrame(spawner)
            if cf then
                local d=root and (root.Position-cf.Position).Magnitude or 0
                if not distance or d<distance then best,distance=cf,d end
            end
        end
    end
    if not best and mobs.catalog[name] and mobs.catalog[name].isBoss then
        local zones=CS:GetTagged("isBossZone")
        local d=descriptions and descriptions.descriptions and descriptions.descriptions[name]
        local declared=d and type(d.zonePath)=="string" and path(workspace,d.zonePath)
        if declared and not table.find(zones,declared) then table.insert(zones,1,declared) end
        for _,zone in ipairs(zones) do
            local arena=zone.Parent
            if zone==declared or zone.Name==name or (arena and arena:GetAttribute("bossType")==name) then
                for _,offset in ipairs({0,-60,-120,-180,-240,-320,-480,-640}) do
                    local point=defense.Safety.Validate(zone.Position+Vector3.new(0,offset,0),zone,true)
                    if point then
                        return CFrame.new(point)
                    end
                end
            end
        end
    end
    return best
end
function Adapter.bossProbeApproach(d,cf)
    if d.id~="WildPsychic" and d.id~="HandDemon" then return cf end
    local desc=descriptions and descriptions.descriptions and descriptions.descriptions[d.id]
    local zone=desc and type(desc.zonePath)=="string" and path(workspace,desc.zonePath)
    if not zone then return end
    local _,_,root=character()
    local direction=root and root.Position-cf.Position or Vector3.new(0,0,1)
    direction=Vector3.new(direction.X,0,direction.Z)
    direction=direction.Magnitude>0.01 and direction.Unit or Vector3.new(0,0,1)
    -- Discovery must not land inside a grab/tornado before a target is acquired.
    for _,radius in ipairs({100,140,75}) do
        for i=0,15 do
            local offset=CFrame.Angles(0,i*math.pi/8,0):VectorToWorldSpace(direction)*radius
            local point=defense.Safety.Validate(cf.Position+offset,zone,true)
            if point then return CFrame.lookAt(point,cf.Position) end
        end
    end
end
-- Entity replication is distance-limited even with Workspace.StreamingEnabled=false.
-- Visit verified spawn/zone points so an unseen selected boss cannot be forgotten.
function Adapter.nextBossProbe(current)
    local run=mobs.bossRun
    if not run then return end
    run.probes=run.probes or {}
    local rows={}
    for id in pairs(run.selected) do
        local d=mobs.catalog[id]
        if d and Adapter.bossInCurrentDimension(id) and (not run.served[id] or flags.AutoQuest) and not bossArena(id) and not dungeonBosses[id]
            and not nearestMob(id) and os.clock()>=(run.probes[id] or 0)
            and (not current or Adapter.bossPriority(d,current)) then table.insert(rows,d) end
    end
    -- Oldest unchecked spawn first. A global 20s timer plus priority sorting
    -- repeatedly selected the same boss and starved every lower-priority spawn.
    table.sort(rows,function(a,b)
        local at,bt=run.probes[a.id] or 0,run.probes[b.id] or 0
        if at~=bt then return at<bt end
        return Adapter.bossPriority(a,b)
    end)
    for _,d in ipairs(rows) do
        local cf=spawnPoint(d.id)
        cf=cf and Adapter.bossProbeApproach(d,cf)
        if cf then return d,cf end
    end
end
function Adapter.probeBoss(token,current)
    if not valid(token) then return false end
    local d,cf=Adapter.nextBossProbe(current)
    if d then
        local run=mobs.bossRun
        local probe={token=token,id=d.id}
        run.probing=probe
        run.probes[d.id]=os.clock()+20
        local ok,value=xpcall(function()
            state.action="Finding selected boss" state.target=d.name
            state.waiting="Checking existing spawn"
            local _,_,root=character()
            local origin=root and root.CFrame
            local points=d.id=="FoundingTitan" and Adapter.foundingProbePoints() or {cf}
            for _,point in ipairs(points) do
                if not valid(token) then return true end
                if d.id=="FoundingTitan" and #Adapter.foundingProbePoints()==0 then break end
                local moved,reason=travel(point*CFrame.new(0,3,0),token,true)
                if not valid(token) then return true end
                if not moved then state.waiting=d.name..": "..tostring(reason) continue end
                if d.id=="FoundingTitan" then defense.waitPoint=point defense.hover=true end
                if not waitFor(0.6,token) then return true end
                scanMobs()
                if nearestMob(d.id) then break end
            end
            if not nearestMob(d.id) and origin and valid(token) then
                -- Probing a dormant sea boss is temporary; never camp on its water plane.
                local returned,why=travel(origin,token,true)
                state.waiting=d.name..": no live boss found"..(returned and "" or " · "..tostring(why))
            end
            run.lastProbe={id=d.id,found=nearestMob(d.id)~=nil,time=os.clock()}
            return true
        end,debug.traceback)
        if run.probing==probe then run.probing=nil end
        if not ok then error(value,0) end
        return value
    end
    return false
end
local function prepareMobQuest(definition,token)
    local quest=definition.quest
    if not quest then
        state.waiting="This mob has no repeatable quest."
        return true
    end
    if mobs.acceptedQuest==quest.id and not mobs.completed[quest.id] then return true end
    state.action="Repeatable quest" state.target=quest.npc.." · "..quest.id
    local npc=questNPC(quest)
    if not npc then
        local cf=spawnPoint(definition.id)
        if not cf then return false,"NPC and mob area are not loaded" end
        local moved,reason=travel(cf*CFrame.new(0,3,0),token,true)
        if not moved then return false,reason end
        if not waitFor(2,token) then return false,"Cancelled" end
        npc=questNPC(quest)
    end
    local cf=npc and objectFrame(npc)
    if not cf then return false,"Waiting for NPC: "..quest.npc end
    local moved,reason=travel(cf*CFrame.new(0,0,5),token,true)
    if not moved then return false,reason end
    if not waitFor(0.4,token) then return false,"Cancelled" end
    -- Also handles a quest completed before this script was loaded, without canceling other quests.
    local ok,redeemed,message=request("redeemQuest",token,quest.id)
    if not valid(token) then return false,"Cancelled" end
    if not ok then return false,tostring(redeemed) end
    if redeemed==true then
        mobs.quests+=1 mobs.completed[quest.id]=nil mobs.acceptedQuest=nil
        state.result="Reward confirmed: "..quest.id
        table.insert(mobs.history,{event="redeem",quest=quest.id,time=os.clock()})
    elseif message=="You already redeemed this quest." then
        mobs.completed[quest.id]=nil mobs.acceptedQuest=nil
    elseif mobs.completed[quest.id] then return false,tostring(message or "Reward confirmation pending") end
    local started,accepted,why=request("startQuest",token,quest.id)
    if not valid(token) then return false,"Cancelled" end
    if started and (accepted==true or why=="This quest is already active.") then
        mobs.acceptedQuest=quest.id
        table.insert(mobs.history,{event=accepted==true and "questStart" or "questActive",quest=quest.id,time=os.clock()})
        state.result=accepted==true and "Server accepted: "..quest.id or "Continuing active quest: "..quest.id
        return true
    end
    return false,tostring(why or accepted)
end
function Adapter.farmAllows(definition,questMob)
    if questMob then return flags.AutoQuest and definition~=nil end
    if flags.BossFarm then
        return definition~=nil and definition.isBoss==true and mobs.bossRun~=nil
            and mobs.bossRun.selected[definition.id]==true
    end
    return flags.MobFarm and definition~=nil and not definition.isBoss
end
local function farmMobSegment(token,questMob,questContinue)
    local event=not questMob and not mobs.bossRun and bloodMoonOverride()
    local definition
    if not questMob and mobs.bossRun then
        scanMobs() definition=Adapter.nextBoss()
        if Adapter.probeBoss(token,definition) then return end
        if not definition then
            state.action="Waiting for bosses" state.target="Selected Bosses"
            state.waiting="Waiting for spawn / JOIN; summons and keys are disabled"
            waitFor(1,token) return
        end
    else definition=mobs.catalog[questMob or (event and "Skeleton" or config.mob)] end
    if definition and not Adapter.farmAllows(definition,questMob) then
        state.waiting="Select a target for this farm" waitFor(1,token) return
    end
    if not definition then state.waiting="Select a mob from the list" waitFor(2,token) return end
    local bossReady,bossReason=prepareBoss(definition,token)
    if not valid(token) then return end
    if not bossReady then
        state.action="Auto join boss" state.target=definition.name state.waiting=tostring(bossReason)
        waitFor(2,token) return
    end
    local ready,reason=true,nil
    if not event and not definition.isBoss and not (questMob and flags.TargetMainQuest) then ready,reason=prepareMobQuest(definition,token) end
    if not valid(token) then return end
    if not ready then state.waiting=tostring(reason) waitFor(3,token) return end
    scanMobs()
    if event and not mobs.eventBatch then
        mobs.eventBatch={}
        for id,mob in pairs(mobs.entities) do
            if skeletonTypes[mob.name] and not mobs.dead[id] and mob.hp>0 then mobs.eventBatch[id]=true end
        end
    end
    if event then
        for id,mob in pairs(mobs.entities) do
            if skeletonTypes[mob.name] and not mobs.dead[id] and mob.hp>0  then
                mobs.eventBatch[id]=true -- newly spawned buffed variants take priority after the locked kill
            end
        end
    end
    local target=nearestMob(definition.id,event and mobs.eventBatch or nil)
    if not target and not flags.BossFarm and (flags.AutoJoinBoss or flags.AutoQuest) and dungeonBosses[definition.id] and workspace:GetAttribute("Place")=="Dungeon" then
        target=nearestMob(nil) -- Clear the current dungeon wave before its selected final boss can spawn.
    end
    if not target then
        local cf
        if event then
            -- Finish the current area's snapshot, then advance; fresh respawns cannot keep us camping.
            if not mobs.eventRoute then
                mobs.eventRoute={}
                for _,object in ipairs(CS:GetTagged("isSpawner")) do
                    local d=mobs.catalog[object:GetAttribute("entityName")]
                    local point=object:IsDescendantOf(workspace) and objectFrame(object)
                    if point and d and not d.isBoss then
                        local covered=false
                        for _,entry in ipairs(mobs.eventRoute) do
                            local other=objectFrame(entry)
                            if other and (point.Position-other.Position).Magnitude<300 then covered=true break end
                        end
                        if not covered then table.insert(mobs.eventRoute,object) end
                    end
                end
                local _,_,root=character()
                table.sort(mobs.eventRoute,function(a,b)
                    local ap,bp=objectFrame(a).Position,objectFrame(b).Position
                    local ad,bd=root and (ap-root.Position).Magnitude or 0,root and (bp-root.Position).Magnitude or 0
                    return ad<bd or (ad==bd and a:GetFullName()<b:GetFullName())
                end)
            end
            if #mobs.eventRoute>0 then
                mobs.eventRouteIndex=mobs.eventRouteIndex%#mobs.eventRoute+1
                local point=mobs.eventRoute[mobs.eventRouteIndex]
                cf=point.Parent and objectFrame(point)
            end
            mobs.eventBatch=nil
        else cf=spawnPoint(definition.id) end
        if cf then travel(cf*CFrame.new(0,3,0),token,true) end
        if not valid(token) then return end
        state.action="Waiting for mobs" state.target=definition.name
        state.waiting=event and "Blood Moon: scanning areas for Skeletons, strongest first."
            or "Waiting for selected target to spawn."
        waitFor(2,token) return
    end
    local targetDefinition=mobs.catalog[target.name] or definition
    local c,h=character()
    if not c then state.waiting="Waiting for respawn" waitFor(1,token) return end
    if not state.trainingSnapshot or state.trainingSnapshot.character~=c then
        state.trainingSnapshot={character=c,stat=c:GetAttribute("statEquipped")}
    end
    local weapon=config.weapon
    if targetDefinition.isBoss then
        if config.bossWeapon=="Strongest Stat" then
            local stats=Adapter.stats()
            weapon=(stats.Strength or 0)>(stats.Sword or 0) and "Strength" or "Sword"
        else weapon=config.bossWeapon=="Strength" and "Strength" or "Sword" end
    end
    state.trainStat=weapon
    -- Acquire before equip confirmation so defense is already active on arrival.
    if not mobs.IsLive(target) then return end
    mobs.target=target mobs.targetToken=token combat.weapon=weapon
    local equipDeadline=os.clock()+2.5
    repeat
        if combat.EnsureWeapon(c,weapon,token) then break end
        if not waitFor(0.05,token) or not mobs.IsLive(target) or player.Character~=c then return end
    until os.clock()>=equipDeadline
    if c:GetAttribute("statEquipped")~=weapon then
        state.waiting="Server has not confirmed equip: "..weapon waitFor(2,token) return
    end
    if not mobs.IsLive(target) then return end
    table.insert(mobs.history,{event="target",id=target.id,name=target.name,time=os.clock()})
    if #mobs.history>60 then table.remove(mobs.history,1) end
    local lastAttack,lastFollow,lastProgress,lastHP=0,0,os.clock(),target.hp
    while valid(token) and (flags.MobFarm or flags.BossFarm or (questMob and flags.AutoQuest)) and player.Character==c and h.Health>0 do
        if event then
            local strongest=nearestMob(nil,{})
            if strongest and skeletonPriority(strongest)>skeletonPriority(target) then mobs.ReleaseTarget(target) return end
        end
        if target.dead or mobs.dead[target.id] or target.hp<=0 then
            if mobs.entities[target.id]==target then mobs.MarkDead(target.id) end
            mobs.ReleaseTarget(target)
            waitFor(0.2,token) return
        end
        if not mobs.IsLive(target) then
            mobs.ReleaseTarget(target) state.waiting="Target disappeared without confirmed death; scanning again" return
        end
        if not mobs.ResolveModel(target) then
            mobs.SuspendCombat()
            state.waiting="Target unloaded; attacks paused until identity is confirmed"
            if not waitFor(0.1,token) then return end
            continue
        end
        if questContinue and not questContinue() then mobs.ReleaseTarget(target) return end
        combat.EnsureWeapon(c,weapon,token)
        state.action=(event and "Blood Moon · " or "Combat · ")..weapon state.target=targetDefinition.name.." #"..target.id
        state.waiting="HP: "..hpText(target.hp).."/"..hpText(target.maxHP).." · waiting for confirmed death"
        if target.hp<lastHP then lastProgress=os.clock() end
        lastHP=target.hp
        if os.clock()-lastProgress>config.mobStall then
            -- Re-enter the attack/equip cycle on the same living identity; phase immunity
            -- or a rejected equip must not permanently disable a boss farm.
            releaseCast() table.clear(combat.aims) table.clear(combat.pending)
            if combat.plans then table.clear(combat.plans) end
            combat.nextEquip=0
            mobs.recoveries=(mobs.recoveries or 0)+1
            lastProgress=os.clock()
            fire("equipStat",{state=true,statType=weapon})
            state.result="Restarting attacks on living target #"..target.id.."; HP has not decreased"
        end
        if mobs.entities[target.id] and os.clock()-lastFollow>=0.2 then
            local position=mobPosition(target)
            if position then
                lastFollow=os.clock()
                local _,_,root=character()
                local cf=mobFacingFrame(target,root)
                if cf then travel(cf,token,true) end
            end
        end
        if not valid(token) then return end
        if not mobs.IsLive(target) then continue end
        combatStep(target,token)
        if not valid(token) then return end
        if not mobs.IsLive(target) then continue end
        if mobs.CanAttack(target) and (not targetDefinition.isBoss or config.castBasic) and mobs.entities[target.id] and not mobs.dead[target.id] and os.clock()-lastAttack>=math.max(1.1,cooldowns[weapon] or 1) then
            local position=mobPosition(target)
            local _,_,root=character()
            if root and position and (targetDefinition.isBoss or (root.Position-position).Magnitude<7) then
                lastAttack=os.clock()
                if c:GetAttribute("statEquipped")~=weapon then fire("equipStat",{state=true,statType=weapon})
                else
                    local ok,accepted=request("trainActiveStat",token)
                    if not valid(token) then return end
                    if ok and accepted==true then state.confirmed+=1 elseif ok then state.rejected+=1
                    else state.error=tostring(accepted) end
                end
            end
        end
        if not waitFor(0.05,token) then return end
    end
end
local function farmMob(token,questMob,questContinue)
    local ok,err=xpcall(function() farmMobSegment(token,questMob,questContinue) end,debug.traceback)
    if mobs.targetToken==token then mobs.ReleaseTarget(mobs.target) end
    if not ok then error(err,0) end
end
-- The quest worker owns both modes when combined. This watcher only cancels the
-- current generation, so no second coroutine can move/train/fight over a quest.
function Adapter.updateBossPriority()
    local priority=false
    if state.ready and flags.AutoQuest and flags.BossFarm and not state.fruitBusy then
        scanMobs()
        local run=mobs.bossRun
        priority=Adapter.nextBoss()~=nil or (run and run.probing and valid(run.probing.token)) or Adapter.nextBossProbe()~=nil
        priority=priority and true or false
    else
        state.bossProbe=nil
    end
    if priority==(state.bossPriority==true) then return end
    state.bossPriority=priority
    state.generation+=1
    api.CancelMove() releaseTraining()
    mobs.ReleaseTarget(mobs.target) mobs.SuspendCombat()
    quests.requiredSpecial=nil
    state.waiting=priority and "Selected boss available; pausing quests" or "Resuming quests"
end
task.spawn(function()
    while state.alive do
        Adapter.updateBossPriority()
        task.wait(0.2)
    end
end)
-- One persistent worker; target identity stays locked until server death or explicit cancellation.
task.spawn(function()
    while state.alive do
        if state.ready and (flags.AutoDungeon or flags.MobFarm or flags.BossFarm) and not flags.AutoQuest and not flags.QuestScan and not state.fruitBusy then
            local token=state.generation
            local ok,err=xpcall(function()
                if flags.AutoDungeon then dungeon.Step(token) else farmMob(token) end
            end,debug.traceback)
            if not ok and valid(token) then
                state.error=tostring(err) state.waiting="Recovering farm after error"
                waitFor(1,token)
            end
        end
        task.wait(0.2)
    end
end)
function api.SelectMob(id)
    local definition=mobs.catalog[id]
    if not definition then return false end
    if definition.isBoss then
        if flags.BossFarm then return false end
        config.bosses[id]=true
        if mobs.bossChecklist then mobs.bossChecklist:SetSelected(Adapter.bossSelectedLabels()) end
        return true
    end
    config.mob=id
    if flags.MobFarm then api.Set("MobFarm",true) end
    return true
end
local nextQuest=module("Utilities.Wrappers.getNextQuestInChain")
local recipes=module("Configs.SpecialCraftingRecipes") or {}
local entityDrops=module("Configs.EntityDrops")
local function questGiver(id)
    local kind,key=id:match("^([^.]+)%.([^.]+)")
    for _,npc in ipairs(CS:GetTagged("isQuest")) do
        if npc:IsDescendantOf(workspace) then
            local dialogue=npc:GetAttribute("Dialogue")
            if (kind=="Repeatable" and dialogue=="RepeatableQuests" and npc:GetAttribute("QuestKey")==key)
                or (kind~="Repeatable" and (dialogue==key or npc:GetAttribute("QuestKey")==key)) then return npc end
        end
    end
end
local function visitQuestGiver(id,token)
    local npc=questGiver(id)
    if not npc then return false,"Quest NPC is not loaded: "..id end
    local cf=objectFrame(npc)
    if not cf then return false,"Quest NPC has no interaction point" end
    local _,_,r=character()
    if not r then return false,"Waiting for respawn" end
    if (r.Position-cf.Position).Magnitude>12 then
        local ok,reason=travel(cf*CFrame.new(0,0,5),token,true)
        if not ok then return false,reason end
    end
    return waitFor(0.3,token)
end
local function acceptQuest(id,token)
    if not questAllowed(id) then return false,"Main Quests Only" end
    local moved,reason=visitQuestGiver(id,token)
    if not moved then return false,reason end
    local ok,accepted,message=request("startQuest",token,id)
    if not valid(token) then return false,"Cancelled" end
    if ok and (accepted==true or message=="This quest is already active.") then
        quests.known[id]=quests.known[id] or {Objectives={}}
        quests.blocked[id]=nil
        return true,accepted==true and "Accepted" or "Active"
    end
    if ok and message=="You already completed this quest." then
        local good,redeemed,why=request("redeemQuest",token,id)
        if not valid(token) then return false,"Cancelled" end
        if good and (redeemed==true or why=="You already redeemed this quest.") then
            quests.known[id]={Completed=true,Redeemed=true,Objectives={}}
            if redeemed==true then quests.claimed+=1 end
            return false,"Claimed"
        end
        quests.known[id]=quests.known[id] or {Objectives={}}
        quests.known[id].Completed=true
        return false,tostring(why or redeemed)
    end
    if ok and message=="You already completed this quest. Rewards redeemed." then
        quests.known[id]={Completed=true,Redeemed=true,Objectives={}}
        return false,"Claimed"
    end
    return false,tostring(message or accepted)
end
local function questScan(token)
    local queue={}
    local seen={}
    for _,npc in ipairs(CS:GetTagged("isQuest")) do
        if npc:IsDescendantOf(workspace) and npc:GetAttribute("Dialogue")~="RepeatableQuests" then
            local key=npc:GetAttribute("QuestKey") or npc:GetAttribute("Dialogue")
            if type(key)=="string" and not seen[key] then
                local ids={}
                for id in pairs(quests.catalog) do
                    if questAllowed(id) and (id:match("^Side%.([^.]+)")==key or id:match("^Main%.([^.]+)")==key) then table.insert(ids,id) end
                end
                if #ids>0 then
                    table.sort(ids,function(a,b)
                        local x=a:gsub("%d+",function(n) return string.format("%08d",tonumber(n)) end)
                        local y=b:gsub("%d+",function(n) return string.format("%08d",tonumber(n)) end)
                        return x<y
                    end)
                    table.insert(queue,{key=key,ids=ids,npc=npc}) seen[key]=true
                end
            end
        end
    end
    table.sort(queue,function(a,b) return a.key<b.key end)
    quests.scanResult={} quests.scanQueue=queue quests.scanIndex=0
    for i,entry in ipairs(queue) do
        if not valid(token) or not flags.QuestScan then return end
        quests.scanIndex=i
        state.action="Collecting quests" state.target=entry.key.." · "..i.."/"..#queue
        local result="No available quest"
        for _,id in ipairs(entry.ids) do
            if not valid(token) or not flags.QuestScan then return end
            local q=quests.known[id]
            if not q or not q.Redeemed then
                local accepted,why=acceptQuest(id,token)
                result=why
                if accepted or why~="Claimed" then break end
            end
            if not waitFor(0.15,token) then return end
        end
        quests.scanResult[entry.key]=result
    end
    if valid(token) then
        flags.QuestScan=false
        state.action="Ready" state.target="—"
        state.result="Scan complete: "..#queue.." quest NPCs"
        state.waiting="—"
        if quests.resumeAfterScan then quests.resumeAfterScan=nil api.Set("AutoQuest",true) end
    end
end
function api.CollectQuests()
    if not state.ready or flags.QuestScan then return end
    local resume=flags.AutoQuest
    api.Set("QuestScan",true)
    quests.resumeAfterScan=resume
end
local function requiredSpecial(id,token)
    if not id then return true end
    local c=player.Character
    if c and c:GetAttribute("specialEquipped")==id then return true end
    for _,slot in ipairs(specialSlots()) do if slot.id==id then
        fire("equipSpecial",slot.index)
        if not waitFor(0.6,token) then return false end
        return player.Character==c and c:GetAttribute("specialEquipped")==id
    end end
    return false
end
local function objectiveMob(o)
    if o.MobName and mobs.catalog[o.MobName] then return o.MobName end
    local selected=mobs.catalog[config.mob]
    if selected and selected.isBoss and not dungeonBosses[selected.id] then return selected.id end
    local choice
    for id,d in pairs(mobs.catalog) do
        if d.isBoss and not dungeonBosses[id] and bossArena(id) and not bossKeys[id] then
            if not choice or (d.maxHP or math.huge)<(mobs.catalog[choice].maxHP or math.huge) then choice=id end
        end
    end
    return choice
end
local function dropMob(item)
    local best
    local function includes(t)
        if type(t)~="table" then return false end
        if t.ItemName==item then return true end
        for _,v in pairs(t) do if type(v)=="table" and includes(v) then return true end end
        return false
    end
    for _,id in ipairs(combatMetadata.itemSources[item] or {}) do
        if mobs.catalog[id] and (not best or (mobs.catalog[id].maxHP or math.huge)<(mobs.catalog[best].maxHP or math.huge)) then best=id end
    end
    for id,pools in pairs(entityDrops or {}) do
        if mobs.catalog[id] and includes(pools) and (not best or (mobs.catalog[id].maxHP or math.huge)<(mobs.catalog[best].maxHP or math.huge)) then best=id end
    end
    return best
end
local function fightQuest(id,index,mob,token)
    if not mob then return false,"Waiting for a target for this quest" end
    farmMob(token,mob,function()
        local queue=questQueue()
        local head=queue[1]
        if head and head.order<20000 and quests.current and quests.current.pinHead and head.id~=quests.current.pinHead then return false end
        return objectivePending(id,index) and flags.AutoQuest
    end)
    return true
end
local function currencyAmount(name)
    local value=dataAt("Currency."..name)
    if type(value)=="number" then return value end
    local label=path(player.PlayerGui,"Main.HUD.PlayerInfo.Info."..name..".Amount")
    if label then return parseDisplay(label.Text:gsub("[^%d%a%.,]","")) end
end
local function questThrottle(key,seconds)
    if os.clock()<(quests.nextAction[key] or 0) then return false end
    quests.nextAction[key]=os.clock()+seconds
    return true
end
local function farmItem(id,index,item,amount,token)
    local current=itemAmount(item)
    if current and current>=amount then return false,"Waiting for item progress: "..item end
    local mob=dropMob(item)
    if not mob then return false,"Item source unavailable: "..item end
    farmMob(token,mob,function()
        local value=itemAmount(item)
        return flags.AutoQuest and objectivePending(id,index) and (not value or value<amount)
    end)
    return true
end
local function summonForQuest(id,index,token)
    local remaining=quests.catalog[id].Objectives[index].Amount or 1
    local q=quests.known[id]
    local progress=q and q.Objectives and q.Objectives[index]
    remaining=math.max(1,remaining-(progress and progress.Progress or 0))
    local amount=remaining>=10 and 10 or 1
    local balance=currencyAmount("Chikara")
    if not balance or balance<100 then return false,"At least 100 Chikara required to summon" end
    if balance<amount*100 then amount=1 end
    if not questThrottle("summon",8) then return false,"Waiting for previous summon confirmation" end
    local capsule
    for _,v in ipairs(CS:GetTagged("championCapsule")) do if v:IsDescendantOf(workspace) then capsule=v break end end
    local cf=capsule and objectFrame(capsule)
    if not cf then return false,"Champion capsule is not loaded" end
    local moved,why=travel(cf*CFrame.new(0,0,5),token,true)
    if not moved or not valid(token) then return false,why end
    local ok,result=request("openBanner",token,"StandardBanner",amount)
    if not valid(token) then return false,"Cancelled" end
    if ok and type(result)=="table" and #result>0 then
        state.result="Champion summon confirmed: "..#result
        return true
    end
    return false,"Summon unconfirmed; checking capacity and currency"
end
local function rollForQuest(o,token)
    local kind=o.Kind or "Bloodline"
    local data=dataAt("Specials."..kind)
    if not data or type(data.SpecialSlots)~="table" then return false,"Special slots unavailable: "..kind end
    local empty
    for index,slot in pairs(data.SpecialSlots) do
        if type(slot)=="table" and (slot.special==nil or slot.special=="" or slot.special=="None") then empty=tonumber(index) break end
    end
    if not empty then return false,"Special roll needs an empty slot: "..kind end
    if not questThrottle("specialRoll",8) then return false,"Waiting for previous roll" end
    fire("selectSpecialSlot",{kind=kind,slotIndex=empty})
    if not waitFor(0.6,token) then return false,"Cancelled" end
    local spins=dataAt("SpecialSpins")
    if type(spins)=="number" and spins>0 then
        fire("requestSpecialSpin",{kind=kind,slotIndex=empty,isLucky=false})
    else
        local options={Bloodline={currency="Chikara",cost=150},Grimoire={currency="CloverToken",cost=150},
            BreathingTechnique={currency="TenseiShards",cost=150},Superpower={currency="TenseiShards",cost=150}}
        local price=options[kind] or {currency="Chikara",cost=150}
        local balance=currencyAmount(price.currency) or itemAmount(price.currency)
        if not balance or balance<price.cost then return false,"Insufficient currency to roll "..kind end
        fire("purchaseAndSpinRegular",{kind=kind,currency=price.currency})
    end
    return true
end
local function equipSpecialKind(kind,token)
    local folder=path(RS,"Dictionaries.Specials.Descriptions")
    local singular={Grimoires="Grimoire",Fruits="Fruit",Stands="Stand",CursedTechniques="CursedTechnique"}
    for _,slot in ipairs(specialSlots()) do
        local definition=folder and folder:FindFirstChild(slot.id,true)
        local k=definition and definition.Parent.Name
        if k==kind or (k and singular[k]==kind) or singular[kind]==k then return requiredSpecial(slot.id,token) end
    end
    return false
end
local function pvpQuest(id,index,o,token,tournament)
    if tournament and player:GetAttribute("tournamentJoined")~=true and workspace:GetAttribute("Place")~="Tournament" then
        if workspace:GetAttribute("tournamentPhase")=="Joining" and questThrottle("tournament",10) then fire("attemptJoinTournament") end
        return false,"Waiting for tournament"
    end
    if tournament then
        local phase=workspace:GetAttribute("tournamentPhase")
        if phase and phase~="Battle" then return false,"Tournament: "..tostring(phase) end
    end
    if o.SpecialType and not equipSpecialKind(o.SpecialType,token) then return false,"Missing Special: "..o.SpecialType end
    local c,h,r=character()
    if not c then return false,"Waiting for respawn" end
    local target,best
    for _,p in ipairs(Players:GetPlayers()) do
        local char=p.Character
        local hum=char and char:FindFirstChildOfClass("Humanoid")
        local root=char and char:FindFirstChild("HumanoidRootPart")
        if p~=player and hum and root and hum.Health>0 and not char:FindFirstChildOfClass("ForceField")
            and char:GetAttribute("isInvulnerable")~=true and (not tournament or p:GetAttribute("tournamentJoined")==true or workspace:GetAttribute("Place")=="Tournament")
            and (not tournament or not player.Team or not p.Team or player.Team~=p.Team) then
            local distance=(root.Position-r.Position).Magnitude
            if not best or distance<best then target={id="Player_"..p.UserId,name=p.Name,model=char,player=p,hp=hum.Health,maxHP=hum.MaxHealth} best=distance end
        end
    end
    if not target then return false,"Waiting for an available PvP opponent" end
    local enemyHum=target.model:FindFirstChildOfClass("Humanoid")
    local deadline=os.clock()+6
    local stats=Adapter.stats()
    local weapon=(stats.Sword or 0)>=(stats.Strength or 0) and "Sword" or "Strength"
    if not state.trainingSnapshot or state.trainingSnapshot.character~=c then
        state.trainingSnapshot={character=c,stat=c:GetAttribute("statEquipped")}
    end
    state.trainStat=weapon fire("equipStat",{state=true,statType=weapon})
    if not waitFor(0.5,token) then return false,"Cancelled" end
    mobs.target=target
    local lastAttack=0
    while valid(token) and flags.AutoQuest and player.Character==c and h.Health>0 and target.model.Parent
        and enemyHum.Health>0 and os.clock()<deadline and objectivePending(id,index) do
        target.hp=enemyHum.Health
        local cf=mobFacingFrame(target,r)
        if cf then travel(cf,token,true) end
        if not valid(token) then break end
        combatStep(target,token)
        if valid(token) and os.clock()-lastAttack>=math.max(1.1,cooldowns[weapon] or 1) then
            lastAttack=os.clock() request("trainActiveStat",token)
        end
        if not waitFor(0.2,token) then break end
    end
    mobs.target=nil releaseCast()
    if valid(token) then refreshQuestState() end
    return true
end

local function runQuestObjective(id,index,o,token)
    local t=o.Type
    local q=quests.known[id]
    local guard=function() return objectivePending(id,index) and flags.AutoQuest end
    if t=="Training" or t=="TrainCount" then
        local stat=o.Stat=="Any" and config.stat or o.Stat
        if not table.find(statNames,stat) then return false,"Unknown stat: "..tostring(stat) end
        trainSegment(stat,token,true)
        return true
    elseif t=="DefeatMob" then
        return fightQuest(id,index,o.MobName,token)
    elseif t=="BossDefeat" or t=="BossDamage" or t=="SpecialMastery" then
        local special=o.SpecialId or (o.RequiredSpecial and o.RequiredSpecial.Id)
        quests.requiredSpecial=special
        if special and not requiredSpecial(special,token) then return false,"Equip in hotbar: "..special end
        if o.SpecialType then
            if not equipSpecialKind(o.SpecialType,token) then return false,"No owned Special of type "..o.SpecialType end
            quests.requiredSpecial=player.Character and player.Character:GetAttribute("specialEquipped")
        end
        return fightQuest(id,index,objectiveMob(o),token)
    elseif t=="ClearDungeon" or t=="DungeonComplete" then
        local mob=o.DungeonName=="Limbo" and "VastoLorde" or "KingAnt"
        if o.Difficulty then config.dungeonDifficulty=o.Difficulty end
        return fightQuest(id,index,mob,token)
    elseif t=="TowerFloor" then
        local place=workspace:GetAttribute("Place")
        if place=="Tower" or place=="Castle" then
            local tower=quests.towerState
            if tower.choices and tower.votes then
                local signature=table.concat(tower.choices,",")
                if quests.lastVote~=signature and tower.choices[1] then
                    quests.lastVote=signature fire("voteModifier",tower.choices[1])
                end
                return false,"Tower: waiting for voting to close"
            end
            if tower.phase=="Waiting" and os.clock()>=(quests.nextAction.towerReady or 0) then
                quests.nextAction.towerReady=os.clock()+5 fire("contentReadyUp")
            end
            scanMobs()
            local mob=nearestMob(nil)
            if mob then farmMob(token,mob.name,guard) else state.waiting="Waiting for next tower floor" waitFor(1,token) end
            return true
        end
        if not queueFunction() then return false,"queue_on_teleport is required to continue the tower" end
        if localDungeonQueue() then return false,"Queued; waiting for teleport" end
        if not quests.pending.tower then
            quests.pending.tower={id=id,name=o.TowerName or "Tower",sent=os.clock()}
            fire("attemptQueueTower",o.TowerName or "Tower")
        end
        return false,"Waiting for queue and teleport to "..(o.TowerName or "Tower")
    elseif t=="RetrieveItem" or t=="RequiredItem" then
        return farmItem(id,index,o.ItemName,o.Amount or 1,token)
    elseif t=="CraftSpecial" then
        local recipe=recipes[o.SpecialId]
        if not recipe then return false,"Recipe unavailable: "..tostring(o.SpecialId) end
        for item,amount in pairs(recipe.recipe or {}) do
            local owned=itemAmount(item)
            if owned==nil then return false,"Inventory has not confirmed material: "..item end
            if owned<amount then
                local mob=dropMob(item)
                if mob then return farmItem(id,index,item,amount,token) end
                return false,"Missing "..item.." · "..owned.."/"..amount
            end
        end
        if quests.pending[id] then return false,"Craft sent; waiting for server confirmation" end
        local npc
        for _,v in ipairs(CS:GetTagged("isQuest")) do
            if v:IsDescendantOf(workspace) and v:GetAttribute("Dialogue")=="SpecialCrafting" and v:GetAttribute("QuestKey")==o.SpecialId then npc=v break end
        end
        local cf=npc and objectFrame(npc)
        if not cf then return false,"Crafting NPC is not loaded" end
        local moved,why=travel(cf*CFrame.new(0,0,5),token,true)
        if not moved or not valid(token) then return false,why end
        quests.pending[id]=true fire("attemptCraftSpecial",o.SpecialId)
        return true
    elseif t=="Playtime" then
        return false,"Playtime progresses automatically"
    elseif t=="PlayWithFriend" then
        local friend=false
        for _,p in ipairs(Players:GetPlayers()) do
            if p~=player then local ok,yes=pcall(player.IsFriendsWith,player,p.UserId) if ok and yes then friend=true break end end
        end
        return false,friend and "Friend playtime progresses automatically" or "Quest requires a friend in the same server"
    elseif t=="QuestComplete" then
        if flags.TargetMainQuest then return false,"Waiting for next main quest completion" end
        local selected=mobs.catalog[config.mob]
        local mob=selected and selected.quest and config.mob or "Thug"
        if mobs.catalog[mob] and mobs.catalog[mob].quest then return fightQuest(id,index,mob,token) end
        return false,"Waiting for next available quest"

    elseif t=="BattlepassTier" then
        return false,"Progresses through Battlepass XP from other quests"
    elseif t=="ObtainPower" then
        local sources=combatMetadata.powerSources[o.PowerId] or {}
        if sources[1] then return fightQuest(id,index,sources[1],token) end
        return false,"Waiting to unlock "..tostring(o.PowerId or o.Label)
    elseif t=="InterfaceInteraction" then
        local interaction=o.Interaction or o.Name or o.Interface
        if type(interaction)~="string" then return false,"No interaction identity" end
        fire("interfaceInteraction",interaction)
        waitFor(1,token) return true
    elseif t=="SummonChampion" or t=="ChampionCapsuleOpened" then
        return summonForQuest(id,index,token)
    elseif t=="SpecialRoll" then
        return rollForQuest(o,token)
    elseif t=="TournamentMatch" or t=="TournamentElimination" or t=="TournamentSpecialElimination" or t=="TournamentWin" then
        return pvpQuest(id,index,o,token,true)
    elseif t=="PlayerKill" then
        return pvpQuest(id,index,o,token,false)
    end
    return false,"Unsupported objective type: "..tostring(t)
end
local function questStep(token)
    local queue=questQueue()
    quests.current=nil
    for _,entry in ipairs(queue) do
        if not valid(token) then return end
        local id,q=entry.id,entry.data
        local definition=quests.catalog[id]
        if definition then
            local pending
            for index in ipairs(definition.Objectives) do if objectivePending(id,index) then pending=index break end end
            if q.Completed or not pending then
                local moved=true
                if id:match("^Main%.") or id:match("^Side%.") then moved=visitQuestGiver(id,token) end
                if not valid(token) then return end
                if moved and os.clock()>=(quests.nextAction[id] or 0) then
                    quests.nextAction[id]=os.clock()+5
                    local ok,accepted,message=request("redeemQuest",token,id)
                    if not valid(token) then return end
                    if ok and accepted==true then
                        q.Completed=true q.Redeemed=true quests.claimed+=1
                        state.result="Quest claimed: "..id
                        if nextQuest then
                            local good,nextId=pcall(nextQuest,id)
                            if good and nextId then acceptQuest(nextId,token) end
                        end
                    elseif ok and message=="You already redeemed this quest." then q.Completed=true q.Redeemed=true
                    elseif ok then quests.blocked[id]=tostring(message or accepted) end
                end
            else
                quests.current={id=id,index=pending,type=definition.Objectives[pending].Type,pinHead=queue[1] and queue[1].id}
                state.action="AutoQuest · "..definition.Objectives[pending].Type
                state.target=id.." · "..pending.."/"..#definition.Objectives
                quests.requiredSpecial=nil
                local worked,why=runQuestObjective(id,pending,definition.Objectives[pending],token)
                if not valid(token) then return end
                quests.requiredSpecial=nil
                if worked then quests.blocked[id]=nil else quests.blocked[id]=tostring(why) end
                if worked then return end
            end
        end
    end
    releaseTraining()
    state.action="AutoQuest" state.target="—"
    local reasons={}
    for _,entry in ipairs(queue) do
        if quests.blocked[entry.id] then table.insert(reasons,entry.id..": "..quests.blocked[entry.id]) end
        if #reasons>=3 then break end
    end
    state.waiting=#reasons>0 and table.concat(reasons,"\n") or (flags.TargetMainQuest
        and "No active main quests · use Collect Quests"
        or "No active quests · use Collect Quests")
    waitFor(2,token)
end
task.spawn(function()
    while state.alive do
        if state.ready and not state.fruitBusy and (flags.QuestScan or flags.AutoQuest) then
            local token=state.generation
            local ok,err=xpcall(function()
                if flags.QuestScan then questScan(token)
                elseif flags.BossFarm and state.bossPriority then
                    farmMob(token)
                else questStep(token) end
            end,debug.traceback)
            if not ok and valid(token) then
                if flags.BossFarm and state.bossPriority then
                    mobs.ReleaseTarget(mobs.target)
                    state.error=tostring(err) state.waiting="Recovering boss farm; quests paused"
                    waitFor(1,token)
                else
                    api.Set(flags.QuestScan and "QuestScan" or "AutoQuest",false) state.error=tostring(err)
                end
            end
        end
        task.wait(0.2)
    end
end)
api.QuestStep=questStep


do
local troll={status="Idle",kills=0,visits=0,cursor=0,cooldowns={},safeZones={},nextZones=0}
Adapter.Troll=troll
function Adapter.inSafeZone(position)
    if os.clock()>=troll.nextZones then troll.nextZones=os.clock()+0.5 troll.safeZones=CS:GetTagged("isSafeZone") end
    for _,zone in ipairs(troll.safeZones) do
        if zone:IsA("BasePart") and zone:IsDescendantOf(workspace) then
            if zone:IsA("Part") and zone.Shape~=Enum.PartType.Block then
                if (position-zone.Position).Magnitude<=zone.Size.X/2 then return true end
            else
                local point=zone.CFrame:PointToObjectSpace(position)
                local half=zone.Size/2
                if math.abs(point.X)<=half.X and math.abs(point.Y)<=half.Y and math.abs(point.Z)<=half.Z then return true end
            end
        end
    end
    return false
end
function Adapter.playerEligible(candidate,expectedCharacter)
    if not candidate or candidate==player or candidate.Parent~=Players then return false,"Player unavailable" end
    local c=candidate.Character
    if not c or (expectedCharacter and c~=expectedCharacter) or not c:IsDescendantOf(workspace) then return false,"Character unavailable" end
    local h=c:FindFirstChildOfClass("Humanoid")
    local root=c.PrimaryPart or c:FindFirstChild("HumanoidRootPart")
    if not h or not root or h.Health<=0 then return false,"Player is dead or not loaded" end
    if c:FindFirstChildOfClass("ForceField") or c:GetAttribute("isInvulnerable")==true then return false,"Player is protected" end
    if Adapter.inSafeZone(root.Position) then return false,"Player is in a safe zone" end
    return true,nil,h,root
end
function Adapter.playerFrame(target)
    local allowed,_,_,root=Adapter.playerEligible(target.player,target.model)
    if not allowed then return end
    local forward=Vector3.new(root.CFrame.LookVector.X,0,root.CFrame.LookVector.Z)
    if forward.Magnitude<0.001 then forward=Vector3.new(0,0,-1) else forward=forward.Unit end
    local center=root.Position
    for _,angle in ipairs({0,math.pi/2,-math.pi/2,math.pi}) do
        local direction=CFrame.Angles(0,angle,0):VectorToWorldSpace(forward)
        local point=center-direction*3+Vector3.new(0,1,0)
        if not Adapter.inSafeZone(point) then return CFrame.lookAt(point,center) end
    end
end
function troll.RefreshPlayers()
    if not troll.dropdown then return end
    local rows={}
    for _,candidate in ipairs(Players:GetPlayers()) do if candidate~=player then table.insert(rows,candidate) end end
    table.sort(rows,function(a,b) return a.Name:lower()<b.Name:lower() end)
    local options,map={"Select a player"},{}
    local selected="Select a player"
    for _,candidate in ipairs(rows) do
        local label=candidate.DisplayName.." (@"..candidate.Name..")"
        table.insert(options,label) map[label]=candidate.UserId
        if candidate.UserId==config.pvpPlayer then selected=label end
    end
    if config.pvpPlayer and selected=="Select a player" then selected="Unavailable · "..(config.pvpPlayerName or tostring(config.pvpPlayer)) table.insert(options,selected) end
    local signature=table.concat(options,"|").."|"..selected
    troll.labels=map
    if signature~=troll.signature then
        troll.signature=signature troll.refreshing=true
        troll.dropdown:SetOptions(options) troll.dropdown:Set(selected)
        troll.refreshing=false
    end
end
function troll.NextPlayer()
    if flags.KillSelectedPlayer then
        local chosen=config.pvpPlayer and Players:GetPlayerByUserId(config.pvpPlayer)
        if Adapter.playerEligible(chosen) then return chosen end
        local _,reason=Adapter.playerEligible(chosen)
        troll.status=reason or "Select a player"
        return
    end
    local options={}
    for _,candidate in ipairs(Players:GetPlayers()) do
        if Adapter.playerEligible(candidate) and os.clock()>=(troll.cooldowns[candidate.UserId] or 0) then table.insert(options,candidate) end
    end
    table.sort(options,function(a,b) return a.UserId<b.UserId end)
    local chosen=options[1]
    for _,candidate in ipairs(options) do if candidate.UserId>troll.cursor then chosen=candidate break end end
    if chosen then troll.cursor=chosen.UserId else troll.status="Waiting for players outside safe zones" end
    return chosen
end
function troll.Fight(candidate,token)
    local allowed,reason,enemyHum=Adapter.playerEligible(candidate)
    if not allowed then troll.status=reason return end
    local c,h,r=character()
    if not c then troll.status="Waiting for respawn" return end
    local target={id="Player_"..candidate.UserId,name=candidate.Name,model=candidate.Character,player=candidate,hp=enemyHum.Health,maxHP=enemyHum.MaxHealth}
    if not state.trainingSnapshot or state.trainingSnapshot.character~=c then state.trainingSnapshot={character=c,stat=c:GetAttribute("statEquipped")} end
    local stats=Adapter.stats()
    local weapon=(stats.Sword or 0)>=(stats.Strength or 0) and "Sword" or "Strength"
    state.trainStat=weapon fire("equipStat",{state=true,statType=weapon})
    if not waitFor(0.3,token) then return end
    mobs.target=target mobs.targetToken=token
    troll.visits+=1
    local deadline,lastAttack,lastProgress,lastHP=os.clock()+10,0,os.clock(),target.hp
    while valid(token) and (flags.KillAllPlayers or flags.KillSelectedPlayer) and player.Character==c and h.Health>0 do
        local eligible,why=Adapter.playerEligible(candidate,target.model)
        if not eligible then troll.status=why break end
        if flags.KillSelectedPlayer and candidate.UserId~=config.pvpPlayer then break end
        target.hp=enemyHum.Health
        if target.hp<lastHP then lastProgress=os.clock() end lastHP=target.hp
        state.action="PvP · "..(flags.KillAllPlayers and "All Players" or "Selected Player")
        state.target=candidate.Name
        troll.status=candidate.Name.." · HP "..hpText(target.hp).."/"..hpText(target.maxHP)
        state.waiting=troll.status
        local frame=Adapter.playerFrame(target,r)
        if not frame then troll.status="No position outside safe zones" break end
        local moved=travel(frame,token,true)
        if not valid(token) then break end
        if moved and mobs.CanAttack(target) then
            combatStep(target,token)
            if os.clock()-lastAttack>=math.max(1.1,cooldowns[weapon] or 1) then
                lastAttack=os.clock()
                if c:GetAttribute("statEquipped")~=weapon then fire("equipStat",{state=true,statType=weapon})
                else request("trainActiveStat",token) end
            end
        end
        if flags.KillAllPlayers and (os.clock()>deadline or os.clock()-lastProgress>4) then troll.status="Rotating to next player" break end
        if not waitFor(0.05,token) then break end
    end
    if candidate.Character==target.model and enemyHum.Parent and enemyHum.Health<=0 then
        troll.kills+=1 state.result="Player death confirmed: "..candidate.Name
    end
    troll.cooldowns[candidate.UserId]=os.clock()+1
    mobs.ReleaseTarget(target)
end
task.spawn(function()
    while state.alive do
        if state.ready and not state.fruitBusy and (flags.KillAllPlayers or flags.KillSelectedPlayer) then
            local candidate=troll.NextPlayer()
            if candidate then
                local token=state.generation
                local ok,err=xpcall(function() troll.Fight(candidate,token) end,debug.traceback)
                if not ok and valid(token) then state.error=tostring(err) mobs.ReleaseTarget(mobs.target) waitFor(1,token) end
            end
        end
        task.wait(0.2)
    end
end)
end -- PvP scheduler

local badgePending={}
api.Achievements={pending=badgePending}
local function claimAchievements(token)
    local list=path(player.PlayerGui,"Main.Pages.Achievements.Page.Main.Main.Milestones")
    local badges=dataAt("Badges")
    for id,index in pairs(combatMetadata.badges) do
        if not valid(token) or not flags.Rewards then return end
        local row=list and list:FindFirstChild(id)
        local title=row and path(row,"RewardsBox.Claim.Title")
        local claimed=badges and badges.Claimed and badges.Claimed[id]
        local completed=badges and badges.Completed and badges.Completed[id]
        local claimable=not claimed and (completed==true or title and title.Text:lower()=="claim")
        if claimable and os.clock()>=(badgePending[id] or 0) then
            badgePending[id]=os.clock()+60
            fire("claimBadge",index)
            if not waitFor(0.15,token) then return end
        end
    end
end

local rewardBusy=false
api.Rewards={status="Idle",pending={},retry={},confirmed=0,busy=false}
function api.ClaimChampionIndex(token,automatic)
    local rewards=api.Rewards
    if rewards.busy or not state.ready or not valid(token) or (automatic and not flags.IndexRewards) then return end
    rewards.busy=true
    local ok,err=xpcall(function()
        local owned=dataAt("ChampionIndex")
        local claimed=dataAt("ChampionIndexClaimed")
        local candidates={}
        -- Sparse replication is not an empty claim map. The native visible CLAIM
        -- label is an independent eligibility source when a full snapshot is absent.
        if type(owned)=="table" and (type(claimed)=="table" or replica.hydrated) then
            for id,collected in pairs(owned) do
                if collected==true and not (claimed and claimed[id]) then candidates[id]=true end
            end
        end
        local page=path(player.PlayerGui,"Main.Pages.ChampionIndex")
        local list=page and page.Visible and path(page,"Page.List")
        for _,row in ipairs(list and list:GetChildren() or {}) do
            local label=path(row,"Main.Slot.DataContent.Rarity")
            if row:IsA("GuiObject") and row.Visible and label and label.Text=="CLAIM" and not (claimed and claimed[row.Name]) then candidates[row.Name]=true end
        end
        local count=0
        for id in pairs(candidates) do
            if not valid(token) or (automatic and not flags.IndexRewards) then return end
            if not rewards.pending[id] and os.clock()>=(rewards.retry[id] or 0) then
                rewards.pending[id]={sent=os.clock()}
                rewards.retry[id]=os.clock()+60
                local sent,why=fire("claimChampionIndexReward",id)
                if not sent then rewards.pending[id]=nil state.error=tostring(why)
                else count+=1 end
                if not waitFor(0.2,token) then return end
            end
        end
        if valid(token) then
            rewards.status=count>0 and "Champion Index: waiting for replicated claims"
                or (next(candidates) and "Champion Index: waiting for confirmation / retry"
                or (type(claimed)=="table" or replica.hydrated or list) and "No Champion Index rewards ready"
                or "Open the native Champion Index once to load claim eligibility")
        end
    end,debug.traceback)
    rewards.busy=false
    if not ok and valid(token) then rewards.status="Champion Index error" state.error=tostring(err) end
end
function api.ObserveIndexClaims()
    local rewards=api.Rewards
    local claimed=dataAt("ChampionIndexClaimed")
    for id,pending in pairs(rewards.pending) do
        if type(claimed)=="table" and claimed[id]==true then
            rewards.pending[id]=nil rewards.confirmed+=1
            rewards.status="Champion Index confirmed: "..id
            state.result=rewards.status
        elseif os.clock()-pending.sent>=15 then
            rewards.pending[id]=nil
            rewards.status="Champion Index unconfirmed: "..id
        end
    end
end
local function claim(name,automatic,token)
    token=token or state.generation
    if rewardBusy or not state.ready or not valid(token) then return end
    local flag=name=="claimAllPlaytimeRewards" and "Rewards" or "DailyRewards"
    if automatic and not flags[flag] then return end
    rewardBusy=true
    local ok,accepted,message,data=request(name,token)
    rewardBusy=false
    if not valid(token) or (automatic and not flags[flag]) then return end
    if ok and accepted==true then
        state.result="Reward confirmed: "..name api.Rewards.status=state.result
        if name=="claimAllPlaytimeRewards" and type(data)=="table" then state.claimed=data.claimed or {} end
        if not automatic then notify("Reward confirmed by server") end
    else api.Rewards.status=tostring(message or accepted or "Reward is not available yet") end
end
function api.DailyRewardReady(name)
    local key=name=="claimDailyReward" and "DailyRewards" or name=="claimLoginBonus" and "LoginBonus"
    if not key then return false end
    local data=dataAt("Other."..key)
    local nextAt=type(data)=="table" and data.NextClaimAt
    if type(nextAt)=="number" then return nextAt<=workspace:GetServerTimeNow() end
    local page=path(player.PlayerGui,"Main.Pages."..key)
    if page and page.Visible then
        local label=path(page,key=="DailyRewards" and "Page.Rewards.Countdown.TimerLabel" or "Page.Buttons.Claim.Title")
        if label then return label.Text==(key=="DailyRewards" and "CLAIM AVAILABLE" or "Claim") end
    end
    return false
end
task.spawn(function()
    local nextClaim,nextIndex,nextDaily=0,0,0
    while state.alive do
        if state.ready then
            api.ObserveIndexClaims()
            local token=state.generation
            if flags.Rewards and os.clock()>=nextClaim then
                nextClaim=os.clock()+30
                claim("claimAllPlaytimeRewards",true,token)
                if valid(token) and flags.Rewards then claimAchievements(token) end
            end
            if valid(token) and flags.IndexRewards and os.clock()>=nextIndex then
                nextIndex=os.clock()+5 api.ClaimChampionIndex(token,true)
            end
            if valid(token) and flags.DailyRewards and os.clock()>=nextDaily then
                nextDaily=os.clock()+30
                for _,name in ipairs({"claimDailyReward","claimLoginBonus"}) do
                    if not valid(token) or not flags.DailyRewards then break end
                    if api.DailyRewardReady(name) then claim(name,true,token) end
                end
            end
        end
        task.wait(0.5)
    end
end)

do
local function buildUI()
-- Preserve existing boss checklist choices when the translated UI gets its new config.
if type(readfile)=="function" then
    local hasNew=pcall(readfile,"SmugLib_afs_hub_v5.json")
    if not hasNew then
        local ok,raw=pcall(readfile,"SmugLib_afs_game_v4.json")
        if ok then
            local decoded,data=pcall(function() return game:GetService("HttpService"):JSONDecode(raw) end)
            if decoded and type(data)=="table" then
                for key,labels in pairs(data) do
                    if type(key)=="string" and key:find("cl:",1,true) and type(labels)=="table" then
                        for _,label in ipairs(labels) do
                            if type(label)=="string" then
                                for id,d in pairs(mobs.catalog) do
                                    if d.isBoss and label:sub(1,#(d.name.." · "))==d.name.." · " then config.bosses[id]=true end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

window=Library:CreateWindow("AFS | Script Hub",{Width=780,Height=580,ToggleKey=Enum.KeyCode.RightControl,
    AccentColor=Color3.fromRGB(46,170,205),AccentLightColor=Color3.fromRGB(108,222,245),
    SectionHeaderColor=Color3.fromRGB(27,53,68),ConfigKey="afs_hub_v5",ConfigAutoSave=true,SuppressLoadNotification=true})
uiRoot=window:GetGui()
local function toggle(section,text,name)
    local control=section:Toggle(text,function(on) if state.ready then api.Set(name,on) end end,false)
    table.insert(toggleControls,{control=control,name=name})
    return control
end
local farming=window:Folder("Auto Farm")
local normalSection=farming:Section("Mob Farm")
local dungeonSection=farming:Section("Current Dungeon")
toggle(dungeonSection,"Auto Dungeon","AutoDungeon")
dungeonSection:Label("Clears the current dungeon with Powers + Specials.\nHovers above enemies and advances after confirmed kills.\nStops at the end of this run.")
dungeon.label=dungeonSection:Label("Idle")
toggle(normalSection,"Auto Farm Mobs","MobFarm")
normalSection:Label("Farms the selected mob and its repeatable quest.\nEnabling this stops Auto Farm Bosses.")
local bossTab=window:Folder("Boss Farm")
bossSection=bossTab:Section("Boss Selection")
toggle(bossSection,"Auto Farm Bosses","BossFarm")
local questFolder=window:Folder("Quests")
local questControls=questFolder:Section("Quest Farm")
toggle(questControls,"Auto Quest","AutoQuest")
toggle(questControls,"Main Quests Only","TargetMainQuest")
questControls:Button("Collect Quests",api.CollectQuests)
questControls:Button("Stop Collecting",function() api.Set("QuestScan",false) end)
state.questDataLabel=questControls:Label("Quests: 0")

mobDropdown=normalSection:Dropdown("Mob",{},function(label)
    if not state.ready or mobs.refreshingDropdown then return end
    local id=mobs.labels[label] if id then api.SelectMob(id) end
end)

bossSection:Label("Select bosses, then enable Auto Farm Bosses.\nPriority: active fight > event > HP > free start.\nWith Auto Quest: quests run between spawned bosses; no free starts.\nSelections are kept between kills and farm switches.")
Adapter.refreshBossControls()
bossJoinLabel=bossSection:Label("Select bosses and enable Auto Farm Bosses.")
local combatTab=window:Folder("Combat")
local combatSection=combatTab:Section("Auto Attack")
combatSection:Dropdown("Attack Stat",{"Strongest Stat","Sword","Strength"},function(v) config.bossWeapon=v end,config.bossWeapon)
combatSection:Toggle("Auto Basic Attacks",function(v) config.castBasic=v end,true)
combatSection:Toggle("Auto Cast Powers",function(v) config.castPowers=v end,true)
combatSection:Toggle("Auto Transform",function(v) config.autoTransform=v end,true)
combatSection:Dropdown("Powers",{"All Unlocked","Equipped Only"},function(v) config.powerMode=v end,config.powerMode)
local specialSection=combatTab:Section("Specials")
specialSection:Toggle("Special M1",function(v) config.castSpecialM1=v end,true)
specialSection:Toggle("Auto Cast Specials (Z / X / C / V)",function(v) config.castSpecials=v end,true)
combat.specialDropdown=specialSection:Dropdown("Special Selection",{"Rotate All"},function(v)
    if combat.refreshingSpecialDropdown then return end
    if v~="Rotate All" and not table.find(combat.specialOptions or {},v) then return end
    config.specialMode=v combat.nextEquip=0 combat.slotCursor=0
end,"Rotate All")
config.specialMode="Rotate All"
function combat.RefreshSpecialDropdown()
    local options={"Rotate All"}
    for _,slot in ipairs(specialSlots()) do table.insert(options,"Slot "..slot.index.." · "..slot.id) end
    local signature=table.concat(options,"|")
    if combat.specialSignature==signature then return end
    combat.specialOptions=options combat.specialSignature=signature
    if not table.find(options,config.specialMode) then config.specialMode="Rotate All" combat.nextEquip=0 combat.slotCursor=0 end
    combat.refreshingSpecialDropdown=true
    local ok,err=pcall(function()
        combat.specialDropdown:SetOptions(options)
        combat.specialDropdown:Set(config.specialMode)
    end)
    combat.refreshingSpecialDropdown=false
    if not ok then combat.specialSignature=nil state.error=tostring(err) end
end
combat.RefreshSpecialDropdown()
specialSection:Slider("Special Rotation Delay (s)",3,30,10,function(v) config.specialRotateSeconds=v end,1)
local mobSection=normalSection
mobSection:Dropdown("Attack",{"Sword","Strength"},function(v)
    config.weapon=v=="Strength" and "Strength" or "Sword"
    if state.ready and flags.MobFarm then api.Set("MobFarm",true) end
end,"Sword")
mobLabel=mobSection:Label("Loading mobs...")
mobSection:Button("Refresh Targets",refreshMobDropdown)
local training=window:Folder("Auto Train")
local trainSettings=training:Section("Training")
trainSettings:Dropdown("Training Stat",trainingStats,function(v)
    if table.find(trainingStats,v) then config.stat=v if flags.Train then api.Set("Train",true) end end
end,config.stat)
toggle(trainSettings,"Auto Train","Train")
trainSettings:Toggle("Train Sword in Durability Area",function(v)
    config.swordDurability=v
    if state.ready and flags.Train then
        state.generation+=1 api.CancelMove() releaseTraining()
    end
end,false)
trainSettings:Dropdown("Training Mode",{"Selected Stat","Stat Rotation"},function(v)
    config.cycle=v=="Stat Rotation"
    if state.ready and flags.Train then api.Set("Train",true) end
end,"Selected Stat")
trainSettings:Slider("Rotation Delay (s)",10,120,30,function(v) config.cycleSeconds=v end,5)
trainSettings:Toggle("Auto Best Training Area",function(on)
    config.bestZone=on
    if state.ready and flags.Train then api.Set("Train",true) end
end,true)
trainSettings:Label("Speed / Agility alternates both areas.\nInside training areas: stand still, no movement or jumping.")
state.trainLabel=trainSettings:Label("Idle")
local fruitTab=window:Folder("Fruit Sniper")
local fruitSection=fruitTab:Section("Snipe Fruit")
fruitDropdown=fruitSection:Dropdown("Fruit",fruitOptions,function(id)
    if state.ready then api.SelectFruit(id) elseif id=="All Fruits" or fruits.catalog[id] then config.fruit=id end
end,config.fruit)
local savedFruit=fruitDropdown:Get()
if savedFruit=="All Fruits" or fruits.catalog[savedFruit] then config.fruit=savedFruit else fruitDropdown:Set(config.fruit) end
toggle(fruitSection,"Auto Collect Fruit","FruitSnipe")
fruitLabel=fruitSection:Label("Idle")

local navigation=window:Folder("Teleports")
local travelSettings=navigation:Section("Teleport Settings")
travelSettings:Dropdown("Teleport Method",{"Game Teleport","Teleport","Tween"},function(v) config.moveMode=v end,config.moveMode)
travelSettings:Slider("Tween Speed",20,500,100,function(v) config.tweenSpeed=v end,10)
travelSettings:Slider("Timeout (s)",3,30,12,function(v) config.timeout=v end,1)
local zones=navigation:Section("Training Areas")
zoneDropdown=zones:Dropdown("Training Area",{},function(v) selectedZone=v end)
selectedZone=zoneDropdown:Get()
local function manual(operation)
    api.CancelAutomationMovement()
    local token=state.generation
    task.spawn(function()
        local ok,a,b=xpcall(function() return operation(token) end,debug.traceback)
        if valid(token) then
            state.action="Manual teleport"
            state.result=ok and a and "Position confirmed after teleport" or "Teleport unconfirmed"
            state.waiting=tostring(ok and b or a)
        end
    end)
end
zones:Button("Teleport to Selected Area",function()
    for _,zone in ipairs(state.zones) do if zone.label==selectedZone then
        local stat=zone.rewards and zone.rewards[1] and zone.rewards[1].statType or config.stat
        manual(function(token) return zoneTravel(zone,stat,token) end) return
    end end
    notify("Select an area from the list")
end)
zones:Button("Teleport to Best Area",function()
    local stat=config.stat=="Speed / Agility" and "Agility" or config.stat
    local zone=Adapter.best(stat)
    if zone then manual(function(token) return zoneTravel(zone,stat,token) end)
    else notify("No eligible training area") end
end)
local places=navigation:Section("Locations & NPCs")
local categoryDropdown=places:Dropdown("Category",placeCategories,function(v)
    if table.find(placeCategories,v) then config.placeCategory=v updatePlaceOptions() end
end,config.placeCategory)
if table.find(placeCategories,categoryDropdown:Get()) then config.placeCategory=categoryDropdown:Get() else categoryDropdown:Set(config.placeCategory) end
placeDropdown=places:Dropdown("Location",{},function(v) selectedPlace=v end)
selectedPlace=placeDropdown:Get()
placeLabel=places:Label("Loading locations...")
places:Button("Teleport to Location",function()
    for _,place in ipairs(state.places) do if place.label==selectedPlace and place.object.Parent then
        local cf=objectFrame(place.object)
        if cf then manual(function(token) return travel(cf*CFrame.new(0,3,6),token) end) end return
    end end
    notify("Location is not loaded; refresh the list")
end)
local bookmarks=navigation:Section("Position Bookmark")
bookmarks:Button("Save Position",function() local _,_,r=character() if r then savedPosition=r.CFrame notify("Position saved") end end)
bookmarks:Button("Return to Saved Position",function() if savedPosition then manual(function(token) return travel(savedPosition,token) end) else notify("Save a position first") end end)
local navigationActions=navigation:Section("Teleport Controls")
navigationActions:Button("Cancel Teleport",api.CancelAutomationMovement)
navigationActions:Button("Refresh Locations",function() task.spawn(api.Refresh) end)

local trollTab=window:Folder("Troll")
local pvpSection=trollTab:Section("Player Combat")
pvpSection:Label("Targets players outside safe zones.\nUses all available Powers and Specials. Enabling PvP stops other farms.")
toggle(pvpSection,"Kill all players","KillAllPlayers")
Adapter.Troll.dropdown=pvpSection:Dropdown("Target Player",{"Select a player"},function(label)
    local troll=Adapter.Troll
    if troll.refreshing then return end
    local id=troll.labels and troll.labels[label]
    if label~="Select a player" and not id then return end
    config.pvpPlayer=id config.pvpPlayerName=label
    if state.ready and flags.KillSelectedPlayer then api.Set("KillSelectedPlayer",true) end
end,"Select a player")
toggle(pvpSection,"Kill selected player","KillSelectedPlayer")
Adapter.Troll.label=pvpSection:Label("Idle")
pvpSection:Button("Refresh Players",Adapter.Troll.RefreshPlayers)
Adapter.Troll.RefreshPlayers()

local playerTab=window:Folder("Player")
local movement=playerTab:Section("Movement")
toggle(movement,"Noclip","Noclip") toggle(movement,"Walk Speed","Speed")
movement:Slider("Walk / Fly Speed",10,250,60,function(v) config.speed=v end,5)
toggle(movement,"Jump Power Changer","Jump")
movement:Slider("Jump Power",10,180,60,function(v) config.jump=v end,5)
toggle(movement,"Infinite Jump","InfiniteJump") toggle(movement,"Fly (WASD / Space / Ctrl)","Fly")
movement:Button("Reset Movement",function()
    api.CancelMove()
    for _,name in ipairs({"Noclip","Speed","Jump","InfiniteJump","Fly"}) do flags[name]=false end
    restoreCharacter()
    for _,item in ipairs(toggleControls) do
        item.control:Set(flags[item.name])
    end
end)
movement:Button("Reset Character",function() api.StopAll() local _,h=character() if h then h.Health=0 end end)
local visuals=playerTab:Section("Visuals & Utility")
toggle(visuals,"Anti AFK","AntiAFK") toggle(visuals,"Fullbright","Fullbright") toggle(visuals,"FOV Changer","FOV")
visuals:Slider("Field of View",40,110,80,function(v) config.fov=v end,1)
toggle(visuals,"NPC & Location ESP","ESP")

local diagnostics=window:Folder("Settings")
local rewardSection=diagnostics:Section("Rewards")
toggle(rewardSection,"Auto Claim Playtime & Achievements","Rewards")
toggle(rewardSection,"Auto Claim Champion Index","IndexRewards")
toggle(rewardSection,"Auto Claim Daily & Login","DailyRewards")
rewardSection:Button("Claim Champion Index",function() task.spawn(api.ClaimChampionIndex,state.generation,false) end)
api.Rewards.label=rewardSection:Label("Idle")
rewardSection:Button("Claim Playtime Rewards",function() task.spawn(claim,"claimAllPlaytimeRewards") end)
rewardSection:Button("Claim Daily Reward",function() task.spawn(claim,"claimDailyReward") end)
rewardSection:Button("Claim Login Bonus",function() task.spawn(claim,"claimLoginBonus") end)

local info=diagnostics:Section("Runtime Status")
info:Toggle("Resume After Respawn",function(on) config.resumeRespawn=on end,true)
statusLabel=info:Label("Loading data...")
statsLabel=info:Label("Stats...")
questLabel=info:Label("Quests...")
info:Button("Refresh Data",function() task.spawn(api.Refresh) end)
info:Button("Stop All",api.StopAll)
info:Button("Unload",api.Unload)

end
buildUI()
end

function api.Diagnose()
    local pending={} for name in pairs(state.requests) do table.insert(pending,name) end
    local placeCounts={} for _,place in ipairs(state.places) do placeCounts[place.category]=(placeCounts[place.category] or 0)+1 end
    local stats,source=Adapter.stats()
    return {version=api.Version,alive=state.alive,flags=table.clone(flags),action=state.action,target=state.target,
        result=state.result,waiting=state.waiting,error=state.error,zones=#state.zones,places=#state.places,
        rewards={status=api.Rewards.status,indexConfirmed=api.Rewards.confirmed},
        stats=stats,source=source,pending=pending,accepted=state.confirmed,rejected=state.rejected,
        moving=state.move~=nil,claimed=state.claimed,generation=state.generation,bossPriority=state.bossPriority==true,
        mob=config.mob,mobTarget=mobs.target and mobs.target.id,mobHP=mobs.target and mobs.target.hp,
        mobKills=mobs.kills,mobRecoveries=mobs.recoveries or 0,mobQuests=mobs.quests,mobHistory=table.clone(mobs.history),
        mobQuest=mobs.acceptedQuest,
        bloodMoon=mobs.bloodMoon,effectiveMob=mobs.bossRun and (mobs.bossRun.current or "Selected Bosses") or (bloodMoonOverride() and "Skeletoni" or config.mob),
        fruit=config.fruit,fruitBusy=state.fruitBusy==true,fruitStatus=fruits.status,fruitsCollected=fruits.collected,
        fruitTypes=#fruitOptions-1,
        placeCounts=placeCounts,
        bossDimension=mobs.bossDimension,bossOptions=#(mobs.bossChecklistOptions or {}),bossSelection=table.clone(config.bosses),bossRun=mobs.bossRun,bossQueue=dungeon.pending,dungeonPhase=dungeon.state.phase,
        autoDungeon={status=dungeon.farm.status,phase=workspace:GetAttribute("Phase") or dungeon.state.phase,job=dungeon.farm.job},trainingGear=Adapter.TrainingGear.status,pvpStatus=Adapter.Troll.status,pvpKills=Adapter.Troll.kills,pvpVisits=Adapter.Troll.visits,pvpSelected=config.pvpPlayer,
        objectives=Adapter.questObjectives(),questQueue=questQueue(),questCurrent=quests.current,questBlocked=quests.blocked,scanResult=quests.scanResult,casts=combat.casts,aimUpdates=combat.aimUpdates or 0,bossDefense=defense.status,dodges=defense.count,skippedCasts=combat.Hit.skipped,castWait=combat.Hit.lastReason}
end
api.Adapter=Adapter
api.Travel=travel
api.Mobs=mobs
connect(workspace:GetAttributeChangedSignal("currentDimension"),function()
    if state.ready then
        api.CancelAutomationMovement()
        table.clear(state.zones) selectedZone=nil selectedPlace=nil
        if zoneDropdown then zoneDropdown:SetOptions({}) end
        refreshPlaces() Adapter.refreshBossControls()
        task.spawn(api.Refresh)
    end
end)
connect(RunService.PreSimulation,function() if state.alive then applyPlayer() end end)
connect(workspace:GetAttributeChangedSignal("bloodMoonEndsAt"),function()
    local active=workspace:GetAttribute("bloodMoonEndsAt")~=nil -- exact HalloweenEvent.isBloodMoonActive contract
    if active==mobs.bloodMoon then return end
    mobs.bloodMoon=active mobs.eventBatch=nil mobs.eventRoute=nil mobs.eventRouteIndex=0
    local selected=mobs.catalog[config.mob]
    if config.farmBosses or mobs.bossRun or (selected and selected.isBoss) then return end
    if flags.MobFarm then api.Set("MobFarm",true) end
    state.result=active and "Blood Moon: farming Skeletons" or "Blood Moon ended: returning to "..config.mob
end)
local function maintainCombatLock()
    local target=mobs.target
    if not state.alive or state.fruitBusy or state.move or not (flags.AutoDungeon or flags.MobFarm or flags.BossFarm or flags.AutoQuest or flags.KillAllPlayers or flags.KillSelectedPlayer) then return end
    if target and not mobs.ResolveModel(target) then return end
    local _,h,root=character()
    if not root then return end
    local cf
    if mobs.IsLive(target) and mobs.ResolveModel(target) then
        defense.waitPoint=nil
        cf=mobFacingFrame(target,root)
    else cf=defense.waitPoint end
    if cf then
        h:Move(Vector3.zero)
        root.AssemblyLinearVelocity=Vector3.zero root.AssemblyAngularVelocity=Vector3.zero
        root.CFrame=cf
    end
end
defense.Apply=maintainCombatLock
connect(RunService.PreSimulation,maintainCombatLock)
connect(RunService.PostSimulation,maintainCombatLock)
connect(RunService.RenderStepped,maintainCombatLock)
-- Defensive movement is applied first. A slow basic attack RPC cannot delay aim or casts.
connect(RunService.Heartbeat,function()
    if not state.ready then return end
    if not combatActive() then
        if mobs.target then
            if not mobs.IsLive(mobs.target) then mobs.ReleaseTarget(mobs.target)
            else mobs.SuspendCombat() end
        end
        return
    end
    local target=mobs.target
    if not mobs.IsLive(target) then return end
    maintainCombatLock()
    state.eventBatch=true
    local ok,err=xpcall(function()
        for id,entry in pairs(combat.aims) do
            if entry.expires<os.clock() then combat.aims[id]=nil
            elseif entry.target==target then aimPower(id,target) end
        end
        combatStep(target,state.generation)
    end,debug.traceback)
    state.eventBatch=false
    if Events.sendEvents then
        local sent,why=pcall(Events.sendEvents)
        if not sent then state.error=tostring(why) end
    end
    if not ok then state.error=tostring(err) end
end)
connect(player.CharacterRemoving,function()
    state.generation+=1 releaseCast() api.CancelMove() releaseTraining() restoreCharacter()
    mobs.target=nil mobs.acceptedQuest=nil
    if not config.resumeRespawn and not mobs.bossRun and not flags.AutoDungeon then
        flags.AutoQuest=false flags.QuestScan=false
        flags.Train=false
        flags.MobFarm=false flags.BossFarm=false flags.KillAllPlayers=false flags.KillSelectedPlayer=false
        flags.FruitSnipe=false
        for _,item in ipairs(toggleControls) do if not flags[item.name] then item.control:Set(false) end end
    end
end)
connect(UIS.JumpRequest,function()
    if state.alive and flags.InfiniteJump and not state.move and not flags.Fly then
        local _,h=character() if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end)
connect(UIS.InputBegan,function(input,processed)
    if not processed and not UIS:GetFocusedTextBox() and input.KeyCode==Enum.KeyCode.Pause then api.StopAll() end
end)
connect(player.Idled,function()
    if not state.alive or not flags.AntiAFK then return end
    pcall(function()
        local user=game:GetService("VirtualUser")
        local camera=workspace.CurrentCamera
        user:Button2Down(Vector2.zero,camera and camera.CFrame or CFrame.new())
        task.wait(0.1)
        user:Button2Up(Vector2.zero,camera and camera.CFrame or CFrame.new())
    end)
end)
task.spawn(function()
    local refreshAt=0
    while state.alive do
        local ok,err=pcall(function()
            if flags.Fullbright then
                if not lightSnapshot then lightSnapshot={} end
                for key,value in pairs({Brightness=2,Ambient=Color3.new(1,1,1),OutdoorAmbient=Color3.new(1,1,1)}) do
                    if not lightSnapshot[key] then lightSnapshot[key]={original=Lighting[key]} end
                    Lighting[key]=value lightSnapshot[key].last=value
                end
            end
            local camera=workspace.CurrentCamera
            if flags.FOV and camera then
                if not cameraSnapshots[camera] then cameraSnapshots[camera]={original=camera.FieldOfView} end
                camera.FieldOfView=config.fov
                cameraSnapshots[camera].last=config.fov
            end
            if os.clock()>refreshAt then refreshAt=os.clock()+10 refreshPlaces() end
            refreshMobDropdown()
            combat.RefreshSpecialDropdown()
            Adapter.Troll.RefreshPlayers()
            Adapter.Troll.label:SetText((flags.KillAllPlayers or flags.KillSelectedPlayer) and (Adapter.Troll.status.."\nConfirmed kills: "..Adapter.Troll.kills.." · Visits: "..Adapter.Troll.visits) or "Idle")
            local selected=mobs.catalog[config.mob]
            local selectedBoss=mobs.catalog[mobs.bossRun and mobs.bossRun.current]
            local quest=selected and selected.quest
            local bossCount=#Adapter.bossSelectedLabels()
            bossJoinLabel:SetText((mobs.bossDimension or "Waiting for dimension").." · Selected bosses: "..bossCount..(mobs.bossRun and (" · round "..mobs.bossRun.round.." · selection locked") or "").."\n"..(selectedBoss and Adapter.bossInCurrentDimension(selectedBoss.id) and (selectedBoss.name.."\n"..bossActivationInfo(selectedBoss.id).." · Casts: "..combat.casts.."\nSpecial: "..(combat.equipStatus or "—").."\n"..defense.status) or "Waiting for selected bosses"))
            fruitLabel:SetText(fruits.status.."\nSelection: "..config.fruit.." · Collected: "..fruits.collected.."\nCatalog: "..(#fruitOptions-1).." types")
            mobLabel:SetText("Selected: "..(selected and selected.name or "—").."\nQuest NPC: "..(quest and quest.npc or "No repeatable quest").."\nConfirmed kills: "..mobs.kills.." · Quests claimed: "..mobs.quests)
            if bloodMoonOverride() then
                mobLabel:SetText("Blood Moon: strongest → weakest Skeletons\nReturn target: "..(selected and selected.name or "—").."\nConfirmed kills: "..mobs.kills)
            end
            if flags.ESP then
                local _,_,root=character()
                local allowed={}
                if root then for _,place in ipairs(state.places) do
                    local object=place.object
                    local cf=object.Parent and objectFrame(object)
                    if cf and place.category~="Mob" and (cf.Position-root.Position).Magnitude<=config.routeRadius then
                        allowed[object]=true
                        if not highlights[object] then
                            local h=Instance.new("Highlight") h.Adornee=object
                            h.FillColor=Color3.fromRGB(105,160,255) h.FillTransparency=0.75
                            h.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop h.Parent=uiRoot
                            highlights[object]=h
                        end
                    end
                end end
                for object,h in pairs(highlights) do if not allowed[object] then h:Destroy() highlights[object]=nil end end
            end
            local d=api.Diagnose()
            if api.Rewards.label then api.Rewards.label:SetText(api.Rewards.status.."\nIndex claims confirmed: "..api.Rewards.confirmed) end
            if dungeon.label then dungeon.label:SetText(dungeon.farm.status.."\nPhase: "..tostring(d.autoDungeon.phase or "Unknown")) end
            state.trainLabel:SetText(flags.Train and (d.action.."\n"..d.target.."\n"..d.waiting.."\nGear: "..Adapter.TrainingGear.status) or "Idle")
            statusLabel:SetText("Action: "..d.action.."\nTarget: "..d.target.."\nResult: "..d.result.."\nWaiting: "..d.waiting.."\nError: "..d.error.."\nRPC accepted / rejected: "..d.accepted.." / "..d.rejected)
            local lines={d.source}
            for _,name in ipairs(statNames) do table.insert(lines,name..": "..tostring(d.stats[name] or "unavailable")) end
            statsLabel:SetText(table.concat(lines," · "))
            local queue=questQueue()
            local blocked=0 for _ in pairs(quests.blocked) do blocked+=1 end
            state.questDataLabel:SetText("Active: "..#queue.." · Claimed: "..quests.claimed.." · Pending: "..blocked.."\nScan: "..quests.scanIndex.."/"..(quests.scanQueue and #quests.scanQueue or 0))
            local text={}
            for i,entry in ipairs(queue) do
                if i>4 then break end
                table.insert(text,entry.id..(quests.blocked[entry.id] and " · "..quests.blocked[entry.id] or ""))
            end
            questLabel:SetText(#text>0 and table.concat(text,"\n") or "Active quests: —")
        end)
        if not ok then state.error=tostring(err) end
        task.wait(1)
    end
end)
-- Window cleanup owns the runtime too (including the library's close button).
if uiRoot then connect(uiRoot.Destroying,api.Unload) end
for _,item in ipairs(toggleControls) do item.control:Set(false) end
for name in pairs(flags) do flags[name]=false end
-- Generated setters replay their buffered historical messages asynchronously. Ignore that backlog.
task.wait(0.2)
table.clear(mobs.entities) table.clear(mobs.dead) table.clear(mobs.removed) table.clear(mobs.completed)
mobs.bootstrapping=false
mobs.bloodMoon=workspace:GetAttribute("bloodMoonEndsAt")~=nil
scanMobs()
state.ready=true
task.spawn(api.Refresh)
-- An explicit active dungeon journey may continue across places; ordinary/saved starts remain OFF.
if type(teleportResume)=="table" and teleportResume.questId and quests.catalog[teleportResume.questId] then
    local ok,data=pcall(game:GetService("HttpService").JSONDecode,game:GetService("HttpService"),teleportResume.questData or "{}")
    if ok then quests.known[teleportResume.questId]=data end
    config.swordDurability=teleportResume.swordDurability==true
    config.dungeonDifficulty=teleportResume.difficulty or "Easy"
    api.Set("TargetMainQuest",teleportResume.targetMainQuest==true)
    api.Set("AutoQuest",true)
    if teleportResume.bossFarm==true then
        local decoded,bosses=pcall(game:GetService("HttpService").JSONDecode,game:GetService("HttpService"),teleportResume.bossesData or "{}")
        if decoded and type(bosses)=="table" then
            table.clear(config.bosses)
            for id,selected in pairs(bosses) do
                if selected==true and mobs.catalog[id] and mobs.catalog[id].isBoss then config.bosses[id]=true end
            end
            api.Set("BossFarm",true)
        end
    end
elseif type(teleportResume)=="table" and dungeonBosses[teleportResume.mob] then
    config.weapon=teleportResume.weapon=="Strength" and "Strength" or "Sword"
    if table.find({"Easy","Medium","Hard","Nightmare"},teleportResume.difficulty) then config.dungeonDifficulty=teleportResume.difficulty end
    api.SelectMob(teleportResume.mob)
    api.Set("AutoJoinBoss",true) api.Set("BossFarm",true)
end
notify("AFS ready · RightControl: menu · Pause: Stop All")

]====]
local run, err = loadstring(AFS_SOURCE, "AFS")
assert(run, err)
return run(AFS_SOURCE)
