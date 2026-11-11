-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local addonName, E = ...
local frame=CreateFrame("Frame")
local installed, tooltipOwner
local CACHE_LIMIT=128
local startupSettings={}
local worldEntered, loading, pending, onboarded

local function describeSettings(saved)
    if type(saved)~="table" then return type(saved) end
    local enabled=0
    for _,value in pairs(type(saved.packs)=="table" and saved.packs or {}) do if value==true then enabled=enabled+1 end end
    return string.format("table; size=%s; angle=%s; enabled packs=%d; setup=%s",
        tostring(saved.size),tostring(saved.minimapAngle),enabled,tostring(saved.setupComplete))
end

local function settingsStatus()
    local function line(text)
        if _G.DEFAULT_CHAT_FRAME then _G.DEFAULT_CHAT_FRAME:AddMessage("Twitch Emotes: "..text)
        else print("Twitch Emotes: "..text) end
    end
    for _,text in ipairs(startupSettings) do line(text) end
    line("Current: "..describeSettings(E.db).."; saved table matches="..tostring(E.db==_G.ForeverEmotesDB))
end

local function clearCache()
    E.messageCache, E.cacheKeys, E.cacheCursor, E.cacheRevision = {}, {}, 0, E.revision
end

local function transform(text)
    if E:IsRestricted(text) or type(text)~="string" then return text,{},false end
    if E.cacheRevision~=E.revision then clearCache() end
    local cached=E.messageCache[text]
    if cached then return cached.text,cached.names,cached.animated end
    local result,names,animated=E:Transform(text)
    if #text<=8192 then
        E.cacheCursor=E.cacheCursor%CACHE_LIMIT+1
        local old=E.cacheKeys[E.cacheCursor]; if old then E.messageCache[old]=nil end
        E.cacheKeys[E.cacheCursor]=text
        E.messageCache[text]={text=result,names=names,animated=animated}
    end
    return result,names,animated
end

local function filter(_,event,text,...)
    if not E.db.enabled or E.db.channels[event]==false then return false,text,... end
    local result=transform(text)
    return false,result,...
end

local function record(event,text,...)
    if not E.db.enabled or E.db.channels[event]==false or E:IsRestricted(text) or type(text)~="string" then return end
    local _,names=transform(text)
    if #names==0 then return end
    local lineID,guid=select(10,...),select(11,...)
    if E:IsRestricted(lineID) or (type(lineID)~="number" and type(lineID)~="string") then lineID=nil end
    -- One event frame counts reception once, independently of display filters.
    E:Record(names,"seen",lineID)
    local own=event=="CHAT_MSG_WHISPER_INFORM" or event=="CHAT_MSG_BN_WHISPER_INFORM"
    -- A whisper to yourself also arrives as an incoming whisper; its INFORM echo already counted it.
    local incoming=event=="CHAT_MSG_WHISPER" or event=="CHAT_MSG_BN_WHISPER"
    if not own and not incoming and not E:IsRestricted(guid) and type(guid)=="string" then
        local player=UnitGUID("player")
        if not E:IsRestricted(player) and player~=nil then own=guid==player end
    end
    if own then E:Record(names,"sent",lineID) end
end

local function eachChatFrame(fn)
    if ChatFrameUtil and ChatFrameUtil.ForEachChatFrame then ChatFrameUtil.ForEachChatFrame(fn)
    else for i=1,(NUM_CHAT_WINDOWS or 10) do if _G["ChatFrame"..i] then fn(_G["ChatFrame"..i]) end end end
end

function E:IsEventSupported(event)
    local events=_G.C_EventUtils
    return not (events and events.IsEventValid) or events.IsEventValid(event)
end

function E:AttachChatWindows()
    local function attach(chat)
        if not self:CanAccessObject(chat) then return end
        self:AttachAnimation(chat)
        local editBox=chat.editBox
        if not editBox and chat.GetName then
            local name=chat:GetName()
            if not self:IsRestricted(name) and type(name)=="string" then editBox=_G[name.."EditBox"] end
        end
        if editBox then self:AttachCompletion(editBox) end
    end
    eachChatFrame(attach)
end

function E:Refresh()
    clearCache()
    if self.RefreshAnimation then self:RefreshAnimation() end
    if self.RefreshUI then self:RefreshUI() end
