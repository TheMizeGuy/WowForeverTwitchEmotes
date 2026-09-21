-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local passed, failed = 0, 0
local function equal(actual, expected)
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function test(name, body)
    local ok, err = pcall(body)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name .. ": " .. err) end
end
local function loadEngine()
    local E = {}
    for _, name in ipairs({"Core", "Text"}) do
        local file = "TwitchEmotes/" .. name .. ".lua"
        local chunk = loadfile(file)
        assert(chunk, "original " .. name .. " module has not been implemented")
        chunk("TwitchEmotes", E)
    end
    E:InitializeDB()
    return E
end
local function entry(name, path, frames)
    return {name = name, path = path or "Interface\\AddOns\\TwitchEmotes\\Media\\test.tga",
        width = 64, height = 32, sheetWidth = 64, sheetHeight = frames and 128 or 32,
        frames = frames or 1, fps = frames and 10 or 0, creator = "Artist", source = "https://7tv.app/emotes/test"}
end
local function setup()
    local E = loadEngine()
    E:RegisterPack({id="base", title="Base", priority=0, emotes={entry("KEKW"), entry("Kappa"), entry("catJAM", nil, 4), entry("!spin"), entry("plink-182"), entry(":smile:")}})
    E:RebuildCatalog()
    return E
end

