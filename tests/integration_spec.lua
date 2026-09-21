-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
-- Usage: luajit tests/integration_spec.lua [repository root] [optional Packs directory]
local testDirectory = arg[0]:match("^(.*[/\\])") or ""
local B = dofile(testDirectory .. "ui_boundary.lua")
local root = arg[1] or "."
local addonDirectory = root .. "/TwitchEmotes"
local packsDirectory = arg[2] or addonDirectory .. "/Packs"
local mediaDirectory = packsDirectory:gsub("/Packs/?$", "")
local E, passed, failed = {}, 0, 0
local function equal(actual, expected, message)
    assert(actual == expected, (message or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function test(name, body)
    local ok, err = pcall(body)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; io.stderr:write("FAIL " .. name .. "\n" .. tostring(err) .. "\n") end
end
local function count(values) local n = 0; for _ in pairs(values) do n = n + 1 end; return n end
local function tuple(...) return { n = select("#", ...), ... } end
local function chatMessage(event, text, lineID, guid)
    B.event(event, text, "Name", "Common", "", nil, nil, 0, 0, "", 0, lineID, guid, 0, false, nil, nil, nil, nil)
end

B.editor = B.editorFrame()
local chat = B.new("ScrollingMessageFrame", "ChatFrame1", UIParent)
chat.visibleLines, chat.editBox = {}, B.editor
B.chats = { chat }

-- Read only the declared modules, and reject unexpected TOC entries before loading.
local modules = { ["Core.lua"] = true, ["Text.lua"] = true, ["UI.lua"] = true, ["Completion.lua"] = true, ["Animation.lua"] = true, ["Runtime.lua"] = true }
local expectedPacks = { "bttv_global", "ffz_global", "seventv_global", "graycen", "erobb221" }
for _, id in ipairs(expectedPacks) do modules["Packs/" .. id .. ".lua"] = true end
local toc = assert(io.open(addonDirectory .. "/TwitchEmotes_Camelot.toc", "r"))
local files, packFiles = {}, {}
for line in toc:lines() do
    line = line:gsub("\r", ""):match("^%s*(.-)%s*$"):gsub("\\", "/")
    if line ~= "" and line:sub(1, 1) ~= "#" then
        assert(modules[line] or line:match("^Packs/[%w_-]+%.lua$"), "Unexpected module in TOC: " .. line)
        files[#files + 1] = line
        if line:sub(1, 6) == "Packs/" then packFiles[#packFiles + 1] = line end
    end
end
toc:close()
local loaded = {}
for _, path in ipairs(files) do
    assert(not loaded[path], "Duplicate TOC module: " .. path)
    local absolute = path:sub(1, 6) == "Packs/" and (packsDirectory .. "/" .. path:sub(7)) or (addonDirectory .. "/" .. path)
    assert(loadfile(absolute))("TwitchEmotes", E); loaded[path] = true
end
for path in pairs(modules) do assert(loaded[path], "Missing TOC module: " .. path) end
equal(#E.packOrder, #packFiles, "every declared provider/channel pack loaded")
for _, id in ipairs(expectedPacks) do assert(E.packs[id], "missing provider/channel pack: " .. id) end

local seed = assert(E.packs.bttv_global.emotes[1], "BTTV global pack is empty")
_G.ForeverEmotesDB = nil
_G.Emoticons_Settings = { LARGEEMOTES = true, MINIMAPBUTTON = false }
_G.TwitchEmoteStatistics = { [seed.name] = { "legacy", 5, 7 } }
B.event("ADDON_LOADED", "AnotherAddon")
equal(E.db, nil, "unrelated addon load does not initialize state")
B.event("ADDON_LOADED", "TwitchEmotes")
B.event("PLAYER_LOGIN")
local panelShownAtLogin = E.ui.panel and E.ui.panel:IsShown()
B.event("PLAYER_ENTERING_WORLD", true, false)
-- Forever closes special windows during world entry, after PLAYER_LOGIN.
for _, name in ipairs(UISpecialFrames) do if _G[name] then _G[name]:Hide() end end
B.nextFrame()

local sample, animated, wide
for _, entry in ipairs(E.names) do
    -- The browser opens to General even when more channel groups start enabled.
    if E.packs[entry.packID].group == "general" then
        if not sample and #entry.name >= 6 and entry.name:match("^[A-Za-z][A-Za-z0-9_]+$") then sample = entry end
        -- Deduplicated animations may replay one cell for several steps; the timing tests need a visible change after one step.
        if not animated and entry.frames > 1 and (not entry.sequence or entry.sequence:byte(2) ~= entry.sequence:byte(1)) then animated = entry end
        if not wide and entry.width > entry.height then wide = entry end
    end
end
assert(sample and animated and wide, "real packs must contain searchable, animated and wide emotes")

test("actual startup migrates the published saved globals and initializes once", function()
    equal(E.db, ForeverEmotesDB); equal(E.db.size, 28); equal(E.db.minimap, false)
    equal(E:Stats(seed.name).sent, 5); equal(E:Stats(seed.name).seen, 7)
    assert(#E.names > 50, "expected real provider catalog")
    assert(not panelShownAtLogin, "startup must not open a configuration window")
    assert(not E.ui.panel or not E.ui.panel:IsShown(), "world entry must not open first-run setup")
    local defaults = { general=true, graycen=true, forsen=true, erobb221=true, xqc=true, asmongold=true }
    local enabledGroups = {}
    for _, id in ipairs(E.packOrder) do
        local group = E.packs[id].group
        equal(E.db.packs[id], defaults[group] == true, "release default for " .. id)
        if E.db.packs[id] then enabledGroups[group] = true end
    end
    equal(count(enabledGroups), 6, "all requested groups exist and start enabled")
    B.event("PLAYER_LOGIN"); equal(B.categories, 1); equal(#B.filters.CHAT_MSG_SAY, 1)
    equal(#chat.displayCallbacks, 1); equal(B.liveTickers(), 0)
    SlashCmdList.FOREVEREMOTES(""); assert(E.ui.panel:IsShown())
end)

test("real picker search, favorites and insertion share the active catalog", function()
    E:OpenPanel("browse"); B.type(E.ui.search, sample.name)
    assert(#E.ui.results > 0)
    for _, entry in ipairs(E.ui.results) do assert(entry.name:lower():find(sample.name:lower(), 1, true), "search leaked another entry") end
    local row = E.ui.rows[1]; local name = row.entry.name; local sentBefore = E:Stats(name).sent
    row.favorite:Click(); equal(E.db.favorites[name], true)
    B.find("Favorites"):Click(); equal(E.ui.results[1].name, name)
    B.active = B.editor; B.type(B.editor, "hello world", 5)
    E.ui.rows[1]:Click(); equal(B.editor:GetText(), "hello " .. name .. " world")
    assert(not B.editor:GetText():find("|", 1, true), "picker must insert plain text")
    equal(E:Stats(name).sent, sentBefore, "picking is not sending")
    B.find("All"):Click(); E.ui.search:SetText("")
end)

test("native completion uses real byte spans without destroying a draft", function()
    local query = sample.name:sub(1, 3)
    B.type(B.editor, "é :" .. query .. "unfinished tail", 4 + #query)
    assert(AutoCompleteBox:IsShown()); assert(#AutoCompleteBox.results <= 5)
    local name = AutoCompleteBox.results[1].name
    assert(AutoCompleteButton1:GetText():find(E:GetEmote(name).path, 1, true), "real suggestion must render the selected emote texture")
    assert(AutoCompleteButton1:GetText():find(":24:", 1, true), "autocomplete image should be readable at 24 pixels")
    assert(not name:find("|", 1, true), "autocomplete selection must remain plain text")
    B.editor:Run("OnEnterPressed")
    equal(B.editor:GetText(), "é " .. name .. " tail"); equal(B.editor:GetCursorPosition(), 3 + #name)
    equal(AutoCompleteBox:IsShown(), false)
end)

test("real settings repaint while disabled channels remain browsable", function()
    E:OpenPanel("settings"); local group = E.ui.selectedGroup
    B.find("Enable this group"):Click()
    for _, id in ipairs(group.packIDs) do equal(E.db.packs[id], false) end
    E:OpenPanel("browse")
    assert(#E.ui.results>0, "disabled channels must keep their catalog previews")
    E:OpenPanel("settings"); B.find("Enable this group"):Click()
    for _, id in ipairs(group.packIDs) do equal(E.db.packs[id], true) end
    E.ui.priorityButton:Click(); equal(E.db.preferredGroup, group.id)
    E:SetOption("animationFPS", 30); B.find("Increase animation fps"):Click(); equal(E.db.animationFPS, 60)
    UIParent:SetSize(580, 480); E:OpenPanel()
    assert(E.ui.panel:GetWidth() * E.ui.panel:GetEffectiveScale() <= 548)
    assert(E.ui.panel:GetHeight() * E.ui.panel:GetEffectiveScale() <= 448)
    UIParent:SetSize(1280, 720); E:OpenPanel("browse")
end)

test("display filters preserve callback arguments and confirmed events own usage counts", function()
    local callback = B.filters.CHAT_MSG_SAY[1]
    local baseline = E:Stats(sample.name); local sent, seen = baseline.sent, baseline.seen
    local result = tuple(callback(chat, "CHAT_MSG_SAY", sample.name, "Alice", nil, "last", nil))
    equal(result.n, 6); equal(result[1], false); assert(result[2]:find("|T", 1, true)); assert(result[2]:find("|Haddon:ForeverEmotes:", 1, true))
    equal(result[3], "Alice"); equal(result[4], nil); equal(result[5], "last"); equal(result[6], nil)
    callback(chat, "CHAT_MSG_SAY", sample.name); equal(E:Stats(sample.name).seen, seen)
    chatMessage("CHAT_MSG_SAY", sample.name, 7001, "Player-other"); equal(E:Stats(sample.name).seen, seen + 1)
    chatMessage("CHAT_MSG_SAY", sample.name, 7001, "Player-other"); equal(E:Stats(sample.name).seen, seen + 1)
    chatMessage("CHAT_MSG_SAY", sample.name, 7002, "Player-self"); equal(E:Stats(sample.name).sent, sent + 1); equal(E.db.recent[1], sample.name)
    E:OpenPanel("settings"); B.find("Say"):Click()
    local _, unchanged = callback(chat, "CHAT_MSG_SAY", sample.name); equal(unchanged, sample.name)
    chatMessage("CHAT_MSG_SAY", sample.name, 7003, "Player-self"); equal(E:Stats(sample.name).sent, sent + 1)
    B.find("Say"):Click()
    local secret = { secret = true }; local _, untouched = callback(chat, "CHAT_MSG_SAY", secret); equal(untouched, secret)
end)

test("native link callbacks insert the actual emote name and expose its metadata", function()
    B.type(B.editor, ""); B.active = B.editor; B.shift = true
    B.callback("SetItemRef", E.linkPrefix .. sample.encodedName, "", "LeftButton", chat)
    equal(B.editor:GetText(), sample.name .. " ")
    B.callback("ChatFrame.OnHyperlinkEnter", chat, E.linkPrefix .. sample.encodedName)
    equal(GameTooltip.lines[1], sample.name); assert(#GameTooltip.lines >= 3)
    B.callback("ChatFrame.OnHyperlinkLeave", chat); B.shift = false
end)

test("real animation metadata changes only visible content and stops while idle", function()
    E:SetOption("animate", true); E:SetOption("animationFPS", 60)
    local line = B.new("FontString", nil, chat); line:SetText(E:Transform(animated.name))
    chat.visibleLines = { line }; chat:RefreshDisplay(); equal(B.liveTickers(), 1)
    local before = line:GetText(); B.tick(1 / animated.fps + 0.001); assert(line:GetText() ~= before)
    equal(B.tickers[#B.tickers].interval, 1 / 60)
    line:SetText("recycled line"); B.tick(2); equal(line:GetText(), "recycled line"); equal(B.liveTickers(), 0)
    chat.visibleLines = {}; chat:RefreshDisplay(); equal(B.liveTickers(), 0)
end)

test("emote hover previews are throttled and release update scripts immediately", function()
    E:OpenPanel("browse"); E.ui.search:SetText(animated.name)
    local row
    for _, candidate in ipairs(E.ui.rows) do if candidate.entry and candidate.entry.name == animated.name then row = candidate; break end end
    assert(row, "animated emote must be visible in search")
    row:Run("OnEnter"); assert(row:GetScript("OnUpdate"), "hover must start the animation preview")
    assert(GameTooltip.lines[4]:find("Source credit: ", 1, true), "provider metadata should use a neutral attribution label")
    local before = row.preview:GetText(); B.time = 1 / animated.fps + 0.001
    row:Run("OnUpdate", 0.01); equal(row.preview:GetText(), before, "hover refresh is capped")
    row:Run("OnUpdate", 0.03); assert(row.preview:GetText() ~= before)
    row:Run("OnLeave"); equal(row:GetScript("OnUpdate"), nil)
    row:Run("OnEnter"); E.ui.panel:Hide(); equal(row:GetScript("OnUpdate"), nil)
    E:OpenPanel("browse"); E:SetOption("animate", false); row:Run("OnEnter"); equal(row:GetScript("OnUpdate"), nil)
    E:SetOption("animate", true)
end)

test("registered texture dimensions match real TGA and BLP files and retain aspect ratio", function()
    local checked = {}
    local entries = { animated, wide }
    for _, id in ipairs(E.packOrder) do entries[#entries + 1] = E.packs[id].emotes[1] end
    for _, entry in ipairs(entries) do
        assert(type(entry.source) == "string" and entry.source ~= "", "source provenance missing")
        assert(type(entry.creator) == "string", "creator metadata missing")
        if not checked[entry.path] then
            local relative = assert(entry.path:match("^Interface\\AddOns\\TwitchEmotes\\(.+)$")):gsub("\\", "/")
            local file = assert(io.open(mediaDirectory .. "/" .. relative, "rb")); local header = file:read(20); file:close()
            assert(header and #header == 20)
            local function number(offset, bytes)
                local value=0; for index=0,bytes-1 do value=value+header:byte(offset+index)*256^index end
                return value
            end
            local width,height
            if relative:match("%.blp$") then
                equal(header:sub(1,12),"BLP2\001\000\000\000\001\008\008\000")
                width,height=number(13,4),number(17,4)
            else
                assert(relative:match("%.tga$") and (header:byte(3)==2 or header:byte(3)==10) and header:byte(17)==32)
                width,height=number(13,2),number(15,2)
            end
            equal(width, entry.sheetWidth); equal(height, entry.sheetHeight); checked[entry.path] = true
        end
    end
    local texture = E:Render(wide, 28)
    local height, width = texture:match("%.[a-z]+:(%d+):(%d+):")
    equal(tonumber(height), 28); equal(tonumber(width), math.floor(28 * wide.width / wide.height + 0.5))
    assert(count(checked) >= 3, "expected multiple provider texture files")
end)

test("chat emote menu hides a name immediately and stops its animation", function()
    E:SetOption("animate",true); B.shift=false
    local line=B.new("FontString",nil,chat); line:SetText(E:Transform(animated.name))
    local other=B.new("FontString",nil,chat); other:SetText("untouched |Hitem:1|h[item]|h")
    chat.visibleLines={line,other}; chat:RefreshDisplay(); equal(B.liveTickers(),1)
    B.type(B.editor,"unsent draft"); local draft=B.editor:GetText()
    B.callback("SetItemRef",E.linkPrefix..animated.encodedName,"","LeftButton",chat)
    assert(E.ui.emoteMenu and E.ui.emoteMenu:IsShown(), "chat click must open the emote menu")
    equal(B.editor:GetText(),draft)
    B.find("Hide this emote",E.ui.emoteMenu):Click()
    equal(line:GetText(),animated.name); equal(other:GetText(),"untouched |Hitem:1|h[item]|h")
    equal(B.liveTickers(),0); equal(E.ui.emoteMenu:IsShown(),false)
    equal(E:GetEmote(animated.name),nil); equal(E:Transform(animated.name),animated.name)
    equal(E:Complete(":"..animated.name,#animated.name+1),nil)
    local _,text=B.filters.CHAT_MSG_SAY[1](chat,"CHAT_MSG_SAY",animated.name); equal(text,animated.name)
end)

test("Hidden view restores names across groups without enabling disabled channels", function()
    assert(type(E.IsEmoteHidden)=="function", "hidden state query is missing")
    assert(E:IsEmoteHidden(animated.name))
    local group=E.packs[animated.packID].group
    E:SetGroupEnabled(group,false); E:OpenPanel("settings")
    B.find("Hidden emotes"):Click(); equal(E.ui.mode,"hidden")
    equal(E.ui.search:GetText(),""); equal(E.ui.groupTitle:GetText(),"Hidden emotes · all groups")
    local row
    for _,candidate in ipairs(E.ui.rows) do if candidate.entry and candidate.entry.name==animated.name then row=candidate; break end end
    assert(row,"hidden emote remains manageable while its channel is disabled")
    equal(row.favorite:IsShown(),false); row:Click()
    equal(E:IsEmoteHidden(animated.name),false); equal(E:GetEmote(animated.name),nil)
    equal(E.db.packs[animated.packID],false)
    E:SetGroupEnabled(group,true); assert(E:GetEmote(animated.name))
    B.find("All",E.ui.browse):Click(); E.ui.search:SetText("")
    chat.visibleLines={}; chat:RefreshDisplay()
end)

test("emote menus reuse controls and close on escape or outside clicks", function()
    assert(type(E.OpenEmoteMenu)=="function", "emote context menu is missing")
    E:OpenEmoteMenu(sample.name); local menu=E.ui.emoteMenu; local frames=#B.frames
    B.editor:ClearFocus(); menu:Run("OnKeyDown","ESCAPE"); equal(menu:IsShown(),false)
    E:OpenEmoteMenu(sample.name); menu.mouseOver=true
    B.event("GLOBAL_MOUSE_DOWN","LeftButton"); equal(menu:IsShown(),true)
    menu.mouseOver=false; B.event("GLOBAL_MOUSE_DOWN","LeftButton"); equal(menu:IsShown(),false)
    for i=1,4 do E:OpenEmoteMenu(sample.name); menu:Run("OnKeyDown","ESCAPE") end
    equal(#B.frames,frames); equal(menu:GetScript("OnUpdate"),nil)
    equal(E:OpenEmoteMenu("notAnInstalledEmote"),false)
    B.callback("SetItemRef","item:1","","LeftButton",chat); equal(menu:IsShown(),false)
    B.callback("SetItemRef",{secret=true},"","LeftButton",chat); equal(menu:IsShown(),false)
    B.callback("SetItemRef",E.linkPrefix..sample.encodedName,"",{secret=true},chat); equal(menu:IsShown(),false)
    B.callback("SetItemRef",E.linkPrefix..sample.encodedName,"","RightButton",chat); equal(menu:IsShown(),true)
    B.find("Emote settings",menu):Click(); equal(menu:IsShown(),false); equal(E.ui.tab,"settings")
end)

test("Browse toggles channels while preserving searchable previews and enabled markers", function()
    E:OpenPanel("browse"); E.ui.mode="all"; E.ui.search:SetText(""); E:RefreshUI()
    local group=E.ui.selectedGroup; E:SetGroupEnabled(group.id,false)
    assert(E.ui.browseEnabled, "Browse needs a channel enable checkbox")
    equal(E.ui.browseEnabled:GetChecked(),false); assert(#E.ui.results>0)
    local preview=E.ui.results[1]; E.ui.search:SetText(preview.name); assert(#E.ui.results>0)
    local groupRow
    for _,row in ipairs(E.ui.groupRows) do if row.group and row.group.id==group.id then groupRow=row end end
    assert(groupRow and groupRow.enabledMark, "sidebar needs a persistent enabled marker")
    equal(groupRow.enabledMark:IsShown(),false)
    E.ui.browseEnabled:Click(); equal(E.ui.browseEnabled:GetChecked(),true)
    equal(groupRow.enabledMark:IsShown(),true); assert(E:GetEmote(preview.name))
    equal(E.ui.search:GetText(),preview.name)
    E.ui.search:SetText("")
end)

test("channel tooltips have explicit readable text and author credit stays visible", function()
    E:OpenPanel("browse"); E.ui.groupRows[1]:Run("OnEnter")
    for _,color in ipairs(GameTooltip.colors) do assert(color[1] and color[1]>=0.65 and color[2]>=0.65 and color[3]>=0.65,"tooltip text must set a readable color") end
    assert(E.ui.credit,"persistent author credit missing"); equal(E.ui.credit:GetText(),"Made by TheMizeGuy")
    for _,tab in ipairs({"browse","settings","setup"}) do E:OpenPanel(tab); assert(E.ui.credit:IsVisible()); equal(E.ui.credit:GetPoint(),"BOTTOMRIGHT") end
end)

test("minimap launcher uses an actual icon rather than a rectangular settings control", function()
    assert(E.ui.minimap.icon,"dedicated minimap icon missing")
    assert(E.ui.minimap.icon.texture or E.ui.minimap.icon.atlas,"minimap icon needs a real texture")
    assert(E.ui.minimap.icon.mask,"minimap background must be circularly masked")
    equal(E.ui.minimap:GetHighlightTexture().mask,E.ui.minimap.icon.mask)
    equal(E.ui.minimap:GetPushedTexture().mask,E.ui.minimap.icon.mask)
    equal(E.ui.minimap.selection,nil,"the settings selection rectangle must not be reused")
    E.ui.minimap:Click(); equal(E.ui.panel:IsShown(),true)
end)

test("emote scale slider updates live preview and rendered chat without recursion", function()
    E:OpenPanel("settings")
    local size=E.ui.options.size
    assert(size.slider,"emote scale requires a slider")
    local low,high=size.slider:GetMinMaxValues(); equal(low,12); equal(high,40)
    size.slider:SetValue(34); equal(E.db.size,34); equal(size.label:GetText(),"34 px")
    assert(E.ui.sizePreview:GetText():match("|T[^|]+:34:%d+:"))
    local _,text=B.filters.CHAT_MSG_SAY[1](chat,"CHAT_MSG_SAY",sample.name)
    assert(text:find(sample.path..":34:",1,true))
    B.type(B.editor,"keep this draft"); size.slider:Run("OnMouseDown","LeftButton")
    equal(B.editor:GetText(),"keep this draft"); equal(B.editor:HasFocus(),false)
    equal(E.ui.keyboardControl,size.slider); assert(size.slider.focusBorder[1]:IsShown())
    E.ui.panel:Run("OnKeyDown","RIGHT"); equal(E.db.size,35)
    E.ui.panel:Run("OnKeyDown","ENTER"); equal(E.db.size,35)
    E.ui.panel:Run("OnKeyDown","SPACE"); equal(E.db.size,35)
    size.slider:SetValue(12); equal(E.db.size,12)
    size.slider:SetValue(40); equal(E.db.size,40)
    E:SetOption("size",28); equal(size.slider:GetValue(),28)
end)

test("hovered chat links remain stable while other emote lines animate", function()
    local line=B.new("FontString",nil,chat); local other=B.new("FontString",nil,chat)
    line:SetText(E:Transform(animated.name)); other:SetText(E:Transform(animated.name))
    chat.visibleLines={line,other}; chat:RefreshDisplay()
    local before,otherBefore=line:GetText(),other:GetText()
    local nativeSetText=line.SetText
    -- Native text replacement invalidates the hovered hyperlink region.
    line.SetText=function(self,text) nativeSetText(self,text); B.callback("ChatFrame.OnHyperlinkLeave",chat) end
    B.callback("ChatFrame.OnHyperlinkEnter",chat,E.linkPrefix..animated.encodedName,"",line)
    assert(GameTooltip:IsShown())
    B.tick(B.time+1/animated.fps+0.001)
    assert(GameTooltip:IsShown(),"animation must not dismiss the hovered chat tooltip")
    equal(line:GetText(),before); assert(other:GetText()~=otherBefore)
    B.callback("ChatFrame.OnHyperlinkLeave",chat); equal(GameTooltip:IsShown(),false)
    B.tick(B.time+1/animated.fps+0.001); assert(line:GetText()~=before)
    line.SetText=nativeSetText; chat.visibleLines={}; chat:RefreshDisplay()
end)

print(string.format("integration: %d passed, %d failed; %d active emotes in %d packs", passed, failed, #E.names, #E.packOrder))
os.exit(failed == 0 and 0 or 1)
