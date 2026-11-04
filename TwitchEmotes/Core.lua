-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local addonName, E = ...

local metadata = _G.C_AddOns and _G.C_AddOns.GetAddOnMetadata or _G.GetAddOnMetadata
E.title = metadata and metadata(addonName, "Title") or "Twitch Emotes"
E.version = "3.1.0"
E.addonName = addonName
E.packs, E.packOrder, E.catalog, E.names = {}, {}, {}, {}
E.revision = 0
E.savedRowLimit = 16384
E.channelLabels = {
    CHAT_MSG_SAY = "Say", CHAT_MSG_YELL = "Yell", CHAT_MSG_GUILD = "Guild", CHAT_MSG_GUILD_DISCORD = "Guild Discord",
    CHAT_MSG_OFFICER = "Officer", CHAT_MSG_PARTY = "Party", CHAT_MSG_PARTY_LEADER = "Party leader",
    CHAT_MSG_RAID = "Raid", CHAT_MSG_RAID_LEADER = "Raid leader", CHAT_MSG_RAID_WARNING = "Raid warning",
    CHAT_MSG_INSTANCE_CHAT = "Instance", CHAT_MSG_INSTANCE_CHAT_LEADER = "Instance leader",
    CHAT_MSG_WHISPER = "Whispers", CHAT_MSG_WHISPER_INFORM = "Outgoing whispers",
    CHAT_MSG_BN_WHISPER = "Battle.net whispers", CHAT_MSG_BN_WHISPER_INFORM = "Outgoing Battle.net whispers",
    CHAT_MSG_CHANNEL = "Public channels", CHAT_MSG_COMMUNITIES_CHANNEL = "Communities", CHAT_MSG_EMOTE = "Emotes",
}

local floor, min, max, byte = math.floor, math.min, math.max, string.byte
local defaultGroups = {general=true, graycen=true, forsen=true, erobb221=true, xqc=true, asmongold=true}
-- Twitch's global text faces (every global name with punctuation) and everyday chat or WoW words start hidden.
local defaultHidden = {
    {2, {":)",":(",":O",":D","D:"}},
    {3, {"<3","1G","Retail","Classic","classic","CLASSIC"}},
    {4, {"8-)",":-(",":-)",":-/",":-\\",":-D",":-O",":-o",":-P",":-p",":-Z",":-z",":/",":\\",":o",":P",":p",":Z",":z",";)",";-)",";-P",";-p",";P",";p",">(","B)","B-)","O.O","O.o","o.O","o.o","O_O","O_o","o_O","o_o","R)","R-)","BOP"}},
}
local function number(value, fallback, low, high)
    if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return fallback end
    return min(high, max(low, value))
end
local function boolean(value, fallback)
    if type(value) == "boolean" then return value end
    return fallback
end
local function tableOrEmpty(value) return type(value) == "table" and value or {} end
local function validName(name)
    return type(name) == "string" and #name > 0 and #name <= 128 and not name:find("[%s%c|]")
end
local function powerOfTwo(value)
    if value < 1 or value ~= floor(value) then return false end
    while value > 1 do if value % 2 ~= 0 then return false end; value = value / 2 end
    return true
end
local function byName(a,b)
    if a.searchName==b.searchName then if a.name==b.name then return a.packID<b.packID end; return a.name<b.name end
    return a.searchName<b.searchName
end
local function byCompletion(a,b)
    if a.completionName==b.completionName then if a.name==b.name then return a.packID<b.packID end; return a.name<b.name end
    return a.completionName<b.completionName
end
local sortedEntries, completionEntries
E.ValidEmoteName = validName

function E:IsRestricted(value)
    if issecretvalue and issecretvalue(value) then return true end
    return canaccessvalue and not canaccessvalue(value) or false
end

