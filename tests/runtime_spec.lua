-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local passed, failed = 0, 0
local function equal(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function test(name,body)
    local ok,err=pcall(body)
    if ok then passed=passed+1 else failed=failed+1; print("FAIL "..name..": "..err) end
end
local function pack(...) return {n=select("#",...),...} end
local function setup(saved)
    local world={frames={},filters={},callbacks={},tickers={},hooks={},time=0,after={},messages={}}
    local secret={}
    _G.issecretvalue=function(value) return value==secret end
    _G.canaccessvalue=function(value) return value~=secret end
    _G.GetTime=function() return world.time end
    _G.UnitGUID=function() return "Player-self" end
    _G.IsShiftKeyDown=function() return world.shift or false end
    _G.ForeverEmotesDB=saved; _G.Emoticons_Settings={MINIMAPBUTTON=false}; _G.TwitchEmoteStatistics={KEKW={"",2,3}}
    _G.DEFAULT_CHAT_FRAME={AddMessage=function(_,message) world.messages[#world.messages+1]=message end}
    _G.SlashCmdList={}
    _G.CreateFrame=function()
        local f={events={},scripts={}}
        function f:SetScript(event,fn) self.scripts[event]=fn end
        function f:RegisterEvent(event) self.events[event]=true end
        function f:UnregisterEvent(event) self.events[event]=nil end
        function f:Fire(event,...) if self.events[event] then self.scripts.OnEvent(self,event,...) end end
        world.frames[#world.frames+1]=f; return f
    end
    _G.C_Timer={After=function(_,fn) world.after[#world.after+1]=fn end,NewTicker=function(interval,fn)
        local ticker={interval=interval,fn=fn}
        function ticker:Cancel() self.cancelled=true end
        world.tickers[#world.tickers+1]=ticker; return ticker
    end}
    _G.ChatFrameUtil={
        AddMessageEventFilter=function(event,fn) world.filters[event]=fn end,
        ForEachChatFrame=function(fn) for _,f in ipairs(world.chats or {}) do fn(f) end end,
    }
    _G.hooksecurefunc=function(name,fn) world.hooks[name]=fn end
    _G.FCF_OpenTemporaryWindow=function() end
    _G.EventRegistry={RegisterCallback=function(_,name,fn,owner) world.callbacks[name]={fn=fn,owner=owner} end}
    _G.GameTooltip={SetOwner=function() end,AddLine=function() end,Show=function() world.tooltip=true end,Hide=function() world.tooltip=false end}
    local E={}
    for _,name in ipairs({"Core","Text","Animation","Runtime"}) do
        local chunk=assert(loadfile("TwitchEmotes/"..name..".lua")); chunk("TwitchEmotes",E)
    end
    E:RegisterPack({id="test",group="general",emotes={
        {name="KEKW",path="Interface\\AddOns\\TwitchEmotes\\Media\\kekw.tga",width=32,height=32,sheetWidth=32,sheetHeight=32,frames=1,fps=0},
        {name="catJAM",path="Interface\\AddOns\\TwitchEmotes\\Media\\cat.tga",width=32,height=32,sheetWidth=32,sheetHeight=128,frames=4,fps=10},
    }})
    function E:InitializeUI() world.ui=(world.ui or 0)+1 end
    function E:AttachCompletion(box) box.attached=true end
    function E:OpenPanel() world.open=true end
    function E:InsertEmote(name) world.inserted=name; return true end
    function E:RefreshUI() world.refreshed=true end
    world.eventFrame=world.frames[1]
    world.eventFrame:Fire("ADDON_LOADED","TwitchEmotes")
    world.eventFrame:Fire("PLAYER_LOGIN")
    world.migratedMinimap=E.db.minimap; world.migratedSent=E:Stats("KEKW").sent
    E.db.stats={}
    function world:Chat(text,guid,id,event)
        self.eventFrame:Fire(event or "CHAT_MSG_SAY",text,"Name","Common","",nil,nil,0,0,"",0,id,guid,0,false,nil,nil,nil,nil)
    end
    function world:Callback(event,...)
        local cb=assert(self.callbacks[event]); cb.fn(cb.owner,...)
    end
    function world:Line(text)
        local l={text=text,shown=true,writes=0}
        function l:GetText() return self.text end
        function l:SetText(value) self.text=value; self.writes=self.writes+1 end
        function l:IsShown() return self.shown end
        function l:IsForbidden() return self.forbidden or false end
        function l:CanBeAccessedInContext() return not self.forbidden end
        function l:HasAnyForbiddenAspects() return self.forbidden or false end
        return l
    end
    function world:ChatFrame(lines)
        local f={visibleLines=lines,scripts={},shown=true,editBox={}}
        function f:AddOnDisplayRefreshedCallback(fn) self.refresh=fn end
        function f:HookScript(event,fn) self.scripts[event]=fn end
        function f:IsShown() return self.shown end
        function f:IsForbidden() return false end
        return f
    end
    return E,world,secret
end

test("login initializes once and slash command opens picker",function()
    local E,w=setup(); equal(E.db,ForeverEmotesDB); equal(w.ui,1)
    w.eventFrame:Fire("PLAYER_LOGIN"); equal(w.ui,1)
    assert(w.filters.CHAT_MSG_SAY); SlashCmdList.FOREVEREMOTES(""); equal(w.open,true)
    equal(w.migratedMinimap,false); equal(w.migratedSent,2)
end)

test("status distinguishes missing saved data from loaded preferences before defaults",function()
    local E,w=setup()
    SlashCmdList.FOREVEREMOTES("status")
    assert(table.concat(w.messages,"\n"):find("Saved at load: nil",1,true))
    equal(w.open,nil,"status must not open the browser")
    local saved={schema=2,size=35,minimapAngle=125.5,setupComplete=true,packs={test=true}}
    E,w=setup(saved)
    local db=E.db
    SlashCmdList.FOREVEREMOTES("status")
    local report=table.concat(w.messages,"\n")
    assert(report:find("Saved at load: table",1,true)); assert(report:find("size=35",1,true))
    assert(report:find("angle=125.5",1,true)); equal(E.db,db); equal(ForeverEmotesDB,db)
    assert(db._startup[1]:find("size=35",1,true),"startup observations must survive the next native save")
end)
test("filter preserves every trailing argument and nil",function()
    local E,w=setup(); local result=pack(w.filters.CHAT_MSG_SAY({},"CHAT_MSG_SAY","KEKW","Alice",nil,"last",nil))
    equal(result.n,6); equal(result[1],false); assert(result[2]:find("|T",1,true))
    equal(result[3],"Alice"); equal(result[4],nil); equal(result[5],"last"); equal(result[6],nil)
end)
test("filter display in multiple windows never counts a message",function()
    local E,w=setup(); for i=1,4 do w.filters.CHAT_MSG_SAY({},"CHAT_MSG_SAY","KEKW") end
    equal(E:Stats("KEKW").seen,0); w:Chat("KEKW","Player-other",42)
    equal(E:Stats("KEKW").seen,1); w:Chat("KEKW","Player-other",42); equal(E:Stats("KEKW").seen,1)
end)
test("confirmed own echoes and outgoing whispers update sent history",function()
    local E,w=setup(); w:Chat("KEKW","Player-self",43)
    equal(E:Stats("KEKW").sent,1); equal(E.db.recent[1],"KEKW")
    w:Chat("catJAM",nil,44,"CHAT_MSG_WHISPER_INFORM"); equal(E:Stats("catJAM").sent,1)
    w:Chat("catJAM","Player-other",45); equal(E:Stats("catJAM").sent,1)
end)
test("restricted messages and GUIDs are never examined",function()
    local E,w,secret=setup(); local _,value=w.filters.CHAT_MSG_SAY({},"CHAT_MSG_SAY",secret)
    equal(value,secret); w:Chat(secret,secret,secret); equal(next(E.db.stats),nil)
    w:Chat("KEKW",secret,46); equal(E:Stats("KEKW").sent,0); equal(E:Stats("KEKW").seen,1)
end)
test("disabled channels preserve text and do not accumulate usage",function()
    local E,w=setup(); E:SetOption("channels",{CHAT_MSG_SAY=false})
    local _,text=w.filters.CHAT_MSG_SAY({},"CHAT_MSG_SAY","KEKW"); equal(text,"KEKW")
    w:Chat("KEKW","Player-self",47); equal(E:Stats("KEKW").seen,0)
end)
test("cache is bounded and settings invalidate rendered sizes",function()
    local E,w=setup()
    for i=1,500 do w.filters.CHAT_MSG_SAY({},"CHAT_MSG_SAY","KEKW "..i) end
    local count=0; for _ in pairs(E.messageCache) do count=count+1 end; assert(count<=128)
    E:SetOption("size",32); local _,text=w.filters.CHAT_MSG_SAY({},"CHAT_MSG_SAY","KEKW 500")
    assert(text:find("kekw.tga:32:32:",1,true))
end)
test("animation only schedules visible animated content and stops at idle",function()
    local E,w=setup(); equal(#w.tickers,0)
    local static=w:Line(E:Transform("KEKW")); local f=w:ChatFrame({static})
    E:AttachAnimation(f); f.refresh(f); equal(#w.tickers,0)
    local line=w:Line(E:Transform("catJAM")); f.visibleLines={line}; f.refresh(f)
    equal(#w.tickers,1); equal(w.tickers[1].interval,1/60)
    w.time=0.25; w.tickers[1].fn(); assert(line.text:find(":64:96|t",1,true))
    equal(E:Stats("catJAM").seen,0)
    line.text="recycled line"; w.tickers[1].fn(); equal(line.text,"recycled line"); equal(w.tickers[1].cancelled,true)
end)
test("hidden and forbidden lines stop without writes",function()
    local E,w,secret=setup(); local line=w:Line(E:Transform("catJAM")); local f=w:ChatFrame({line})
    E:AttachAnimation(f); f.refresh(f); local writes=line.writes
    line.forbidden=true; w.tickers[1].fn(); equal(line.writes,writes); equal(w.tickers[1].cancelled,true)
    line.forbidden=false; line.text=secret; f.refresh(f); equal(#w.tickers,1)
end)
test("disabling animation resets visible emotes and removes ticker",function()
    local E,w=setup(); local line=w:Line(E:Transform("catJAM")); local f=w:ChatFrame({line})
    E:AttachAnimation(f); f.refresh(f); w.time=0.25; w.tickers[1].fn()
    E:SetOption("animate",false); assert(line.text:find(":0:32|t",1,true)); equal(w.tickers[1].cancelled,true)
end)
test("new chat windows attach completion and display callbacks idempotently",function()
    local E,w=setup(); local f=w:ChatFrame({}); w.chats={f}
    w.eventFrame:Fire("UPDATE_CHAT_WINDOWS"); assert(f.refresh); equal(f.editBox.attached,true)
    local callback=f.refresh; w.eventFrame:Fire("UPDATE_CHAT_WINDOWS"); equal(callback,f.refresh)
end)
test("native hyperlink callbacks act only on owned links",function()
    local E,w=setup(); w.shift=true
    w:Callback("SetItemRef","item:1","", "LeftButton",{}); equal(w.inserted,nil)
    w:Callback("SetItemRef",E.linkPrefix.."4b454b57","", "LeftButton",{}); equal(w.inserted,"KEKW")
    local chat={}
    w:Callback("ChatFrame.OnHyperlinkEnter",chat,E.linkPrefix.."4b454b57"); equal(w.tooltip,true)
    w:Callback("ChatFrame.OnHyperlinkLeave",chat); equal(w.tooltip,false)
end)

test("escaped animation markup never creates an idle ticker",function()
    local E,w=setup(); local text="|"..E:Transform("catJAM")
    local line=w:Line(text); local f=w:ChatFrame({line}); E:AttachAnimation(f); f.refresh(f)
    equal(line.text,text); equal(#w.tickers,0)
end)

print(string.format("runtime: %d passed, %d failed",passed,failed))
os.exit(failed==0 and 0 or 1)
