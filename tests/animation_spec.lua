-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
-- The interpreter must not sink the allocations the garbage checks measure.
if jit then jit.off() end
local passed, failed = 0, 0
local function equal(a,b,message) assert(a==b,(message and message..": " or "")..tostring(a).." ~= "..tostring(b)) end
local function test(name,body)
    local ok,err=pcall(body)
    if ok then passed=passed+1 else failed=failed+1; print("FAIL "..name..": "..tostring(err)) end
end
local ANIMATION=os.getenv("TE_ANIMATION") or "TwitchEmotes/Animation.lua"
local MEDIA="Interface\\AddOns\\TwitchEmotes\\Media\\"

local function setup()
    local world={time=0,tickers={}}
    local secret={}
    world.secret=secret
    _G.issecretvalue=function(value) return value==secret end
    _G.canaccessvalue=function(value) return value~=secret end
    _G.GetTime=function() return world.time end
    _G.C_Timer={NewTicker=function(interval,fn)
        local ticker={interval=interval,fn=fn}
        function ticker:Cancel() self.cancelled=true end
        world.tickers[#world.tickers+1]=ticker; return ticker
    end}
    local E={}
    for _,path in ipairs({"TwitchEmotes/Core.lua","TwitchEmotes/Text.lua",ANIMATION}) do assert(loadfile(path))("TwitchEmotes",E) end
    E:RegisterPack({id="test",group="general",emotes={
        {name="KEKW",path=MEDIA.."kekw.tga",width=32,height=32,sheetWidth=32,sheetHeight=32,frames=1,fps=0},
        {name="catJAM",path=MEDIA.."cat.tga",width=32,height=32,sheetWidth=32,sheetHeight=128,frames=4,fps=10},
        {name="slowJAM",path=MEDIA.."slow.tga",width=32,height=32,sheetWidth=32,sheetHeight=128,frames=4,fps=4},
        {name="W",path=MEDIA.."w.tga",width=32,height=32,sheetWidth=256,sheetHeight=32,frames=8,fps=20,columns=8,cellWidth=32},
        {name="seqJAM",path=MEDIA.."seq.blp",width=32,height=32,sheetWidth=32,sheetHeight=128,frames=3,fps=10,sequence="\0\0\0\1\1\2"},
    }})
    E:InitializeDB(); E:RebuildCatalog()
    -- Runtime.lua's E:Refresh, which Core's SetOption calls after every change.
    function E:Refresh() self:RefreshAnimation() end

    function world:Tick(now)
        self.time=now
        for _,ticker in ipairs(self.tickers) do if not ticker.cancelled then ticker.fn() end end
    end
    function world:Live()
        local count,last=0,nil
        for _,ticker in ipairs(self.tickers) do if not ticker.cancelled then count=count+1; last=ticker end end
        return count,last
    end
    function world:Line()
        local l={shown=false,writes=0,bottom=0}
        function l:GetText() return self.text end
        function l:SetText(value) self.text=value; self.writes=self.writes+1 end
        function l:IsShown() return self.shown end
        function l:IsVisible() return self.shown end
        function l:IsMouseOver() return self.mouseOver or false end
        function l:GetBottom() return self.bottom end
        function l:IsForbidden() return false end
        return l
    end
    -- ScrollingMessageFrame: history index 1 is the newest message, visibleLines[1] the bottom slot,
    -- and each slot sits on top of the one below it inside a container that spans the frame.
    function world:ChatFrame(slots,height)
        local f={history={},offset=0,scripts={},shown=true,height=height or 140,lineHeight=14,visibleLines={},callbacks={},calls={IsShown=0,GetTop=0}}
        for i=1,slots do f.visibleLines[i]=world:Line() end
        f.FontStringContainer={}
        function f.FontStringContainer:GetTop() f.calls.GetTop=f.calls.GetTop+1; if f.top~=nil then return f.top end; return f.height end
        function f:AddOnDisplayRefreshedCallback(fn) self.callbacks[#self.callbacks+1]=fn end
        function f:HookScript(event,fn)
            local before=self.scripts[event]
            self.scripts[event]=function(frame,...) if before then before(frame,...) end; fn(frame,...) end
        end
        function f:IsShown() self.calls.IsShown=self.calls.IsShown+1; return self.shown end
        function f:IsVisible() return self.shown end
        function f:IsForbidden() return false end
        function f:Show() if not self.shown then self.shown=true; if self.scripts.OnShow then self.scripts.OnShow(self) end end end
        function f:Hide() if self.shown then self.shown=false; if self.scripts.OnHide then self.scripts.OnHide(self) end end end
        -- rows is how many wrapped lines the message fills; Transform's extra results are ignored.
        function f:AddMessage(text,rows)
            table.insert(self.history,1,{message=text,rows=type(rows)=="number" and rows or 1})
            if self.offset~=0 then self.offset=self.offset+1 end
            self:MarkDisplayDirty()
        end
        function f:MarkDisplayDirty() self.displayDirty=true end
        function f:MarkLayoutDirty() self.layoutDirty=true end
        -- OnUpdate's RefreshIfNecessary.
        function f:Update()
            if self.layoutDirty then self:RefreshLayout() end
            if self.displayDirty then self:RefreshDisplay() end
        end
        -- The pool releases every fontstring and hands them back in another order.
        function f:RefreshLayout()
            self.layoutDirty=false
            local old,lines=self.visibleLines,{}
            for i=1,#old do local line=old[#old+1-i]; line.text=nil; line.shown=false; lines[i]=line end
            self.visibleLines=lines; self:MarkDisplayDirty()
        end
        -- Blizzard rewrites every slot from history (its own SetText, not counted as an addon write), then calls back.
        function f:RefreshDisplay()
            local y=0
            for index,line in ipairs(self.visibleLines) do
                local info=self.history[index+self.offset]
                line.bottom=y
                if info then line.text=info.message; line.shown=true; y=y+info.rows*self.lineHeight
                else line.text=nil; line.shown=false; y=y+self.lineHeight end
            end
            self.displayDirty=false
            for _,fn in ipairs(self.callbacks) do fn(self) end
        end
        return f
    end
    function world:Attached(slots,height)
        local f=self:ChatFrame(slots,height); E:AttachAnimation(f); return f
    end
    return E,world
end

local function counting(E)
    local animate=E.AnimateText
    local calls={n=0,render=function(text,now) return (animate(E,text,now)) end}
    E.AnimateText=function(self,...) calls.n=calls.n+1; return animate(self,...) end
    return calls
end

test("a display refresh animates every slot from its own history message",function()
    local E,w=setup(); local f=w:Attached(4)
    f:AddMessage(E:Transform("catJAM")); f:Update(); equal(w:Live(),1)
    w.time=0.05; f:AddMessage(E:Transform("KEKW and catJAM")); f:Update()
    w:Tick(0.25)
    for slot=1,2 do
        local message=f.history[slot].message
        equal(f.visibleLines[slot].text,(E:AnimateText(message,0.25)),"slot "..slot)
        assert(f.visibleLines[slot].text~=message,"slot "..slot.." must leave frame 0")
    end
    f:MarkLayoutDirty(); f:Update()
    w:Tick(0.45)
    for slot=1,4 do
        local info=f.history[slot]
        equal(f.visibleLines[slot].text,info and (E:AnimateText(info.message,0.45)) or nil,"recycled slot "..slot)
    end
end)

test("hiding the chat frame cancels the ticker and showing it rescans",function()
    local E,w=setup(); local f=w:Attached(4)
    f:AddMessage(E:Transform("catJAM")); f:Update(); equal(w:Live(),1)
    local line=f.visibleLines[1]
    f:Hide(); equal(w:Live(),0)
    local writes=line.writes; w:Tick(0.25); equal(line.writes,writes)
    f:Show(); equal(w:Live(),1); equal(line.text,(E:AnimateText(f.history[1].message,0.25)))
    w:Tick(0.35); equal(line.text,(E:AnimateText(f.history[1].message,0.35)))
end)

test("changing the animation rate replaces the ticker",function()
    local E,w=setup(); local f=w:Attached(4)
    f:AddMessage(E:Transform("catJAM")); f:Update()
    local count,old=w:Live(); equal(count,1); equal(old.interval,1/60)
    E:SetOption("animationFPS",30)
    local now,current=w:Live(); equal(now,1); equal(current.interval,1/30); equal(old.cancelled,true)
end)

test("ticks between frame steps neither re-render nor write",function()
    local E,w=setup(); local f=w:Attached(4)
    w.time=0.01; f:AddMessage(E:Transform("catJAM")); f:Update()
    local line,calls=f.visibleLines[1],counting(E)
    w:Tick(0.05); equal(calls.n,0,"render before the first step"); equal(line.writes,0)
    w:Tick(0.25); equal(calls.n,1); equal(line.writes,1); assert(line.text:find(":64:96|t",1,true))
    w:Tick(0.26); equal(calls.n,1,"render inside one step"); equal(line.writes,1)
    w:Tick(0.31); equal(calls.n,2); equal(line.writes,2); assert(line.text:find(":96:128|t",1,true))
end)

test("the fastest emote on a line decides its next render",function()
    local E,w=setup(); local f=w:Attached(4)
    w.time=0.01; f:AddMessage(E:Transform("slowJAM catJAM")); f:Update()
    local line=f.visibleLines[1]
    w:Tick(0.15); equal(line.writes,1,"catJAM steps at 0.1 although slowJAM waits until 0.25")
    w:Tick(0.27); equal(line.writes,2)
    equal(line.text,(E:AnimateText(f.history[1].message,0.27)))
end)

test("repeated sequence cells wait for the next distinct cell",function()
    local E,w=setup(); local f=w:Attached(4)
    w.time=0.01; f:AddMessage(E:Transform("seqJAM")); f:Update()
    local line,calls=f.visibleLines[1],counting(E)
    w:Tick(0.15); w:Tick(0.25); equal(calls.n,0,"cell 0 repeats until step 3"); equal(line.writes,0)
    w:Tick(0.31); equal(calls.n,1); equal(line.writes,1); assert(line.text:find(":32:64|t",1,true))
    w:Tick(0.45); equal(calls.n,1,"cell 1 repeats until step 5")
    w:Tick(0.51); equal(calls.n,2); assert(line.text:find(":64:96|t",1,true))
    w:Tick(0.61); equal(calls.n,3); assert(line.text:find(":0:32|t",1,true))
end)

test("skipped ticks never leave a visible frame behind",function()
    local E,w=setup(); local f=w:Attached(4)
    w.time=0.004; f:AddMessage(E:Transform("seqJAM catJAM slowJAM")); f:AddMessage(E:Transform("W KEKW seqJAM")); f:Update()
    local calls,changes=counting(E),0
    local shown={f.visibleLines[1].text,f.visibleLines[2].text}
    for i=1,240 do
        local now=0.004+i/60; w:Tick(now)
        for slot=1,2 do
            local line=f.visibleLines[slot]
            equal(line.text,calls.render(f.history[slot].message,now),string.format("slot %d at %.4f",slot,now))
            if line.text~=shown[slot] then changes=changes+1; shown[slot]=line.text end
        end
    end
    equal(calls.n,changes,"every render changes the picture")
end)

test("a line rewritten by another addon stops animating on the next tick",function()
    local E,w=setup(); local f=w:Attached(4)
    w.time=0.01; f:AddMessage(E:Transform("catJAM")); f:Update()
    local line=f.visibleLines[1]; line.text="recycled line"
    w:Tick(0.02); equal(line.text,"recycled line"); equal(w:Live(),0)
end)

test("access checks allocate nothing",function()
    local E,w=setup(); local line=w:Line()
    collectgarbage("collect"); collectgarbage("stop")
    local before=collectgarbage("count")
    for _=1,1000 do E:CanAccessObject(line) end
    local grown=(collectgarbage("count")-before)*1024
    collectgarbage("restart")
    assert(grown<1024,string.format("1000 access checks allocated %.0f bytes",grown))
end)

test("each tick checks a chat frame once, not once per line",function()
    local E,w=setup(); local f=w:Attached(6)
    for i=1,6 do f:AddMessage(E:Transform("catJAM "..i)) end
    f:Update(); equal(w:Live(),1)
    f.calls.IsShown,f.calls.GetTop=0,0
    w:Tick(0.15)
    equal(f.calls.IsShown,1,"frame IsShown per tick"); equal(f.calls.GetTop,1,"container GetTop per tick")
    for slot=1,6 do equal(f.visibleLines[slot].writes,1,"slot "..slot) end
end)

test("a line with more than 16 emotes shows still frames and never ticks",function()
    local E,w=setup(); local f=w:Attached(4)
    w.time=0.3
    local crowded=E:AnimateText(E:Transform(("W "):rep(128)),0.3)
    f:AddMessage(crowded); f:Update()
    local line=f.visibleLines[1]
    equal(w:Live(),0); equal(line.text,(E:AnimateText(crowded,nil)),"crowded line returns to frame 0")
    local _,links=line.text:gsub("|Haddon:ForeverEmotes:",""); equal(links,128)
    local writes=line.writes; w:Tick(0.6); equal(line.writes,writes)
    f:AddMessage(E:Transform(("W "):rep(17))); f:Update(); equal(w:Live(),0)
    f:AddMessage(E:Transform(("W "):rep(16))); f:Update(); equal(w:Live(),1)
    f:AddMessage(E:Transform("W catJAM W")); f:Update(); equal(w:Live(),1)
    local slots={}; for slot=1,4 do slots[slot]=f.visibleLines[slot].writes end
    w:Tick(0.92)
    equal(f.visibleLines[1].writes,slots[1]+1,"three emotes animate"); equal(f.visibleLines[2].writes,slots[2]+1,"sixteen emotes animate")
    equal(f.visibleLines[3].writes,slots[3],"seventeen emotes stay still"); equal(f.visibleLines[4].writes,slots[4],"128 emotes stay still")
end)

test("slots above the clipped container neither animate nor start the ticker",function()
    local E,w=setup(); local f=w:Attached(2,28)
    f:AddMessage(E:Transform("catJAM")); f:AddMessage(E:Transform("KEKW"),2); f:Update()
    local above=f.visibleLines[2]
    equal(above.bottom,28); equal(above.shown,true); equal(w:Live(),0)
    f=w:Attached(2,28)
    f:AddMessage(E:Transform("catJAM")); f:AddMessage(E:Transform("catJAM"),2); f:Update()
    local below; below,above=f.visibleLines[1],f.visibleLines[2]
    equal(above.bottom,28); equal(w:Live(),1)
    w:Tick(0.15); equal(below.writes,1); equal(above.writes,0)
    below.bottom=40; w:Tick(0.25); equal(below.writes,1); equal(w:Live(),0)
end)

test("unreadable geometry never hides a line",function()
    local E,w=setup(); local f=w:Attached(2,28)
    f.top=w.secret; f:AddMessage(E:Transform("catJAM")); f:AddMessage(E:Transform("KEKW"),2); f:Update()
    local line=f.visibleLines[2]; equal(line.bottom,28); equal(w:Live(),1)
    w:Tick(0.15); equal(line.writes,1)
    f.top=nil; line.bottom=w.secret; w:Tick(0.25); equal(line.writes,2)
    f.top=false; line.bottom=40; w:Tick(0.35); equal(line.writes,3)
end)

test("hovering one line freezes only that line",function()
    local E,w=setup(); local f=w:Attached(4)
    f:AddMessage(E:Transform("catJAM")); f:AddMessage(E:Transform("catJAM")); f:Update()
    local hovered,other=f.visibleLines[1],f.visibleLines[2]
    E:SetHoveredChatLine(f,hovered)
    w:Tick(0.15); equal(hovered.writes,0); equal(other.writes,1)
    E:ClearHoveredChatLine(f)
    w:Tick(0.16); equal(hovered.writes,1); equal(other.writes,1)
end)

test("hiding one of two chat frames keeps the other animating",function()
    local E,w=setup(); local first,second=w:Attached(4),w:Attached(4)
    first:AddMessage(E:Transform("catJAM")); first:Update(); second:AddMessage(E:Transform("catJAM")); second:Update()
    equal(w:Live(),1)
    first:Hide(); equal(w:Live(),1)
    w:Tick(0.15); equal(first.visibleLines[1].writes,0); equal(second.visibleLines[1].writes,1)
    second:Hide(); equal(w:Live(),0)
end)

print(string.format("animation: %d passed, %d failed",passed,failed))
os.exit(failed==0 and 0 or 1)