function E:InitializeDB(saved)
    local s = tableOrEmpty(saved)
    local d = {schema=4, channels={}, packs={}, favorites={}, hidden={}, recent={}, stats={}}
    d.enabled = boolean(s.enabled, true)
    local savedSize=s.size
    if (type(s.schema)~="number" or s.schema<2) and savedSize==22 then savedSize=nil end
    d.size = floor(number(savedSize, 28, 12, 40))
    d.animate = boolean(s.animate, true)
    d.animationFPS = floor(number(s.animationFPS, 60, 5, 60))
    d.minimap = boolean(s.minimap, true)
    d.minimapAngle = number(s.minimapAngle,220,0,360)
    d.setupComplete = boolean(s.setupComplete,false)
    d.preferredGroup = type(s.preferredGroup)=="string" and s.preferredGroup:match("^[%w_-]+$") and #s.preferredGroup<=64 and s.preferredGroup or nil
    for event in pairs(self.channelLabels) do
        d.channels[event] = boolean(tableOrEmpty(s.channels)[event], true)
    end
    for id, enabled in pairs(tableOrEmpty(s.packs)) do
        if type(id)=="string" and #id <= 64 and type(enabled)=="boolean" then d.packs[id]=enabled end
    end
    local count,rows=0,self.savedRowLimit
    for name, favorite in pairs(tableOrEmpty(s.favorites)) do
        if validName(name) and favorite == true and count < rows then d.favorites[name]=true; count=count+1 end
    end
    count=0
    for name, hidden in pairs(tableOrEmpty(s.hidden)) do
        if validName(name) and hidden == true and count < rows then d.hidden[name]=true; count=count+1 end
    end
    -- A restore is stored as absence, so each name is hidden only by the schema that added it.
    local schema=type(s.schema)=="number" and s.schema or 0
    for _,step in ipairs(defaultHidden) do
        if schema<step[1] then for _,name in ipairs(step[2]) do d.hidden[name]=true end end
    end
    local recentSeen={}
    for _, name in ipairs(tableOrEmpty(s.recent)) do
        if #d.recent >= 100 then break end
        if validName(name) and not recentSeen[name] then d.recent[#d.recent+1]=name; recentSeen[name]=true end
    end
    count=0
    for name, value in pairs(tableOrEmpty(s.stats)) do
        if validName(name) and type(value)=="table" and count < rows then
            local sent, seen = value.sent, value.seen
            d.stats[name]={sent=floor(number(sent,0,0,2147483647)), seen=floor(number(seen,0,0,2147483647))}
            count=count+1
        end
    end
    self.db=d
    self.messageIDs, self.messageRing, self.messageCursor = {}, {}, 0
    return d
end

function E:PrepareSetup()
    local selected={}
    for _,id in ipairs(self.packOrder) do
        local choice=self.db.packs[id]
        if choice~=nil then
            local group=self.packs[id].group
            selected[group]=selected[group] or choice
        end
    end
    for _,id in ipairs(self.packOrder) do
        if self.db.packs[id]==nil then
            local group=self.packs[id].group
            local choice=selected[group]
            if choice==nil then choice=defaultGroups[group]==true end
            self.db.packs[id]=choice
        end
    end
end

function E:RegisterPack(def)
    assert(type(def)=="table" and type(def.id)=="string" and def.id:match("^[%w_-]+$") and #def.id <= 64, "invalid pack id")
    assert(type(def.emotes)=="table", "pack has no emote list")
    local pack={id=def.id,title=def.title or def.id,provider=def.provider or "",source=def.source or "",priority=number(def.priority,0,-1000,1000),emotes={}}
    pack.group=def.group or (def.id:match("_global$") and "general") or def.id
    assert(type(pack.group)=="string" and pack.group:match("^[%w_-]+$") and #pack.group<=64,"invalid group id")
    pack.groupTitle=pack.group=="general" and "General" or def.groupTitle or pack.title
    local seen={}
    for i, raw in ipairs(def.emotes) do
        assert(type(raw)=="table" and validName(raw.name), "invalid emote name in "..def.id)
        assert(not seen[raw.name], "duplicate emote name in "..def.id); seen[raw.name]=true
        local textureType=type(raw.path)=="string" and raw.path:match("^Interface\\AddOns\\TwitchEmotes\\Media\\[%w_\\%-]+%.([a-z]+)$")
        assert(textureType=="tga" or textureType=="blp", "invalid texture path")
        local w,h,sw,sh,frames,fps=raw.width,raw.height,raw.sheetWidth,raw.sheetHeight,raw.frames or 1,raw.fps or 0
        local columns,cellWidth=raw.columns or 1,raw.cellWidth or sw
        for _, v in ipairs({w,h,sw,sh,frames,fps,columns,cellWidth}) do assert(type(v)=="number" and v==v and v < math.huge, "invalid texture dimension") end
        assert(w and h and sw and sh and w>=1 and h>=1 and w<=256 and h<=128 and w==floor(w) and h==floor(h), "invalid frame size")
        assert(sw>=w and sh>=h and sw<=2048 and sh<=2048 and powerOfTwo(sw) and powerOfTwo(sh), "invalid texture canvas")
        assert(columns>=1 and columns<=32 and columns==floor(columns) and cellWidth>=w and cellWidth<=256 and powerOfTwo(cellWidth) and columns*cellWidth<=sw,"invalid texture grid")
        assert(frames>=1 and frames<=256 and frames==floor(frames) and math.ceil(frames/columns)*h<=sh, "invalid frame count")
        assert((frames==1 and fps>=0) or (fps>0 and fps<=60), "invalid animation rate")
        local sequence=raw.sequence
        if sequence~=nil then
            assert(type(sequence)=="string" and #sequence>=2 and #sequence<=256 and frames>=2, "invalid frame sequence")
            for k=1,#sequence do assert(byte(sequence,k)<frames, "invalid frame sequence") end
        end
        local e={name=raw.name,path=raw.path,width=w,height=h,sheetWidth=sw,sheetHeight=sh,frames=frames,fps=fps,columns=columns,cellWidth=cellWidth,sequence=sequence,
            creator=type(raw.creator)=="string" and raw.creator or "",source=type(raw.source)=="string" and raw.source or pack.source,
            id=raw.id,packID=def.id,provider=pack.provider,searchName=raw.name:lower(),completionName=raw.name:lower():gsub("^:","")}
        pack.emotes[i]=e
    end
    if not self.packs[def.id] then self.packOrder[#self.packOrder+1]=def.id end
    self.packs[def.id]=pack
    sortedEntries=nil
end

-- Settings never change this index: the preferred-group bonus is equal within a group, so each group's winner is fixed.
local function indexPacks(self)
    local known,groups,groupPriority,entries,winners,browseNames={},{},{},{},{},{}
    for _, id in ipairs(self.packOrder) do
        local pack=self.packs[id]
        local group,ranks=groups[pack.group] or {},groupPriority[pack.group] or {}
        groups[pack.group],groupPriority[pack.group]=group,ranks
        for _, entry in ipairs(pack.emotes) do
            known[entry.name]=true; entries[#entries+1]=entry
            if not ranks[entry.name] or pack.priority>=ranks[entry.name] then group[entry.name]=entry; ranks[entry.name]=pack.priority end
        end
    end
    local completion={}; for i,entry in ipairs(entries) do completion[i]=entry end
    table.sort(entries,byName); table.sort(completion,byCompletion)
    for _,group in pairs(groups) do for _,entry in pairs(group) do winners[entry]=true end end
    for _,entry in ipairs(entries) do if winners[entry] then browseNames[#browseNames+1]=entry end end
    sortedEntries,completionEntries=entries,completion
    self.known,self.browseNames=known,browseNames
end

function E:RebuildCatalog()
    if not self.db then self:InitializeDB() end
    if not sortedEntries then indexPacks(self) end
    local catalog,priority,available,allPriority={},{},{},{}
    local hidden,choices,preferred=self.db.hidden,self.db.packs,self.db.preferredGroup
    for _, id in ipairs(self.packOrder) do
        local pack=self.packs[id]
        local rank=pack.priority+(pack.group==preferred and 10000 or 0)
        local enabled=choices[id]~=false
        for _, entry in ipairs(pack.emotes) do
            local name=entry.name
            if not allPriority[name] or rank>=allPriority[name] then available[name]=entry; allPriority[name]=rank end
            if enabled and not hidden[name] and (not priority[name] or rank>=priority[name]) then catalog[name]=entry; priority[name]=rank end
        end
    end
    local names,completionNames,hiddenNames={},{},{}
    for _,entry in ipairs(sortedEntries) do if catalog[entry.name]==entry then names[#names+1]=entry end end
    for _,entry in ipairs(completionEntries) do if catalog[entry.name]==entry then completionNames[#completionNames+1]=entry end end
    for name in pairs(hidden) do if available[name] then hiddenNames[#hiddenNames+1]=available[name] end end
    table.sort(hiddenNames,byName)
    self.catalog,self.names,self.completionNames=catalog,names,completionNames
    self.available,self.hiddenNames=available,hiddenNames
    for i=#self.db.recent,1,-1 do if not self.known[self.db.recent[i]] then table.remove(self.db.recent,i) end end
    self.revision=self.revision+1
    if self.BuildMatcher then self:BuildMatcher() end
end

function E:GetEmote(name,includeDisabled) return (includeDisabled and self.available or self.catalog)[name] end
function E:IsEmoteHidden(name) return self.db.hidden[name]==true end
function E:GetHiddenEmote(name) return self:IsEmoteHidden(name) and self.available[name] or nil end

function E:SetEmoteHidden(name,hidden)
    if not validName(name) or not self.known[name] or type(hidden)~="boolean" or self:IsEmoteHidden(name)==hidden then return false end
    self.db.hidden[name]=hidden or nil
    self:RebuildCatalog()
    if self.DismissCompletion then self:DismissCompletion() end
    if self.Refresh then self:Refresh() elseif self.RefreshUI then self:RefreshUI() end
    return true
end

function E:GetGroups()
    local groups,byID={},{}
    for _,id in ipairs(self.packOrder) do
        local pack=self.packs[id]
        local group=byID[pack.group]
        if not group then
            group={id=pack.group,title=pack.groupTitle,packIDs={}}
            groups[#groups+1]=group; byID[group.id]=group
        end
        group.packIDs[#group.packIDs+1]=id
    end
    table.sort(groups,function(a,b)
        if a.id==b.id then return false end
        if a.id=="general" then return true end
        if b.id=="general" then return false end
        return a.title:lower()<b.title:lower()
    end)
    return groups
end

function E:Search(query, limit, mode, packID, includeDisabled)
    query=type(query)=="string" and query:lower() or ""
    limit=floor(number(limit,100,1,50000))
    local result, source={},includeDisabled and self.browseNames or self.names
    if mode=="hidden" then source=self.hiddenNames end
    local recentOrder={}
    if mode=="recent" then
        for i,name in ipairs(self.db.recent) do recentOrder[name]=i end
    end
    for _,entry in ipairs(source) do
        local included=not packID or (type(packID)=="table" and packID[entry.packID]) or entry.packID==packID
        if included and (mode=="hidden" or not self.db.hidden[entry.name]) and (mode~="favorites" or self.db.favorites[entry.name]) and
            (mode~="recent" or recentOrder[entry.name]) and entry.searchName:find(query,1,true) then
            result[#result+1]=entry; if mode~="recent" and #result>=limit then break end
        end
    end
    if mode=="recent" then
        table.sort(result,function(a,b) return recentOrder[a.name]<recentOrder[b.name] end)
        for i=#result,limit+1,-1 do result[i]=nil end
    end
    return result
end

function E:SetOption(key,value)
    if key=="enabled" or key=="animate" or key=="minimap" or key=="setupComplete" then
        if type(value)~="boolean" then return end
    elseif key=="size" then value=floor(number(value,self.db.size,12,40))
    elseif key=="animationFPS" then value=floor(number(value,self.db.animationFPS,5,60))
    elseif key=="minimapAngle" then value=number(value,self.db.minimapAngle,0,360)
    elseif key=="preferredGroup" then
        local known=false
        for _,pack in pairs(self.packs) do if pack.group==value then known=true; break end end
        if not known then return end
    elseif key=="channels" and type(value)=="table" then
        local channels={}
        for event in pairs(self.channelLabels) do channels[event]=boolean(value[event],self.db.channels[event]) end
        value=channels
    else return end
    self.db[key]=value
    if key=="preferredGroup" then self:RebuildCatalog() else self.revision=self.revision+1 end
    if self.Refresh then self:Refresh() elseif self.RefreshUI then self:RefreshUI() end
end

function E:SetPackEnabled(id,enabled)
    if not self.packs[id] or type(enabled)~="boolean" then return end
    self.db.packs[id]=enabled; self:RebuildCatalog()
    if self.Refresh then self:Refresh() elseif self.RefreshUI then self:RefreshUI() end
end

function E:SetGroupEnabled(id,enabled)
    if type(enabled)~="boolean" then return end
    local changed=false
    for _,packID in ipairs(self.packOrder) do
        if self.packs[packID].group==id then self.db.packs[packID]=enabled; changed=true end
    end
    if not changed then return end
    self:RebuildCatalog()
    if self.Refresh then self:Refresh() elseif self.RefreshUI then self:RefreshUI() end
end

function E:ToggleFavorite(name)
    if not self:GetEmote(name,true) then return false end
    self.db.favorites[name]=not self.db.favorites[name] or nil
    if self.RefreshUI then self:RefreshUI() end
    return self.db.favorites[name]==true
end

function E:Stats(name) return self.db.stats[name] or {sent=0,seen=0} end

function E:Record(names,kind,messageID)
    if kind~="sent" and kind~="seen" then return end
    if messageID~=nil then
        local id=kind..":"..tostring(messageID)
        if self.messageIDs[id] then return end
        self.messageCursor=self.messageCursor%256+1
        local old=self.messageRing[self.messageCursor]; if old then self.messageIDs[old]=nil end
        self.messageRing[self.messageCursor]=id; self.messageIDs[id]=true
    end
    for _,name in ipairs(names) do
        if self.catalog[name] then
            local stats=self.db.stats[name] or {sent=0,seen=0}; self.db.stats[name]=stats
            stats[kind]=min(2147483647,stats[kind]+1)
            if kind=="sent" then
                for i=#self.db.recent,1,-1 do if self.db.recent[i]==name then table.remove(self.db.recent,i) end end
                table.insert(self.db.recent,1,name); self.db.recent[101]=nil
            end
        end
    end
end
