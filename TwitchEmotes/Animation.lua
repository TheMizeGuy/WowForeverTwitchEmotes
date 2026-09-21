-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local _, E = ...
local frames, active = {}, {}
local ticker, tickerFPS
local hoverFrame, hoverLine

function E:CanAccessObject(object)
    if self:IsRestricted(object) or object==nil then return false end
    for _,method in ipairs({"IsForbidden","HasAnyForbiddenAspects","CanBeAccessedInContext"}) do
        if object[method] then
            local value=object[method](object)
            if self:IsRestricted(value) then return false end
            if method=="CanBeAccessedInContext" then
                if not value then return false end
            elseif value then return false end
        end
    end
    return true
end

local function visible(object)
    if not E:CanAccessObject(object) then return false end
    if object.IsShown then local shown=object:IsShown(); if E:IsRestricted(shown) or not shown then return false end end
    return true
end

local function stopIfIdle()
    if not next(active) and ticker then ticker:Cancel(); ticker=nil end
end

function E:SetHoveredChatLine(frame, line)
    if not self:CanAccessObject(frame) or self:IsRestricted(line) then return end
    hoverFrame, hoverLine = frame, nil
    local lines = frame.visibleLines
    if not self:IsRestricted(lines) and type(lines)=="table" then
        for _, candidate in ipairs(lines) do
            if not self:IsRestricted(candidate) and candidate==line then hoverLine=line; break end
        end
    end
end

function E:ClearHoveredChatLine(frame)
    if not self:IsRestricted(frame) and frame==hoverFrame then hoverFrame,hoverLine=nil,nil end
end

local function tick()
    local now=GetTime()
    for line,record in pairs(active) do
        if not visible(record.frame) or not visible(line) then
            active[line]=nil
        else
            local text=line:GetText()
            if E:IsRestricted(text) or text~=record.last then
                active[line]=nil
            elseif record.frame~=hoverFrame or (hoverLine and line~=hoverLine) then
                -- Replacing this fontstring can invalidate its hovered hyperlink.
                -- Keep that line stable until the pointer leaves; other lines keep animating.
                local updated=E:AnimateText(record.source,now)
                if updated~=text then line:SetText(updated); record.last=updated end
            end
        end
    end
    stopIfIdle()
end

local function schedule()
    if ticker and tickerFPS~=E.db.animationFPS then ticker:Cancel(); ticker=nil end
    if next(active) and not ticker and C_Timer and C_Timer.NewTicker then
        tickerFPS=E.db.animationFPS
        ticker=C_Timer.NewTicker(1/tickerFPS,tick)
    end
    stopIfIdle()
end

local function clearFrame(frame)
    for line,record in pairs(active) do if record.frame==frame then active[line]=nil end end
end

local function scan(frame)
    clearFrame(frame)
    if not visible(frame) then stopIfIdle(); return end
    -- Forever's ScrollingMessageFrame publishes the visible fontstrings here.
    -- Read only the current display; never rewrite its history buffer.
    local lines=frame.visibleLines
    if E:IsRestricted(lines) or type(lines)~="table" then stopIfIdle(); return end
    for _,line in ipairs(lines) do
        if visible(line) and line.GetText and line.SetText then
            local text=line:GetText()
            if not E:IsRestricted(text) and type(text)=="string" and text:find("|Haddon:ForeverEmotes:",1,true) then
                local updated,animated=E:AnimateText(text,E.db.animate and GetTime() or nil)
                if updated~=text then line:SetText(updated) end
                if E.db.enabled and E.db.animate and animated then active[line]={frame=frame,source=text,last=updated} end
            end
        end
    end
    schedule()
end

function E:AttachAnimation(frame)
    if not self:CanAccessObject(frame) or frames[frame] or not frame.AddOnDisplayRefreshedCallback then return end
    frames[frame]=true
    frame:AddOnDisplayRefreshedCallback(scan)
    if frame.HookScript then
        frame:HookScript("OnHide",function() E:ClearHoveredChatLine(frame); clearFrame(frame); stopIfIdle() end)
        frame:HookScript("OnShow",function() scan(frame) end)
    end
    scan(frame)
end

function E:RefreshAnimation()
    for frame in pairs(frames) do
        scan(frame)
        if self:CanAccessObject(frame) and frame.MarkDisplayDirty then frame:MarkDisplayDirty() end
    end
    schedule()
end