test("module loads engine implementation", function() assert(loadEngine().Transform) end)
test("higher priority enabled pack wins and disabling reveals lower pack", function()
    local E = setup()
    E:RegisterPack({id="channel", priority=20, emotes={entry("KEKW", "Interface\\AddOns\\TwitchEmotes\\Media\\other.tga")}})
    E:RebuildCatalog(); equal(E:GetEmote("KEKW").packID, "channel")
    E:SetPackEnabled("channel", false); equal(E:GetEmote("KEKW").packID, "base")
end)
test("pack validation rejects unsafe paths names and impossible sheets", function()
    local E = setup()
    for _, bad in ipairs({entry("bad name"), entry("bad|name"), entry("bad", "..\\outside.tga"), entry("bad", "Interface\\AddOns\\TwitchEmotes\\Media\\ok.tga|t")}) do
        assert(not pcall(function() E:RegisterPack({id="unsafe",emotes={bad}}) end))
    end
    local bad = entry("bad", nil, 4); bad.sheetHeight=32
    assert(not pcall(function() E:RegisterPack({id="unsafe",emotes={bad}}) end))
    equal(E.packs.unsafe, nil)
end)
test("newer registration at equal priority wins deterministically", function()
    local E=setup(); E:RegisterPack({id="a",emotes={entry("KEKW")}}); E:RegisterPack({id="b",emotes={entry("KEKW")}})
    E:RebuildCatalog(); equal(E:GetEmote("KEKW").packID,"b")
end)
test("render preserves wide aspect ratio and samples animation at elapsed time", function()
    local E=setup()
    equal(E:Render(E:GetEmote("KEKW"),20,nil,false),"|TInterface\\AddOns\\TwitchEmotes\\Media\\test.tga:20:40:0:0:64:32:0:64:0:32|t")
    equal(E:Render(E:GetEmote("catJAM"),20,0.25,false),"|TInterface\\AddOns\\TwitchEmotes\\Media\\test.tga:20:40:0:0:64:128:0:64:64:96|t")
    equal(E:Render(E:GetEmote("catJAM"),20,0.45,false),"|TInterface\\AddOns\\TwitchEmotes\\Media\\test.tga:20:40:0:0:64:128:0:64:0:32|t")
end)
test("BLP sheets retain the same animation crop and strict path validation", function()
    local E=setup()
    local path="Interface\\AddOns\\TwitchEmotes\\Media\\7tv\\compressed.blp"
    E:RegisterPack({id="compressed",emotes={entry("compressed",path,4)}}); E:RebuildCatalog()
    equal(E:Render(E:GetEmote("compressed"),20,0.25,false),"|T"..path..":20:40:0:0:64:128:0:64:64:96|t")
    for _, bad in ipairs({path.."|t",path..".tga",path:gsub("%.blp$",".png"),path:gsub("compressed","..\\compressed")}) do
        assert(not pcall(function() E:RegisterPack({id="invalid",emotes={entry("bad",bad)}}) end))
    end
end)
test("literal replacement preserves embedded words and punctuation", function()
    local E=setup(); local text,names,animated=E:Transform("preKEKW KEKW! plink-182 (!spin) :smile: catJAM")
    assert(text:find("preKEKW ",1,true)); equal(#names,5); equal(names[1],"KEKW"); equal(names[2],"plink-182"); equal(names[3],"!spin"); equal(names[4],":smile:"); equal(names[5],"catJAM"); assert(animated)
end)
test("matching is case-sensitive while search is not", function()
    local E=setup(); equal(E:Transform("kekw"),"kekw"); equal(E:Search("kek",10)[1].name,"KEKW")
end)
test("hyperlinks textures atlases escaped pipes and URLs remain opaque", function()
    local E=setup()
    for _, value in ipairs({"|Hitem:123|h[KEKW]|h", "|TKEKW:32|t", "|AatlasKEKW:32:32|a", "https://example.org/KEKW", "www.example.org/KEKW", "foo@KEKW.com", "||HKEKW"}) do
        equal(E:Transform(value),value)
    end
    local changed=E:Transform("|cffff0000KEKW|r")
    assert(changed:sub(1,10)=="|cffff0000"); assert(changed:sub(-2)=="|r"); assert(changed:find("|T",1,true))
    equal(E:Transform("pre|cffff0000KEKW|r"),"pre|cffff0000KEKW|r")
end)
test("malformed markup is preserved rather than partially rewritten", function()
    local E=setup(); equal(E:Transform("|Hitem:123|hKEKW"),"|Hitem:123|hKEKW")
    equal(E:Transform("|TKEKW"),"|TKEKW")
end)
test("unicode surrounding text survives byte-for-byte", function()
    local E=setup(); local text,names=E:Transform("你好 KEKW café")
    assert(text:sub(1,7)=="你好 "); assert(text:sub(-6)==" café"); equal(#names,1)
    equal(E:Transform("你好KEKW"),"你好KEKW")
end)
test("longest literal name wins", function()
    local E=setup(); E:RegisterPack({id="more",emotes={entry("KappaPride")}}); E:RebuildCatalog()
    local _, names=E:Transform("KappaPride Kappa"); equal(names[1],"KappaPride"); equal(names[2],"Kappa")
end)
test("disabled engine returns original text with no hits", function()
    local E=setup(); E:SetOption("enabled",false); local text,names=E:Transform("KEKW"); equal(text,"KEKW"); equal(#names,0)
end)
test("oversized text avoids unbounded work", function()
    local E=setup(); local text=string.rep("KEKW ",2000); equal(E:Transform(text),text)
end)
test("completion replaces only token at cursor and preserves UTF8 prefix suffix", function()
    local E=setup(); local text="你好 :ke tail"; local c=E:Complete(text,10,8)
    assert(c); equal(c.entries[1].name,"KEKW")
    local result,cursor=E:ApplyCompletion(text,c,"KEKW")
    equal(result,"你好 KEKW tail"); equal(cursor,11)
end)
test("completion does not activate inside hyperlink URL or ordinary words", function()
    local E=setup()
    for _, value in ipairs({"word:ke", "https://a/:ke", "|Hitem:1|h:ke|h", "KEKW"}) do equal(E:Complete(value,#value,8),nil) end
end)
test("completion selects suffix of existing colon token at mid-token caret", function()
    local E=setup(); local c=E:Complete(":kexyz rest",3,8)
    equal(E:ApplyCompletion(":kexyz rest",c,"KEKW"),"KEKW rest")
end)
test("colon-style emotes are offered with a single trigger colon", function()
    local E=setup(); local c=E:Complete(":smi",4,8)
    assert(c); equal(c.entries[1].name,":smile:")
end)
test("channel options retain known channels and reject arbitrary settings", function()
    local E=setup(); E:SetOption("channels",{CHAT_MSG_GUILD=false,CHAT_MSG_SAY=true,UNKNOWN=true})
    equal(E.db.channels.CHAT_MSG_GUILD,false); equal(E.db.channels.CHAT_MSG_RAID,true); equal(E.db.channels.UNKNOWN,nil)
end)
test("favorite and pack filters don't leak other entries", function()
    local E=setup(); E:ToggleFavorite("KEKW"); equal(#E:Search("",100,"favorites"),1)
    equal(E:Search("",100,"favorites")[1].name,"KEKW"); equal(#E:Search("",100,"all","missing"),0)
    E:ToggleFavorite("KEKW"); equal(#E:Search("",100,"favorites"),0)
end)
test("usage deduplicates a message across multiple chat frames", function()
    local E=setup(); E:Record({"KEKW","KEKW"},"seen",77); E:Record({"KEKW","KEKW"},"seen",77)
    equal(E:Stats("KEKW").seen,2); E:Record({"KEKW"},"sent",77); equal(E:Stats("KEKW").sent,1)
    equal(E:Search("",10,"recent")[1].name,"KEKW")
end)
test("unknown entries never grow saved usage", function()
    local E=setup(); for i=1,1000 do E:Record({"unknown"..i},"seen",i) end
    equal(next(E.db.stats),nil); equal(#E.db.recent,0)
end)
test("legacy preferences and usage migrate without sharing source tables", function()
    local legacy={LARGEEMOTES=true, ENABLE_ANIMATEDEMOTES=false, MINIMAPBUTTON=false, CHAT_MSG_GUILD=false, MINIMAPDATA={minimapPos=45}}
    local E=loadEngine(); E:InitializeDB(nil,legacy,{KEKW={"ignored",4,8}})
    equal(E.db.animate,false); equal(E.db.minimap,false); equal(E.db.channels.CHAT_MSG_GUILD,false); equal(E.db.size,28); equal(E.db.minimapAngle,45)
    equal(E:Stats("KEKW").sent,4); equal(E:Stats("KEKW").seen,8)
    E.db.channels.CHAT_MSG_GUILD=true; equal(legacy.CHAT_MSG_GUILD,false)
end)
test("corrupt saved state and options are sanitized", function()
    local E=loadEngine(); E:InitializeDB({size=math.huge,animationFPS=-3,channels="bad",packs=false,stats={x={sent=-3,seen="bad"}},recent=false,minimapAngle=0/0})
    equal(E.db.size,28); equal(E.db.animationFPS,5); equal(type(E.db.channels),"table"); equal(type(E.db.stats),"table")
    E:SetOption("size",999); equal(E.db.size,40); E:SetOption("arbitrary",true); equal(E.db.arbitrary,nil)
end)
test("animated markup advances only addon-owned links", function()
    local E=setup(); local text=E:Transform("catJAM |Hitem:1|hcatJAM|h")
    local updated=E:AnimateText(text,0.25)
    assert(updated:find(":64:96|t",1,true)); assert(updated:find("|Hitem:1|hcatJAM|h",1,true))
    E:SetOption("animate",false); local still=E:AnimateText(updated,0.25)
    assert(still:find(":0:32|t",1,true))
end)

test("completion preserves a spaced hyperlink label at the caret", function()
    local E=setup(); local text="|Hitem:1|hlabel :ke|h"
    equal(E:Complete(text,#text-2,8),nil)
end)
test("color escapes do not introduce a right word boundary", function()
    local E=setup()
    for _,text in ipairs({"KEKW|cffff0000suffix|r","|cffff0000KEKW|rsuffix"}) do equal(E:Transform(text),text) end
end)
test("quoted and parenthesized URLs stay opaque", function()
    local E=setup()
    for _,text in ipairs({"(https://example.org/KEKW)",'"https://example.org/KEKW"',"[www.example.org/KEKW]"}) do equal(E:Transform(text),text) end
end)
test("animation preserves escaped and foreign hyperlink markup", function()
    local E=setup(); local text="|"..E:Transform("catJAM")
    equal(E:AnimateText(text,0.25),text)
    equal(E:NameFromLink(E.linkPrefix.."7c"),nil)
end)

test("high resolution sprite grids crop columns and rows precisely", function()
    local E=setup()
    E:RegisterPack({id="hd",emotes={{name="HD",path="Interface\\AddOns\\TwitchEmotes\\Media\\hd.tga",width=96,height=64,
        cellWidth=128,columns=8,frames=128,fps=60,sheetWidth=1024,sheetHeight=1024}}})
    E:RebuildCatalog()
    equal(E:Render(E:GetEmote("HD"),24,10/60,false),"|TInterface\\AddOns\\TwitchEmotes\\Media\\hd.tga:24:36:0:0:1024:1024:256:352:64:128|t")
    E:SetOption("animationFPS",60); equal(E.db.animationFPS,60)
end)
test("invalid grid bounds fail before registration", function()
    local E=setup(); local bad=entry("bad",nil,4); bad.columns=3; bad.cellWidth=64
    assert(not pcall(function() E:RegisterPack({id="bad",emotes={bad}}) end)); equal(E.packs.bad,nil)
end)

test("a frame sequence replays stored cells in the recorded order", function()
    local E=setup(); local path="Interface\\AddOns\\TwitchEmotes\\Media\\seq.tga"
    E:RegisterPack({id="seq",emotes={{name="seqJAM",path=path,width=64,height=32,cellWidth=64,columns=1,
        frames=3,fps=10,sheetWidth=64,sheetHeight=128,sequence="\000\001\001\002"}}})
    E:RebuildCatalog(); local seqJAM=E:GetEmote("seqJAM")
    local function cell(top) return "|T"..path..":20:40:0:0:64:128:0:64:"..top..":"..(top+32).."|t" end
    equal(E:Render(seqJAM,20,0,false),cell(0)); equal(E:Render(seqJAM,20,0.15,false),cell(32))
    equal(E:Render(seqJAM,20,0.25,false),cell(32)); equal(E:Render(seqJAM,20,0.35,false),cell(64))
    equal(E:Render(seqJAM,20,0.45,false),cell(0))
end)
test("frame heights other than 64 crop rows and scale width from the frame aspect", function()
    local E=setup(); local path="Interface\\AddOns\\TwitchEmotes\\Media\\short.tga"
    E:RegisterPack({id="short",emotes={{name="shortJAM",path=path,width=80,height=40,cellWidth=128,columns=2,
        frames=3,fps=10,sheetWidth=256,sheetHeight=128}}})
    E:RebuildCatalog(); local shortJAM=E:GetEmote("shortJAM")
    equal(E:Render(shortJAM,20,0.05,false),"|T"..path..":20:40:0:0:256:128:0:80:0:40|t")
    equal(E:Render(shortJAM,20,0.15,false),"|T"..path..":20:40:0:0:256:128:128:208:0:40|t")
    equal(E:Render(shortJAM,20,0.25,false),"|T"..path..":20:40:0:0:256:128:0:80:40:80|t")
end)
test("frame sequences must be bounded byte strings over stored cells", function()
    local E=setup()
    local function sequenced(sequence,frames)
        local e=entry("seqBad",nil,frames or 4); e.sequence=sequence; return e
    end
    local static=entry("seqBad"); static.sequence="\000\000"
    for _, bad in ipairs({sequenced({0,1}),sequenced("\000"),sequenced(string.rep("\000",257)),sequenced("\000\004"),static}) do
        assert(not pcall(function() E:RegisterPack({id="badseq",emotes={bad}}) end))
    end
    equal(E.packs.badseq,nil)
    E:RegisterPack({id="goodseq",emotes={sequenced("\000\001\001\002")}}); E:RebuildCatalog()
    equal(E:GetEmote("seqBad").sequence,"\000\001\001\002")
end)

test("provider globals share General and channel packs share one named group", function()
    local E=loadEngine()
    E:RegisterPack({id="bttv_global",title="BTTV Global",emotes={entry("KEKW")}})
    E:RegisterPack({id="ffz_global",title="FFZ Global",emotes={entry("Kappa")}})
    E:RegisterPack({id="twitch_forsen",title="Twitch Forsen",group="forsen",groupTitle="Forsen",emotes={entry("forsenE")}})
    E:RegisterPack({id="seven_forsen",title="7TV Forsen",group="forsen",groupTitle="Forsen",emotes={entry("forsenCD")}})
    E:RebuildCatalog(); local groups=E:GetGroups()
    equal(#groups,2); equal(groups[1].title,"General"); equal(#groups[1].packIDs,2)
    equal(groups[2].title,"Forsen"); equal(#groups[2].packIDs,2)
    equal(#E:Search("",50,"all",{twitch_forsen=true,seven_forsen=true}),2)
    E:SetGroupEnabled("forsen",false); equal(E:GetEmote("forsenE"),nil); equal(E:GetEmote("forsenCD"),nil)
    E:SetGroupEnabled("forsen",true); assert(E:GetEmote("forsenE"))
end)

test("missing settings enable the release channels without overwriting saved choices", function()
    local E=loadEngine()
    E:RegisterPack({id="bttv_global",emotes={entry("Kappa")}})
    for _,id in ipairs({"graycen","forsen","erobb221","xqc","asmongold","xaryu"}) do
        E:RegisterPack({id=id,emotes={entry(id.."Emote")}})
    end
    E:PrepareSetup(); E:RebuildCatalog()
    assert(E:GetEmote("Kappa")); equal(E:GetEmote("xaryuEmote"),nil)
    for _,id in ipairs({"graycen","forsen","erobb221","xqc","asmongold"}) do assert(E:GetEmote(id.."Emote"),id.." must start enabled") end
    E:SetGroupEnabled("forsen",false); E:SetGroupEnabled("xaryu",true)
    E:InitializeDB(E.db); E:PrepareSetup(); E:RebuildCatalog()
    equal(E:GetEmote("forsenEmote"),nil); assert(E:GetEmote("xaryuEmote"))
    E:SetOption("setupComplete",true); equal(E.db.setupComplete,true)
end)
test("preferred channel wins overlaps and disabled groups relinquish names", function()
    local E=setup()
    E:RegisterPack({id="forsen",priority=20,emotes={entry("KEKW","Interface\\AddOns\\TwitchEmotes\\Media\\forsen.tga")}})
    E:RebuildCatalog(); equal(E:GetEmote("KEKW").packID,"forsen")
    E:SetOption("preferredGroup","base"); equal(E:GetEmote("KEKW").packID,"base")
    E:SetGroupEnabled("base",false); equal(E:GetEmote("KEKW").packID,"forsen")
    E:SetOption("preferredGroup","missing"); equal(E.db.preferredGroup,"base")
end)

test("new packs inherit chosen channel state while new channels stay off", function()
    local E=loadEngine(); E.db.setupComplete=true
    E:RegisterPack({id="seventv_forsen",group="forsen",emotes={entry("KEKW")}})
    E.db.packs.seventv_forsen=true
    E:RegisterPack({id="twitch_forsen",group="forsen",emotes={entry("forsenE")}})
    E:RegisterPack({id="xaryu",emotes={entry("newEmote")}})
    E:PrepareSetup(); equal(E.db.packs.twitch_forsen,true); equal(E.db.packs.xaryu,false)
end)

test("hidden names stay plain across packs and leave search and completion", function()
    local E=setup()
    E:RegisterPack({id="channel",priority=20,emotes={entry("KEKW")}}); E:RebuildCatalog()
    E.db.favorites.KEKW=true; E.db.recent={"KEKW"}
    assert(type(E.SetEmoteHidden)=="function", "individual emote hiding is missing")
    assert(E:SetEmoteHidden("KEKW",true)); equal(E:GetEmote("KEKW"),nil)
    equal(E:Transform("KEKW"),"KEKW"); equal(E:Complete(":KEK",4),nil)
    equal(#E:Search("KEKW",10),0); equal(#E:Search("KEKW",10,"favorites"),0)
    equal(#E:Search("KEKW",10,"recent"),0)
    E:SetPackEnabled("channel",false); equal(E:GetEmote("KEKW"),nil)
    equal(E.db.favorites.KEKW,true); equal(E.db.recent[1],"KEKW")
    E:InitializeDB(E.db); E:RebuildCatalog(); equal(E:Transform("KEKW"),"KEKW")
    assert(E:IsEmoteHidden("KEKW")); equal(E:GetHiddenEmote("KEKW").name,"KEKW")
end)

test("hidden emotes can be restored even when their channel is disabled", function()
    local E=setup()
    assert(type(E.SetEmoteHidden)=="function", "individual emote hiding is missing")
    E:SetEmoteHidden("catJAM",true); E:SetPackEnabled("base",false)
    local hidden=E:Search("cat",10,"hidden"); equal(#hidden,1); equal(hidden[1].name,"catJAM")
    E:SetEmoteHidden("catJAM",false); equal(#E:Search("",10,"hidden"),0)
    equal(E:GetEmote("catJAM"),nil); equal(E.db.packs.base,false)
    E:SetPackEnabled("base",true); assert(E:GetEmote("catJAM"))
end)

test("hidden preferences reject invalid input and unchanged choices do no work", function()
    local E=setup()
    E:InitializeDB({hidden={KEKW=true,Kappa=false,["bad|name"]=true,[7]=true,unknown=true}})
    E:RebuildCatalog()
    assert(type(E.db.hidden)=="table", "saved hidden preferences are missing")
    equal(E.db.hidden.KEKW,true); equal(E.db.hidden.Kappa,nil); equal(E.db.hidden.unknown,nil)
    equal(E.db.hidden["bad|name"],nil); equal(E.db.hidden[7],nil)
    local revision=E.revision
    equal(E:SetEmoteHidden("unknown",true),false); equal(E:SetEmoteHidden("KEKW","false"),false)
    equal(E:SetEmoteHidden("KEKW",true),false); equal(E.revision,revision)
    assert(E:SetEmoteHidden("KEKW",false)); assert(E.revision>revision)
end)

test("browsing disabled groups shows their own deduplicated catalog", function()
    local E=setup()
    E:RegisterPack({id="channel",group="channel",priority=20,emotes={entry("KEKW"),entry("exclusive")}})
    E:SetGroupEnabled("base",false); E:SetGroupEnabled("channel",true)
    local entries=E:Search("KEKW",10,"all",{base=true},true)
    equal(#entries,1); equal(entries[1].packID,"base")
    equal(E:GetEmote("KEKW").packID,"channel")
    E:SetGroupEnabled("channel",false)
    equal(#E:Search("exclusive",10,"all",{channel=true},true),1)
    equal(E:GetEmote("exclusive"),nil); equal(E:GetEmote("exclusive",true).name,"exclusive")
    E:ToggleFavorite("exclusive"); equal(#E:Search("",10,"favorites",{channel=true},true),1)
end)

test("larger defaults migrate once and preserve deliberately chosen sizes", function()
    local E=loadEngine(); equal(E.db.size,28)
    E:InitializeDB({schema=1,size=22}); equal(E.db.size,28); equal(E.db.schema,4)
    E:SetOption("size",22); E:InitializeDB(E.db); equal(E.db.size,22)
    E:InitializeDB({schema=1,size=35}); equal(E.db.size,35)
end)

test("common text faces and chat words start hidden and explicit restoration survives reload", function()
    local E=loadEngine(); local faces={":)",":(",":O",":D","D:","<3",":-P",":/",":-\\","8-)","B)","O_o","R-)",";p","1G","BOP","Retail","Classic","classic","CLASSIC"}; local entries={}
    for _,name in ipairs(faces) do entries[#entries+1]=entry(name) end
    E:RegisterPack({id="twitch_global",emotes=entries}); E:RebuildCatalog()
    for _,name in ipairs(faces) do equal(E:Transform(name),name); assert(E:IsEmoteHidden(name),name.." must start hidden") end
    E:SetEmoteHidden(":)",false); E:InitializeDB(E.db); E:RebuildCatalog()
    assert(E:GetEmote(":)")); equal(E:IsEmoteHidden(":)"),false); equal(E:IsEmoteHidden(":("),true)
    E:InitializeDB({schema=1,size=22}); E:RebuildCatalog(); equal(E:IsEmoteHidden(":)"),true)
    -- a 3.0.0 install saved under schema 2 gains the new names but keeps a deliberate restore
    E:InitializeDB({schema=2,hidden={Retail=false}}); E:RebuildCatalog()
    equal(E:IsEmoteHidden("Retail"),false); equal(E:IsEmoteHidden("1G"),true); equal(E:IsEmoteHidden(":-P"),true); equal(E.db.schema,4)
end)

print(string.format("core: %d passed, %d failed",passed,failed))
os.exit(failed==0 and 0 or 1)