end

local function ownedEntry(link)
    if E:IsRestricted(link) then return nil end
    local name=E:NameFromLink(link)
    return name and E:GetEmote(name)
end

-- Blizzard rebuilds a revealed censored line from C_ChatInfo.GetChatLineText without running message filters.
local function revealCensored(link)
    if E:IsRestricted(link) or type(link)~="string" or not E.db.enabled then return end
    local lineID=tonumber(link:match("^censoredmessage:(%d+)"))
    local report=_G.CENSORED_MESSAGE_REPORT
    if not lineID or type(report)~="string" or not (C_ChatInfo and C_ChatInfo.GetChatLineText) then return end
    local text,names=transform(C_ChatInfo.GetChatLineText(lineID))
    if #names==0 then return end
    local shown
    local function matches(_,_,_,_,_,_,_,event,eventArgs)
        -- lineID is never secret; a secret sender marks a line received during chat messaging lockdown.
        if type(eventArgs)~="table" or E:IsRestricted(event) or E:IsRestricted(eventArgs[11]) or E:IsRestricted(eventArgs[2]) then return false end
        return eventArgs[11]==lineID and E.db.channels[event]~=false
    end
    local function rebuild(message,r,g,b,infoID,accessID,typeID,event,eventArgs,formatter,...)
        if type(formatter)~="function" then return message,r,g,b,infoID,accessID,typeID,event,eventArgs,formatter,... end
        shown=true
        return report:format(formatter(text),lineID),r,g,b,infoID,accessID,typeID,event,eventArgs,formatter,...
    end
    eachChatFrame(function(chat)
        if chat.TransformMessages and E:CanAccessObject(chat) then chat:TransformMessages(matches,rebuild) end
    end)
    if shown then E:Record(names,"seen",lineID) end
end

local function installLinks()
    if not EventRegistry then return end
    EventRegistry:RegisterCallback("SetItemRef",function(_,link,_,button)
        local entry=ownedEntry(link)
        if not entry or E:IsRestricted(button) then return end
        if button=="LeftButton" and IsShiftKeyDown() then E:InsertEmote(entry.name)
        elseif button=="LeftButton" or button=="RightButton" then E:OpenEmoteMenu(entry.name) end
    end,E)
    EventRegistry:RegisterCallback("ChatFrame.OnHyperlinkEnter",function(_,chat,link,_,region)
        E:SetHoveredChatLine(chat,region)
        local entry=ownedEntry(link)
        if not entry or not GameTooltip or not E:CanAccessObject(chat) then return end
        tooltipOwner=chat
        GameTooltip:SetOwner(chat,"ANCHOR_CURSOR")
        GameTooltip:AddLine(entry.name,1,1,1)
        local pack=E.packs[entry.packID]
        if pack then GameTooltip:AddLine(pack.title.." · "..pack.provider,0.7,0.7,0.7) end
        if entry.creator~="" then GameTooltip:AddLine("Source credit: "..entry.creator,0.7,0.7,0.7) end
        GameTooltip:AddLine("Click for options · Shift-click to insert",0.7,0.7,0.7)
        GameTooltip:Show()
    end,E)
    EventRegistry:RegisterCallback("ChatFrame.OnHyperlinkLeave",function(_,chat)
        E:ClearHoveredChatLine(chat)
        if tooltipOwner and not E:IsRestricted(chat) and chat==tooltipOwner then
            if not GameTooltip.GetOwner or GameTooltip:GetOwner()==chat then GameTooltip:Hide() end
            tooltipOwner=nil
        end
    end,E)
end

local function login()
    if installed then return end
    installed=true
    local addFilter=ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter or _G.ChatFrame_AddMessageEventFilter
    for event in pairs(E.channelLabels) do
        -- RegisterEvent raises on an event the running client does not define.
        if E:IsEventSupported(event) then
            if addFilter then addFilter(event,filter) end
            frame:RegisterEvent(event)
        end
    end
    E:AttachChatWindows()
    installLinks()
    frame:RegisterEvent("UPDATE_CHAT_WINDOWS")
    frame:RegisterEvent("UPDATE_FLOATING_CHAT_WINDOWS")
    if type(_G.FCF_OpenTemporaryWindow)=="function" and hooksecurefunc then hooksecurefunc("FCF_OpenTemporaryWindow",function() E:AttachChatWindows() end) end
    if type(_G.SetItemRef)=="function" and hooksecurefunc then hooksecurefunc("SetItemRef",revealCensored) end
    _G.SLASH_FOREVEREMOTES1="/te"
    _G.SLASH_FOREVEREMOTES2="/twitch"
    SlashCmdList.FOREVEREMOTES=function(message)
        if type(message)=="string" and message:lower():match("^%s*status%s*$") then settingsStatus()
        else E:OpenPanel() end
    end
    -- Last, so a UI fault cannot disable chat rendering, links or the slash command; its error still propagates.
    E:InitializeUI()
