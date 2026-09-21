-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local addonName, E = ...
local frame=CreateFrame("Frame")
local installed, tooltipOwner
local CACHE_LIMIT=128
local startupSettings={}

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
    if not own and not E:IsRestricted(guid) and type(guid)=="string" then
        local player=UnitGUID("player")
        if not E:IsRestricted(player) and player~=nil then own=guid==player end
    end
    if own then E:Record(names,"sent",lineID) end
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
    if ChatFrameUtil and ChatFrameUtil.ForEachChatFrame then ChatFrameUtil.ForEachChatFrame(attach)
    else for i=1,(NUM_CHAT_WINDOWS or 10) do if _G["ChatFrame"..i] then attach(_G["ChatFrame"..i]) end end end
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
        if addFilter then addFilter(event,filter) end
        frame:RegisterEvent(event)
    end
    E:InitializeUI()
    E:AttachChatWindows()
    installLinks()
    frame:RegisterEvent("UPDATE_CHAT_WINDOWS")
    frame:RegisterEvent("UPDATE_FLOATING_CHAT_WINDOWS")
    if type(_G.FCF_OpenTemporaryWindow)=="function" and hooksecurefunc then hooksecurefunc("FCF_OpenTemporaryWindow",function() E:AttachChatWindows() end) end
    _G.SLASH_FOREVEREMOTES1="/te"
    _G.SLASH_FOREVEREMOTES2="/twitch"
    SlashCmdList.FOREVEREMOTES=function(message)
        if type(message)=="string" and message:lower():match("^%s*status%s*$") then settingsStatus()
        else E:OpenPanel() end
    end
end

frame:SetScript("OnEvent",function(_,event,...)
    if event=="ADDON_LOADED" then
        local loaded=...
        if loaded~=addonName then return end
        startupSettings[#startupSettings+1]="Saved at load: "..describeSettings(_G.ForeverEmotesDB)
        _G.ForeverEmotesDB=E:InitializeDB(_G.ForeverEmotesDB,_G.Emoticons_Settings,_G.TwitchEmoteStatistics)
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
    elseif event=="UPDATE_CHAT_WINDOWS" or event=="UPDATE_FLOATING_CHAT_WINDOWS" then E:AttachChatWindows()
    else record(event,...) end
end)
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
