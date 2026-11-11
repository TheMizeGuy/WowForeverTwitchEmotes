-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local passed, failed = 0, 0
local function equal(a,b) assert(a==b,tostring(a).." ~= "..tostring(b)) end
local function test(name,body)
    local ok,err=pcall(body)
    if ok then passed=passed+1 else failed=failed+1; print("FAIL "..name..": "..err) end
end
local function pack(...) return {n=select("#",...),...} end
local LIFECYCLE={ADDON_LOADED=true,PLAYER_LOGIN=true,PLAYER_ENTERING_WORLD=true,UPDATE_CHAT_WINDOWS=true,UPDATE_FLOATING_CHAT_WINDOWS=true,
    LOADING_SCREEN_DISABLED=true,PLAYER_REGEN_ENABLED=true}
-- options.unknown: events the simulated client does not know; options.uiError: InitializeUI raises;
-- options.deferLogin: the test fires PLAYER_LOGIN itself; options.firstRunError: OpenFirstRun raises.
local function setup(saved,options)
    options=options or {}
    local world={frames={},filters={},callbacks={},tickers={},hooks={},time=0,after={},delays={},messages={}}
    local secret={}
    local E={}
    local function known(event)
        if options.unknown and options.unknown[event] then return false end
        if LIFECYCLE[event] then return true end
        return E.channelLabels~=nil and E.channelLabels[event]~=nil
    end
    _G.C_EventUtils={IsEventValid=function(event) return known(event) end}
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
        function f:RegisterEvent(event)
            if not known(event) then error('Attempt to register unknown event "'..tostring(event)..'"') end
            self.events[event]=true
        end
        function f:UnregisterEvent(event) self.events[event]=nil end
        function f:Fire(event,...) if self.events[event] then self.scripts.OnEvent(self,event,...) end end
        world.frames[#world.frames+1]=f; return f
    end
    _G.InCombatLockdown=function() return world.combat or false end
    _G.UIParent={IsVisible=function() return not world.uiHidden end}
    _G.UnitIsDeadOrGhost=function(unit) assert(unit=="player"); return world.dead or false end
    _G.StaticPopup_IsAnyDialogShown=function() return world.popup or false end
    _G.C_Timer={After=function(delay,fn) world.after[#world.after+1]=fn; world.delays[#world.delays+1]=delay end,NewTicker=function(interval,fn)
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
    _G.SetItemRef=function() end
    _G.EventRegistry={RegisterCallback=function(_,name,fn,owner) world.callbacks[name]={fn=fn,owner=owner} end}
    _G.GameTooltip={SetOwner=function() end,AddLine=function() end,Show=function() world.tooltip=true end,Hide=function() world.tooltip=false end}
    for _,name in ipairs({"Core","Text","Animation","Runtime"}) do
        local chunk=assert(loadfile("TwitchEmotes/"..name..".lua")); chunk("TwitchEmotes",E)
    end
    E.channelLabels.CHAT_MSG_GUILD_DISCORD=E.channelLabels.CHAT_MSG_GUILD_DISCORD or "Guild Discord"
    E:RegisterPack({id="test",group="general",emotes={
        {name="KEKW",path="Interface\\AddOns\\TwitchEmotes\\Media\\kekw.tga",width=32,height=32,sheetWidth=32,sheetHeight=32,frames=1,fps=0},
        {name="catJAM",path="Interface\\AddOns\\TwitchEmotes\\Media\\cat.tga",width=32,height=32,sheetWidth=32,sheetHeight=128,frames=4,fps=10},
    }})
    function E:InitializeUI() world.ui=(world.ui or 0)+1; if options.uiError then error("UI construction failed") end end
    function E:AttachCompletion(box) box.attached=true end
    function E:OpenPanel() world.open=true end
    function E:OpenFirstRun()
        world.firstRuns=(world.firstRuns or 0)+1
        if options.firstRunError then error("onboarding failed") end
        return true
    end
    function E:InsertEmote(name) world.inserted=name; return true end
    function E:RefreshUI() world.refreshed=true end
    world.eventFrame=world.frames[1]
    world.eventFrame:Fire("ADDON_LOADED","TwitchEmotes")
    if not options.deferLogin then world.eventFrame:Fire("PLAYER_LOGIN") end
    world.loadedMinimap=E.db.minimap; world.loadedSent=E:Stats("KEKW").sent; world.loadedSeen=E:Stats("KEKW").seen
    E.db.stats={}
    function world:Chat(text,guid,id,event)
        self.eventFrame:Fire(event or "CHAT_MSG_SAY",text,"Name","Common","",nil,nil,0,0,"",0,id,guid,0,false,nil,nil,nil,nil)
    end
    function world:Callback(event,...)
        local cb=assert(self.callbacks[event]); cb.fn(cb.owner,...)
    end
    -- Runs the pending timers as the client does: each one alone, an error reaching only the error handler.
    function world:Timers()
        local pending,errors=self.after,{}
        self.after={}
        for _,fn in ipairs(pending) do local ok,err=pcall(fn); if not ok then errors[#errors+1]=tostring(err) end end
        return errors
    end
    function world:Enter()
        self.eventFrame:Fire("PLAYER_ENTERING_WORLD",true,false); self.eventFrame:Fire("LOADING_SCREEN_DISABLED")
        return self:Timers()
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
        local f={visibleLines=lines,scripts={},shown=true,editBox={},history={}}
        function f:AddOnDisplayRefreshedCallback(fn) self.refresh=fn end
        function f:HookScript(event,fn) self.scripts[event]=fn end
        function f:IsShown() return self.shown end
        function f:IsForbidden() return false end
        -- Mirrors ScrollingMessageFrameMixin:TransformMessages with PackageEntry/UnpackageEntry.
        function f:TransformMessages(predicate,transform)
            for i,entry in ipairs(self.history) do
                local x=entry.extraData
                if predicate(entry.message,entry.r,entry.g,entry.b,unpack(x,1,x.n)) then
                    local out=pack(transform(entry.message,entry.r,entry.g,entry.b,unpack(x,1,x.n)))
                    self.history[i]={message=out[1],r=out[2],g=out[3],b=out[4],extraData={n=out.n-4,unpack(out,5,out.n)}}
                    self.dirty=true
                end
            end
        end
        return f
    end
    function world:Entry(message,event,lineID,formatter)
        local args={"censored placeholder","Bob","Common","",nil,nil,0,0,"",0,lineID,"Player-bob",n=12}
        return {message=message,r=1,g=0.5,b=1,extraData={n=6,1,"accessID","typeID",event,args,formatter}}
    end
    return E,world,secret
end

test("login initializes once and slash command opens picker",function()
    local E,w=setup(); equal(E.db,ForeverEmotesDB); equal(w.ui,1)
    w.eventFrame:Fire("PLAYER_LOGIN"); equal(w.ui,1)
    assert(w.filters.CHAT_MSG_SAY); SlashCmdList.FOREVEREMOTES(""); equal(w.open,true)
    equal(w.loadedMinimap,true); equal(w.loadedSent,0); equal(w.loadedSeen,0)
end)

test("startup retains native preferences and statistics despite legacy globals",function()
    local E,w=setup({schema=4,minimap=false,stats={KEKW={sent=9,seen=11}}})
    equal(E.db,ForeverEmotesDB); equal(w.loadedMinimap,false)
    equal(w.loadedSent,9); equal(w.loadedSeen,11)
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

test("Guild Discord renders and counts on clients that know the event",function()
    local E,w=setup(); equal(w.eventFrame.events.CHAT_MSG_GUILD_DISCORD,true)
    local _,text=w.filters.CHAT_MSG_GUILD_DISCORD({},"CHAT_MSG_GUILD_DISCORD","KEKW"); assert(text:find("|T",1,true))
    w:Chat("KEKW","Player-self",48,"CHAT_MSG_GUILD_DISCORD"); equal(E:Stats("KEKW").sent,1)
end)
test("events the client does not know are skipped and login still completes",function()
    local E,w=setup(nil,{unknown={CHAT_MSG_GUILD_DISCORD=true}})
    equal(w.filters.CHAT_MSG_GUILD_DISCORD,nil); equal(w.eventFrame.events.CHAT_MSG_GUILD_DISCORD,nil)
    assert(w.filters.CHAT_MSG_SAY); equal(w.eventFrame.events.CHAT_MSG_SAY,true)
    assert(w.callbacks.SetItemRef); assert(w.hooks.FCF_OpenTemporaryWindow)
    SlashCmdList.FOREVEREMOTES(""); equal(w.open,true)
end)
test("a whisper to yourself counts as sent once",function()
    local E,w=setup()
    w:Chat("KEKW","Player-self",9001,"CHAT_MSG_WHISPER_INFORM"); w:Chat("KEKW","Player-self",9002,"CHAT_MSG_WHISPER")
    equal(E:Stats("KEKW").sent,1); equal(E.db.recent[1],"KEKW"); equal(#E.db.recent,1)
    w:Chat("catJAM","Player-self",9003,"CHAT_MSG_BN_WHISPER"); equal(E:Stats("catJAM").sent,0)
end)
test("a UI fault at login still leaves chat rendering, links and the slash command installed",function()
    local E,w=setup(nil,{uiError=true,deferLogin=true}); local f=w:ChatFrame({}); w.chats={f}
    local ok,err=pcall(w.eventFrame.Fire,w.eventFrame,"PLAYER_LOGIN")
    equal(ok,false); assert(tostring(err):find("UI construction failed",1,true),"the UI error must reach the error handler")
    assert(w.filters.CHAT_MSG_SAY); assert(f.refresh); equal(f.editBox.attached,true)
    assert(w.callbacks.SetItemRef); assert(w.callbacks["ChatFrame.OnHyperlinkEnter"]); assert(w.hooks.FCF_OpenTemporaryWindow)
    equal(w.eventFrame.events.UPDATE_CHAT_WINDOWS,true); equal(type(SlashCmdList.FOREVEREMOTES),"function")
end)
test("temporary whisper windows opened after login attach display and completion once",function()
    local E,w=setup(); assert(w.hooks.FCF_OpenTemporaryWindow)
    local f=w:ChatFrame({}); w.chats={f}
    w.hooks.FCF_OpenTemporaryWindow("WHISPER","Bob"); assert(f.refresh); equal(f.editBox.attached,true)
    local callback=f.refresh; w.hooks.FCF_OpenTemporaryWindow("WHISPER","Bob"); equal(f.refresh,callback)
end)
test("revealing a censored line renders its emotes and records it once",function()
    local E,w,secret=setup(); assert(w.hooks.SetItemRef,"SetItemRef post-hook")
    _G.CENSORED_MESSAGE_REPORT="%s |Hreportcensoredmessage:%d|h[Report]|h"
    local lines={[77]="KEKW",[79]="KEKW",[80]=secret,[81]="KEKW"}
    _G.C_ChatInfo={GetChatLineText=function(id) return lines[id] end}
    local function formatter(text) return "[Bob] whispers: "..text end
    local f=w:ChatFrame({}); w.chats={f}
    local revealed=CENSORED_MESSAGE_REPORT:format(formatter("KEKW"),77)
    f.history={w:Entry(revealed,"CHAT_MSG_WHISPER",77,formatter),w:Entry("other line","CHAT_MSG_WHISPER",78,formatter),
        w:Entry("say line","CHAT_MSG_SAY",79,formatter),w:Entry("secret line","CHAT_MSG_WHISPER",80,formatter),
        w:Entry("lockdown line","CHAT_MSG_WHISPER",81,formatter)}
    f.history[5].extraData[5][2]=secret
    local untouched,args=f.history[2],f.history[1].extraData[5]
    w.hooks.SetItemRef("item:1","[Item]","LeftButton",f); equal(f.dirty,nil)
    w.hooks.SetItemRef("censoredmessage:77","[Show]","LeftButton",f)
    local entry=f.history[1]
    equal(entry.message,CENSORED_MESSAGE_REPORT:format(formatter((E:Transform("KEKW"))),77))
    assert(entry.message:find("|H"..E.linkPrefix.."4b454b57|h",1,true))
    equal(entry.r,1); equal(entry.g,0.5); equal(entry.b,1); equal(entry.extraData.n,6)
    equal(entry.extraData[4],"CHAT_MSG_WHISPER"); equal(entry.extraData[5],args); equal(entry.extraData[6],formatter)
    equal(f.history[2],untouched); equal(E:Stats("KEKW").seen,1)
    w.hooks.SetItemRef("censoredmessage:77","[Show]","LeftButton",f); equal(E:Stats("KEKW").seen,1)
    E:SetOption("channels",{CHAT_MSG_SAY=false}); w.hooks.SetItemRef("censoredmessage:79","[Show]","LeftButton",f)
    equal(f.history[3].message,"say line"); equal(E:Stats("KEKW").seen,1)
    w.hooks.SetItemRef("censoredmessage:80","[Show]","LeftButton",f); equal(f.history[4].message,"secret line")
    w.hooks.SetItemRef("censoredmessage:81","[Show]","LeftButton",f); equal(f.history[5].message,"lockdown line"); equal(E:Stats("KEKW").seen,1)
    w.hooks.SetItemRef(secret,"[Show]","LeftButton",f)
end)

test("the first world entry opens the first-run picker a moment after the loading screen lifts",function()
    local E,w=setup()
    w.eventFrame:Fire("PLAYER_ENTERING_WORLD",true,false); equal(#w:Timers(),0)
    equal(w.firstRuns,nil,"never under the loading screen, where world entry closes special windows")
    w.eventFrame:Fire("LOADING_SCREEN_DISABLED"); equal(w.firstRuns,nil); equal(#w.after,1)
    assert(w.delays[#w.delays]>0,"the picker waits a moment after the loading screen")
    equal(#w:Timers(),0); equal(w.firstRuns,1)
    equal(w.eventFrame.events.PLAYER_ENTERING_WORLD,nil); equal(w.eventFrame.events.LOADING_SCREEN_DISABLED,nil)
    assert(ForeverEmotesDB._startup[#ForeverEmotesDB._startup]:find("After world entry",1,true),"the startup sample still runs")
end)
test("the first-run picker opens at most once per session",function()
    local E,w=setup(); w:Enter(); equal(w.firstRuns,1)
    w.eventFrame.scripts.OnEvent(w.eventFrame,"PLAYER_ENTERING_WORLD",false,false)
    w.eventFrame.scripts.OnEvent(w.eventFrame,"LOADING_SCREEN_DISABLED")
    w.eventFrame.scripts.OnEvent(w.eventFrame,"PLAYER_REGEN_ENABLED")
    equal(#w:Timers(),0); equal(w.firstRuns,1); equal(E.db.setupComplete,false)
end)
test("a loading screen that lifts before world entry still leads to the picker",function()
    local E,w=setup()
    w.eventFrame:Fire("LOADING_SCREEN_DISABLED"); w:Timers(); equal(w.firstRuns,nil)
    w.eventFrame:Fire("PLAYER_ENTERING_WORLD",true,false); w:Timers(); equal(w.firstRuns,1)
end)
test("finished setup opens nothing at world entry",function()
    local E,w=setup({schema=4,setupComplete=true})
    equal(#w:Enter(),0); equal(w.firstRuns,nil); equal(#w.delays,1,"only the startup sample is scheduled")
    equal(w.eventFrame.events.PLAYER_REGEN_ENABLED,nil)
end)
test("saved choices without a finished setup reach the picker unchanged",function()
    local E,w=setup({schema=4,packs={test=false}})
    w:Enter(); equal(w.firstRuns,1); equal(E.db.packs.test,false); equal(E.db.setupComplete,false)
end)
test("entering the world in combat waits for combat to end",function()
    local E,w=setup(); w.combat=true
    w:Enter(); equal(w.firstRuns,nil); equal(w.eventFrame.events.PLAYER_REGEN_ENABLED,true)
    w.combat=false; w.eventFrame:Fire("PLAYER_REGEN_ENABLED"); equal(w.firstRuns,nil,"a moment after combat, not at once")
    equal(w.eventFrame.events.PLAYER_REGEN_ENABLED,nil)
    equal(#w:Timers(),0); equal(w.firstRuns,1)
    w.eventFrame.scripts.OnEvent(w.eventFrame,"PLAYER_REGEN_ENABLED"); w:Timers(); equal(w.firstRuns,1)
end)
test("combat that starts again before the picker opens is waited out too",function()
    local E,w=setup(); w.combat=true; w:Enter()
    w.combat=false; w.eventFrame:Fire("PLAYER_REGEN_ENABLED"); w.combat=true; w:Timers()
    equal(w.firstRuns,nil); equal(w.eventFrame.events.PLAYER_REGEN_ENABLED,true)
    w.combat=false; w.eventFrame:Fire("PLAYER_REGEN_ENABLED"); w:Timers(); equal(w.firstRuns,1)
end)
test("setup finished during that combat opens nothing afterwards",function()
    local E,w=setup(); w.combat=true; w:Enter()
    E:SetOption("setupComplete",true); w.combat=false; w.eventFrame:Fire("PLAYER_REGEN_ENABLED"); w:Timers()
    equal(w.firstRuns,nil); equal(w.eventFrame.events.PLAYER_REGEN_ENABLED,nil)
end)
test("a hidden interface, death or an open dialog delays the picker until it is gone",function()
    for _,state in ipairs({"uiHidden","dead","popup"}) do
        local E,w=setup(); w[state]=true
        w:Enter(); equal(w.firstRuns,nil,state)
        equal(#w:Timers(),0); equal(w.firstRuns,nil,state.." is checked again later")
        w[state]=false; w:Timers(); equal(w.firstRuns,1,state)
        w:Timers(); equal(w.firstRuns,1,state)
    end
    local E,w,secret=setup(); w.dead=secret
    w:Enter(); equal(w.firstRuns,1,"an unreadable death state does not hold the picker back")
end)
test("a client without the loading screen event opens the picker after world entry",function()
    local E,w=setup(nil,{unknown={LOADING_SCREEN_DISABLED=true}})
    equal(w.eventFrame.events.LOADING_SCREEN_DISABLED,nil)
    w.eventFrame:Fire("PLAYER_ENTERING_WORLD",true,false); w:Timers(); equal(w.firstRuns,1)
end)
test("a failing first-run picker leaves chat rendering, links and the slash command working",function()
    local E,w=setup(nil,{firstRunError=true}); local f=w:ChatFrame({}); w.chats={f}
    local errors=w:Enter()
    equal(#errors,1); assert(errors[1]:find("onboarding failed",1,true),"the fault must reach the error handler")
    equal(w.firstRuns,1)
    local _,text=w.filters.CHAT_MSG_SAY({},"CHAT_MSG_SAY","KEKW"); assert(text:find("|T",1,true))
    w:Chat("KEKW","Player-other",61); equal(E:Stats("KEKW").seen,1)
    w.shift=true; w:Callback("SetItemRef",E.linkPrefix.."4b454b57","","LeftButton",{}); equal(w.inserted,"KEKW")
    SlashCmdList.FOREVEREMOTES(""); equal(w.open,true)
    w.eventFrame:Fire("UPDATE_CHAT_WINDOWS"); equal(f.editBox.attached,true)
    w.eventFrame.scripts.OnEvent(w.eventFrame,"PLAYER_REGEN_ENABLED"); equal(w.firstRuns,1,"a failure is not retried this session")
    -- The combat path fails the same way and leaves nothing registered.
    E,w=setup(nil,{firstRunError=true}); w.combat=true; w:Enter(); w.combat=false
    w.eventFrame:Fire("PLAYER_REGEN_ENABLED"); errors=w:Timers()
    equal(#errors,1); assert(errors[1]:find("onboarding failed",1,true)); equal(w.eventFrame.events.PLAYER_REGEN_ENABLED,nil)
    _,text=w.filters.CHAT_MSG_SAY({},"CHAT_MSG_SAY","KEKW"); assert(text:find("|T",1,true))
end)

print(string.format("runtime: %d passed, %d failed",passed,failed))
os.exit(failed==0 and 0 or 1)