end

-- Cinematics, Alt-Z, the interface's return and death all close special windows, and dialogs sit beneath the panel.
local function busy()
    local dead,popup=UnitIsDeadOrGhost("player"),_G.StaticPopup_IsAnyDialogShown
    return not UIParent:IsVisible() or (not E:IsRestricted(dead) and dead) or (popup~=nil and popup())
end

local function settle()
    onboarded=true
    for _,event in ipairs({"LOADING_SCREEN_ENABLED","LOADING_SCREEN_DISABLED","PLAYER_REGEN_ENABLED"}) do
        if E:IsEventSupported(event) then frame:UnregisterEvent(event) end
    end
end

local onboard
-- Every world entry closes special windows, so the first-run picker waits for each loading screen to lift, then a moment more.
local function armOnboarding()
    if onboarded or pending or loading or not worldEntered then return end
    if E.db.setupComplete then settle(); return end
    pending=true; C_Timer.After(2,onboard)
end

function onboard()
    pending=false
    if onboarded or E.db.setupComplete then settle(); return end
    if loading then return end
    if InCombatLockdown() then frame:RegisterEvent("PLAYER_REGEN_ENABLED"); return end
    if busy() then pending=true; C_Timer.After(2,onboard); return end
    settle()
    if E.OpenFirstRun then E:OpenFirstRun() end
end

frame:SetScript("OnEvent",function(_,event,...)
    if event=="ADDON_LOADED" then
        local loaded=...
        if loaded~=addonName then return end
        startupSettings[#startupSettings+1]="Saved at load: "..describeSettings(_G.ForeverEmotesDB)
        _G.ForeverEmotesDB=E:InitializeDB(_G.ForeverEmotesDB)
        _G.ForeverEmotesDB._startup=startupSettings
        E:PrepareSetup()
        E:RebuildCatalog(); clearCache()
        frame:UnregisterEvent("ADDON_LOADED")
    elseif event=="PLAYER_LOGIN" then
        startupSettings[#startupSettings+1]="At login: "..describeSettings(_G.ForeverEmotesDB).."; saved table matches="..tostring(E.db==_G.ForeverEmotesDB)
        login()
    elseif event=="PLAYER_ENTERING_WORLD" then
        frame:UnregisterEvent("PLAYER_ENTERING_WORLD")
        -- Sample settings after the other world-entry handlers finish.
        C_Timer.After(0,function()
            startupSettings[#startupSettings+1]="After world entry: "..describeSettings(_G.ForeverEmotesDB).."; saved table matches="..tostring(E.db==_G.ForeverEmotesDB)
            if type(_G.ForeverEmotesDB)=="table" then _G.ForeverEmotesDB._startup=startupSettings end
        end)
        worldEntered=true; armOnboarding()
    elseif event=="LOADING_SCREEN_ENABLED" then loading=true
    elseif event=="LOADING_SCREEN_DISABLED" then loading=false; armOnboarding()
    elseif event=="PLAYER_REGEN_ENABLED" then frame:UnregisterEvent("PLAYER_REGEN_ENABLED"); armOnboarding()
    elseif event=="UPDATE_CHAT_WINDOWS" or event=="UPDATE_FLOATING_CHAT_WINDOWS" then E:AttachChatWindows()
    else record(event,...) end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
if E:IsEventSupported("LOADING_SCREEN_DISABLED") then
    loading=true; frame:RegisterEvent("LOADING_SCREEN_DISABLED")
    if E:IsEventSupported("LOADING_SCREEN_ENABLED") then frame:RegisterEvent("LOADING_SCREEN_ENABLED") end
end
