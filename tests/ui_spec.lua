-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
local B = dofile("tests/ui_boundary.lua")
local E = { title = "Twitch Emotes WoW Forever", version = "3.0.0", packs = {}, packOrder = { "global", "global2", "channel", "channel2" }, names = {} }
E.db = { enabled = true, size = 22, animate = true, animationFPS = 20, minimap = true, minimapAngle = 220, packs = {}, channels = { CHAT_MSG_SAY = true }, favorites = {}, recent = {}, stats = {} }
for i = 1, 48 do E.names[i] = { name = string.format("Emote%02d", i), path = "Interface\\AddOns\\TwitchEmotes\\Media\\test.tga", width = 64, height = 32, frames = 1, sheetWidth = 64, sheetHeight = 32, provider = "7TV", creator = "A creator", packID = i <= 16 and "global" or (i <= 24 and "global2" or "channel") } end
E.packs.global = { id = "global", title = "Global", provider = "7TV" }
E.packs.channel = { id = "channel", title = "Channel", provider = "BTTV" }
E.packs.global2 = { id = "global2", title = "Global 2", provider = "BTTV" }
E.packs.channel2 = { id = "channel2", title = "Channel 2", provider = "Twitch" }
E.groups = { { id = "general", title = "General", packIDs = { "global", "global2" } }, { id = "forsen", title = "Forsen", packIDs = { "channel", "channel2" } } }
function E:GetGroups() return self.groups end
function E:SetGroupEnabled(id, enabled)
    for _, group in ipairs(self.groups) do if group.id == id then for _, packID in ipairs(group.packIDs) do self.db.packs[packID] = enabled end end end
    self:RefreshUI()
