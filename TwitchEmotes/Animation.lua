-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local _, E = ...
local find, sub, byte, floor = string.find, string.sub, string.byte, math.floor
local frames, active = {}, {}
local ticker, tickerFPS
local hoverFrame, hoverLine
local ACCESS = {"IsForbidden","HasAnyForbiddenAspects","CanBeAccessedInContext"}
local LINK = "|Haddon:ForeverEmotes:"

function E:CanAccessObject(object)
    if self:IsRestricted(object) or object==nil then return false end
    for i=1,3 do
        local method=ACCESS[i]
        if object[method] then
            local value=object[method](object)
            if self:IsRestricted(value) then return false end
            if i==3 then
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

local function animatedEntries(text)
    local entries,pos={},1
    while true do
        local start=find(text,LINK,pos,true)
        local close=start and find(text,"|h",start+#LINK,true)
        if not close then return entries end
        local name=E:NameFromLink(sub(text,start+2,close-1))
        local entry=name and E.catalog[name]
        if entry and entry.frames>1 then entries[#entries+1]=entry end
        pos=close+2
    end
end

-- The earliest time any entry shows another cell, mirroring E:Render's frame index.
local function nextChange(entries,now)
    local soonest
    for i=1,#entries do
        local entry=entries[i]
        local fps,sequence=entry.fps,entry.sequence
        local step=floor(now*fps)+1
        if sequence then
            -- Deduplicated frames repeat a cell, which leaves the picture unchanged.
            local length=#sequence
            local cell=byte(sequence,(step-1)%length+1)
            for _=2,length do
                if byte(sequence,step%length+1)~=cell then break end
                step=step+1
            end
        end
        if not soonest or step/fps<soonest then soonest=step/fps end
    end
    return soonest or now
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
    for frame,lines in pairs(active) do
        if visible(frame) then
            for line,record in pairs(lines) do
                if not visible(line) then
                    lines[line]=nil
                else
                    local text=line:GetText()
                    if E:IsRestricted(text) or text~=record.last then
                        lines[line]=nil
                    elseif now>=record.next and (frame~=hoverFrame or (hoverLine and line~=hoverLine)) then
                        -- Replacing this fontstring can invalidate its hovered hyperlink.
                        -- Keep that line stable until the pointer leaves; other lines keep animating.
                        local updated=E:AnimateText(record.source,now)
                        if updated~=text then line:SetText(updated); record.last=updated end
                        record.next=nextChange(record.entries,now)
                    end
                end
            end
            if not next(lines) then active[frame]=nil end
        else
            active[frame]=nil
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

local function scan(frame)
    active[frame]=nil
    if not visible(frame) then stopIfIdle(); return end
    -- Forever's ScrollingMessageFrame publishes the visible fontstrings here.
    -- Read only the current display; never rewrite its history buffer.
    local lines=frame.visibleLines
    if E:IsRestricted(lines) or type(lines)~="table" then stopIfIdle(); return end
    local now,records=GetTime(),nil
    for _,line in ipairs(lines) do
        if visible(line) and line.GetText and line.SetText then
            local text=line:GetText()
            if not E:IsRestricted(text) and type(text)=="string" and find(text,LINK,1,true) then
                local entries=E.db.enabled and E.db.animate and animatedEntries(text)
                local updated,animated=E:AnimateText(text,entries and now or nil)
                if updated~=text then line:SetText(updated) end
                if entries and animated then
                    records=records or {}
                    records[line]={source=text,last=updated,entries=entries,next=nextChange(entries,now)}
                end
            end
        end
    end
    active[frame]=records
    schedule()
end

function E:AttachAnimation(frame)
    if not self:CanAccessObject(frame) or frames[frame] or not frame.AddOnDisplayRefreshedCallback then return end
    frames[frame]=true
    frame:AddOnDisplayRefreshedCallback(scan)
    if frame.HookScript then
        frame:HookScript("OnHide",function() E:ClearHoveredChatLine(frame); active[frame]=nil; stopIfIdle() end)
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