end
function E:GetEmote(name) for _, entry in ipairs(self.names) do if entry.name == name then return entry end end end
function E:Search(query, limit, mode, packID)
    local results = {}
    for _, entry in ipairs(self.names) do
        if self.db.packs[entry.packID] ~= false and entry.name:lower():find(query:lower(), 1, true) and (not packID or entry.packID == packID or type(packID) == "table" and packID[entry.packID]) and (mode ~= "favorites" or self.db.favorites[entry.name]) and (mode ~= "recent" or self.db.recent[1] == entry.name) then
            results[#results + 1] = entry; if #results == limit then break end
        end
    end
    return results
end
function E:Stats(name) return self.db.stats[name] or { sent = 0, seen = 0 } end
function E:Render(entry) return "|T" .. entry.path .. ":22:44|t" end
function E:SetOption(key, value) self.db[key] = value; self:RefreshUI() end
function E:SetPackEnabled(id, enabled) self.db.packs[id] = enabled; self:RefreshUI() end
function E:ToggleFavorite(name) self.db.favorites[name] = not self.db.favorites[name] or nil; self:RefreshUI(); return self.db.favorites[name] end
function E:Complete(text, cursor, limit)
    self.completeCalls = (self.completeCalls or 0) + 1
    local first, last, query = text:sub(1, cursor):find(":(Em%w*)$")
    if not first then return nil end
    return { first = first, last = last, query = query, entries = self:Search(query, limit) }
end
function E:ApplyCompletion(text, completion, name)
    return text:sub(1, completion.first - 1) .. name .. text:sub(completion.last + 1), completion.first - 1 + #name
end

local tests, passed = {}, 0
local function test(name, fn) tests[#tests + 1] = { name, fn } end
local function equal(actual, expected, message) assert(actual == expected, (message or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)) end
local function module(path) local loader = loadfile(path); if loader then loader("TwitchEmotes", E) end end
module("TwitchEmotes/UI.lua"); module("TwitchEmotes/Completion.lua")

test("panel construction is lazy and reused across search, pages and settings", function()
    assert(type(E.InitializeUI) == "function", "InitializeUI is required")
    E:InitializeUI(); local before = #B.frames; E:InitializeUI(); equal(#B.frames, before); equal(B.categories, 1)
    E:OpenPanel(); assert(B.find("Search emotes")); local created = #B.frames
    for _ = 1, 6 do B.find("Next page"):Click() end
    B.find("Settings"):Click(); B.find("Browse"):Click()
    E:OpenPanel(); equal(#B.frames, created, "recycled frame pool")
end)

test("picker inserts only a plain name at the current chat cursor", function()
    B.editor = B.editorFrame(); B.active = B.editor; B.type(B.editor, "hello world", 5)
    assert(E:InsertEmote("Emote01")); equal(B.editor:GetText(), "hello Emote01 world")
    assert(not B.editor:GetText():find("|", 1, true)); equal(E:InsertEmote("unknown"), false)
end)

test("insertion chooses an editor without discarding an unsent draft", function()
    B.active = nil; B.editor:SetText("draft ")
    assert(E:InsertEmote("Emote02")); equal(B.editor:GetText(), "draft Emote02 ")
end)

test("secret and forbidden editor values never reach text processing", function()
    B.editor.forbidden = true; equal(E:InsertEmote("Emote01"), false); B.editor.forbidden = false
    B.editor.scriptedInput = true; equal(E:InsertEmote("Emote01"), false); B.editor.scriptedInput = false
    B.editor.text = { secret = true }; equal(E:InsertEmote("Emote01"), false)
    B.editor:SetText("draft"); B.editor.cursor = { secret = true }; equal(E:InsertEmote("Emote01"), false)
    B.editor:SetText("")
end)

test("favorites, recent, search and channel groups repaint existing rows", function()
    E:OpenPanel(); E:ToggleFavorite("Emote07"); B.find("Favorites"):Click()
    assert(B.find("Emote07"):IsVisible()); assert(not B.find("Emote01") or not B.find("Emote01"):IsVisible())
    E.db.recent = { "Emote02" }; B.find("Recent"):Click(); assert(B.find("Emote02"):IsVisible())
    B.find("All"):Click(); assert(E.ui.groupRows, "visible group navigation is required")
    B.find("Forsen", E.ui.sidebar):Click(); equal(E.ui.results[1].name, "Emote25")
    B.find("Settings"):Click(); B.find("Enable this group"):Click(); equal(E.db.packs.channel, false); equal(E.db.packs.channel2, false)
    B.find("Enable this group"):Click(); B.find("General", E.ui.sidebar):Click(); B.find("Browse"):Click()
    local search = E.ui.search; B.type(search, "Emote10"); assert(B.find("Emote10"):IsVisible())
    B.find("Clear"):Click(); equal(search:GetText(), "")
end)

test("General combines providers and long channel lists recycle a bounded sidebar", function()
    E:OpenPanel("browse"); equal(#E.ui.results, 24); equal(E.ui.results[24].name, "Emote24")
    local original, frameCount = E.groups, #B.frames
    E.groups = { original[1], original[2] }
    for i = 1, 64 do E.groups[#E.groups + 1] = { id = "channel" .. i, title = "Channel " .. i, packIDs = {} } end
    E:RefreshUI(); E.ui.groupScroll:SetScrollPercentage(1)
    equal(E.ui.groupRows[#E.ui.groupRows]:GetText(), "Channel 64"); equal(#B.frames, frameCount)
    B.type(E.ui.groupSearch, "Forsen"); equal(E.ui.groupRows[1]:GetText(), "Forsen"); equal(E.ui.groupRows[2]:IsShown(), false)
    E.groups = original; E.ui.groupSearch:SetText(""); B.find("General", E.ui.sidebar):Click()
end)

test("manual channel picker offers checkboxes and returns to Browse", function()
    E.db.setupComplete = false; E.db.packs.global = true; E.db.packs.global2 = true; E.db.packs.channel = false; E.db.packs.channel2 = false
    E:OpenPanel("settings"); E.ui.manageGroups:Click()
    equal(E.ui.tab, "setup"); equal(E.ui.setupRows[1]:GetChecked(), true); equal(E.ui.setupRows[2]:GetChecked(), false)
    equal(E.ui.setupDone:GetText(), "Done")
    E.ui.setupRows[2]:Click(); equal(E.db.packs.channel, true); equal(E.db.packs.channel2, true)
    E.ui.setupDone:Click(); equal(E.db.setupComplete, true); equal(E.ui.tab, "browse")
    E:OpenPanel("settings"); E.ui.priorityButton:Click(); equal(E.db.preferredGroup, "general")
end)

test("minimap launcher draws above the native rim in the minimap's strata", function()
    equal(E.ui.minimap:GetFrameStrata(), MinimapBackdrop:GetFrameStrata())
    assert(E.ui.minimap:GetFrameLevel() > MinimapBackdrop:GetFrameLevel(), "native minimap rim must not cover the launcher")
end)

test("settings and minimap visibility update saved values", function()
    B.find("Settings"):Click(); B.find("Show minimap button"):Click(); equal(E.db.minimap, false); equal(E.ui.minimap:IsShown(), false)
    B.find("Show minimap button"):Click(); equal(E.ui.minimap:IsShown(), true)
    B.find("Say"):Click(); equal(E.db.channels.CHAT_MSG_SAY, false)
    E.ui.options.size.slider:SetValue(23); equal(E.db.size, 23)
    E.ui.minimap:Run("OnDragStart"); E.ui.minimap:Run("OnUpdate", 0.016); E.ui.minimap:Run("OnDragStop")
    equal(math.floor(E.db.minimapAngle), 0); equal(E.ui.minimap:GetScript("OnUpdate"), nil)
end)

test("animation settings offer 15, 30 and 60 FPS and stop at the bounds", function()
    B.find("Increase animation fps"):Click(); equal(E.db.animationFPS, 30)
    B.find("Increase animation fps"):Click(); equal(E.db.animationFPS, 60)
    B.find("Increase animation fps"):Click(); equal(E.db.animationFPS, 60)
    B.find("Decrease animation fps"):Click(); equal(E.db.animationFPS, 30)
    B.find("Decrease animation fps"):Click(); equal(E.db.animationFPS, 15)
    B.find("Decrease animation fps"):Click(); equal(E.db.animationFPS, 15)
end)

test("panel keyboard navigation consumes its keys and releases chat input", function()
    E.ui.panel:Hide(); E:OpenPanel("browse")
    B.focus = nil; E.ui.panel:Run("OnKeyDown", "TAB"); equal(E.ui.panel.propagate, false)
    E.ui.panel:Run("OnKeyDown", "ENTER"); equal(E.ui.panel.propagate, false)
    equal(E.ui.tab, "settings", "keyboard traversal skips the disabled current tab")
    B.editor:SetFocus(); E.ui.panel:Run("OnKeyDown", "A"); equal(E.ui.panel.propagate, true)
end)

test("closing the configuration window releases search focus and can reopen", function()
    E:OpenPanel("browse"); E.ui.search:SetFocus(); E.ui.panel.CloseButton:Click()
    equal(E.ui.panel:IsShown(), false); equal(E.ui.search:HasFocus(), false)
    E.ui.minimap:Click(); equal(E.ui.panel:IsShown(), true)
end)

test("completion attaches once and uses one bounded native suggestion list", function()
    assert(type(E.AttachCompletion) == "function", "AttachCompletion is required")
    E:AttachCompletion(B.editor); local script = B.editor:GetScript("OnTextChanged"); E:AttachCompletion(B.editor); equal(B.editor:GetScript("OnTextChanged"), script)
    B.type(B.editor, "hello :Em"); assert(AutoCompleteBox:IsShown()); assert(#AutoCompleteBox.results <= 8)
    equal(AutoCompleteBox.parent, B.editor)
    equal(#B.editor.autoCompleteSource("unrelated native OnChar", 1, 1, true), 0, "source must not inline-replace chat text")
end)

test("Tab and arrows select then Enter replaces only the UTF8 byte span", function()
    B.type(B.editor, "é :Em tail", 6)
    B.editor:Run("OnTabPressed"); B.editor:Run("OnArrowPressed", "DOWN"); B.editor:Run("OnEnterPressed")
    equal(B.editor:GetText(), "é Emote03 tail"); equal(B.editor:GetCursorPosition(), 10)
    equal(AutoCompleteBox:IsShown(), false)
end)

test("autocomplete previews show images and restore native row sizes on close", function()
    B.type(B.editor, "draft :Em")
    local info = AutoCompleteBox.results[1]
    local button = AutoCompleteButton1
    assert(button:GetText():find("|T", 1, true), "suggestion must show the emote image")
    assert(button:GetText():find(info.name, 1, true), "suggestion must retain the plain name")
    assert(not info.name:find("|", 1, true), "display markup must stay out of selection metadata")
    assert(button:GetHeight() >= 28, "preview needs room above and below its image")
    equal(AutoCompleteBox:GetHeight(), #AutoCompleteBox.results * button:GetHeight() + 35)
    B.editor:Run("OnEscapePressed")
    equal(button:GetHeight(), 14); equal(button:GetWidth(), 120); equal(AutoCompleteBox.maxHeight, 70)
    equal(B.editor:GetText(), "draft :Em")
end)

test("native player suggestions regain their layout without closing the popup", function()
    B.type(B.editor, ":Em")
    AutoComplete_UpdateResults(AutoCompleteBox, {{name="AnotherPlayer", priority=Enum.AutoCompletePriority.Other}})
    equal(AutoCompleteButton1:GetText(), "AnotherPlayer"); equal(AutoCompleteButton1:GetHeight(), 14)
    equal(AutoCompleteBox:GetHeight(), 49); equal(AutoCompleteBox.maxHeight, 70)
    E:DismissCompletion()
end)

test("Escape dismisses without clearing the draft and normal Tab is preserved", function()
    B.type(B.editor, "draft :Em"); B.editor:Run("OnEscapePressed"); equal(B.editor:GetText(), "draft :Em"); equal(AutoCompleteBox:IsShown(), false)
    B.editor:Run("OnTabPressed"); equal(B.nativeTabs, 1)
end)

test("completion preserves other sources and restores callbacks on focus loss", function()
    local other = B.editorFrame(); local original = function() return {} end; local callback = function() return "native" end
    other.autoCompleteSource = original; other.autoCompleteParams = { "whisper" }; other.customAutoCompleteFunction = callback
    E:AttachCompletion(other); B.type(other, ":Em")
    other:ClearFocus(); equal(other.autoCompleteSource, original); equal(other.autoCompleteParams[1], "whisper"); equal(other.customAutoCompleteFunction, callback)
    B.type(other, "/w Friend"); equal(other.autoCompleteSource, original)
    B.type(other, ":Em"); B.editor:SetText(""); B.editor:SetFocus(); equal(AutoCompleteBox:IsShown(), false); equal(other.autoCompleteSource, original)
end)

test("lockdown and secret text disable completion before Core is called", function()
    local before = E.completeCalls
    B.combat = true; B.type(B.editor, ":Em"); equal(E.completeCalls, before); equal(AutoCompleteBox:IsShown(), false); B.combat = false
    B.chatLockdown = true; B.type(B.editor, ":Em"); equal(E.completeCalls, before); B.chatLockdown = false
    B.editor.text = { secret = true }; B.editor:Run("OnTextChanged", true); equal(E.completeCalls, before)
    B.editor:SetText("")
end)

test("cursor movement invalidates stale suggestions before acceptance", function()
    B.type(B.editor, ":Em suffix", 3); B.editor:SetCursorPosition(10); equal(AutoCompleteBox:IsShown(), false)
    B.type(B.editor, ":Em"); B.editor.text = "changed"; B.editor.cursor = 7
    B.editor:Run("OnEnterPressed"); equal(B.editor:GetText(), "changed"); equal(AutoCompleteBox:IsShown(), false)
end)

test("incoming lockdown closes suggestions before the direct API changes", function()
    B.type(B.editor, ":Em"); equal(B.chatLockdown, false)
    B.event("ADDON_RESTRICTION_STATE_CHANGED", Enum.AddOnRestrictionType.Chat, Enum.AddOnRestrictionState.Activating)
    equal(AutoCompleteBox:IsShown(), false)
    B.type(B.editor, ":Em"); B.event("PLAYER_REGEN_DISABLED"); equal(AutoCompleteBox:IsShown(), false)
end)

test("native callback chains and source resets survive an active colon session", function()
    local editor = B.editorFrame(); local called = 0
    local before, changed = function() return {} end, function() return {} end
    editor.autoCompleteSource = before; editor.autoCompleteParams = { "before" }
    editor.customAutoCompleteFunction = function(_, _, info) called = called + 1; return info.native end
    E:AttachCompletion(editor); B.type(editor, ":Em")
    equal(editor.customAutoCompleteFunction(editor, "friend", { native = true }, "friend"), true); equal(called, 1)
    editor.autoCompleteSource = changed; editor.autoCompleteParams = { "new" }
    editor:Run("OnTextChanged", true); editor:ClearFocus()
    equal(editor.autoCompleteSource, changed); equal(editor.autoCompleteParams[1], "new")
end)

test("whisper display toggles cover outgoing echoes and preserve other channels", function()
    E.db.channels.CHAT_MSG_CHANNEL = true; E.db.channels.CHAT_MSG_WHISPER = true; E.db.channels.CHAT_MSG_WHISPER_INFORM = true
    E:OpenPanel("settings"); B.find("Whispers"):Click()
    equal(E.db.channels.CHAT_MSG_WHISPER, false); equal(E.db.channels.CHAT_MSG_WHISPER_INFORM, false); equal(E.db.channels.CHAT_MSG_CHANNEL, true)
end)

for _, case in ipairs(tests) do
    local ok, err = pcall(case[2])
    if not ok then io.stderr:write("FAIL " .. case[1] .. "\n" .. tostring(err) .. "\n"); os.exit(1) end
    passed = passed + 1; print("PASS " .. case[1])
end
print(string.format("%d UI tests passed", passed))
