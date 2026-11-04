-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
-- Usage: luajit tests/ui_spec.lua [retail|classic]
local B = dofile("tests/ui_boundary.lua")
local E = { title = "Twitch Emotes WoW Forever", version = "3.0.0", packs = {}, packOrder = { "global", "global2", "channel", "channel2" }, names = {} }
E.db = { enabled = true, size = 22, animate = true, animationFPS = 20, minimap = true, minimapAngle = 220, packs = {}, channels = { CHAT_MSG_SAY = true }, favorites = {}, recent = {}, stats = {}, hidden = {} }
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
function E:IsEmoteHidden(name) return self.db.hidden[name] == true end
function E:SetEmoteHidden(name, hidden) self.db.hidden[name] = hidden or nil; self:RefreshUI(); return true end
function E:Complete(text, cursor, limit)
    self.completeCalls = (self.completeCalls or 0) + 1
    local first, last, query = text:sub(1, cursor):find(":(Em%w*)$")
    if not first then return nil end
    return { first = first, last = last, query = query, entries = self:Search(query, limit) }
end
-- Text.lua contract: a result longer than the limit is refused with a nil position.
function E:ApplyCompletion(text, completion, name, limit)
    local result = text:sub(1, completion.first - 1) .. name .. text:sub(completion.last + 1)
    if limit and #result > limit then return text, nil end
    return result, completion.first - 1 + #name
end

local tests, passed = {}, 0
local function test(name, fn) tests[#tests + 1] = { name, fn } end
local function equal(actual, expected, message) assert(actual == expected, (message or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)) end
local function module(path) local loader = loadfile(path); if loader then loader("TwitchEmotes", E) end end
local function clean(message) assert(#B.violations == 0, (message or "addon touched Blizzard chat state") .. ": " .. table.concat(B.violations, ", ")) end
module("TwitchEmotes/UI.lua"); module("TwitchEmotes/Completion.lua")
local function suggest() return _G.ForeverEmotesSuggest end
local function suggesting() return suggest() ~= nil and suggest():IsShown() end

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
    B.active = B.editor
    B.editor.forbidden = true; equal(E:InsertEmote("Emote01"), false); B.editor.forbidden = false
    if B.editor.HasAnyForbiddenAspects then B.editor.scriptedInput = true; equal(E:InsertEmote("Emote01"), false); B.editor.scriptedInput = false end
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

test("completion attaches once and uses one bounded addon-owned suggestion list", function()
    assert(type(E.AttachCompletion) == "function", "AttachCompletion is required")
    E:AttachCompletion(B.editor); local script = B.editor:GetScript("OnTextChanged"); E:AttachCompletion(B.editor); equal(B.editor:GetScript("OnTextChanged"), script)
    B.type(B.editor, "hello :Em"); assert(suggesting())
    local shown = 0; for _, row in ipairs(suggest().rows) do if row:IsShown() then shown = shown + 1 end end
    assert(shown >= 1 and shown <= 8, "rows shown: " .. shown); equal(suggest().rows[1].selection:IsShown(), true, "first row selected")
    local point, anchor, relative = suggest():GetPoint(); equal(point, "BOTTOMLEFT"); equal(anchor, B.editor); equal(relative, "TOPLEFT")
    equal(suggest():GetFrameStrata(), "TOOLTIP"); equal(suggest():GetParent(), UIParent)
    equal(AutoCompleteBox:IsShown(), false, "the shared Blizzard box stays untouched")
end)

test("arrows choose and Tab replaces only the UTF8 byte span", function()
    B.type(B.editor, "é :Em tail", 6); assert(suggesting()); equal(B.editor:GetAltArrowKeyMode(), false, "arrows reach the box while listing")
    B.editor:Run("OnArrowPressed", "DOWN"); B.editor:Run("OnArrowPressed", "DOWN"); B.editor:Run("OnArrowPressed", "UP"); B.editor:Run("OnArrowPressed", "DOWN")
    equal(suggest().rows[3].selection:IsShown(), true)
    local custom = B.customTabs
    B.editor:Run("OnTabPressed")
    equal(B.editor:GetText(), "é Emote03 tail"); equal(B.editor:GetCursorPosition(), 10)
    equal(suggesting(), false); equal(B.editor:GetAltArrowKeyMode(), true, "arrow mode restored"); equal(B.customTabs, custom, "accepted Tab is consumed")
end)

test("suggestions show images beside plain names and leave the native rows alone", function()
    B.type(B.editor, "draft :Em")
    local row = suggest().rows[1]
    assert(row.label:GetText():find("|T", 1, true), "suggestion must show the emote image")
    assert(row.label:GetText():find(row.entry.name, 1, true), "suggestion must retain the plain name")
    assert(not row.entry.name:find("|", 1, true), "display markup must stay out of selection metadata")
    assert(row:GetHeight() >= 28, "preview needs room above and below its image")
    local shown = 0; for _, candidate in ipairs(suggest().rows) do if candidate:IsShown() then shown = shown + 1 end end
    equal(suggest():GetHeight(), shown * row:GetHeight() + 28)
    equal(AutoCompleteButton1:GetHeight(), 14); equal(AutoCompleteButton1:GetWidth(), 120); equal(AutoCompleteBox.maxHeight, 70)
    E:DismissCompletion(); equal(suggesting(), false)
end)

test("Enter sends the line as typed while suggestions are shown", function()
    B.sent = nil; B.type(B.editor, "lol :Em"); assert(suggesting())
    B.editor:Run("OnEnterPressed"); equal(B.sent, "lol :Em"); equal(suggesting(), false)
end)

test("Escape dismisses and Tab without suggestions keeps native and chained handlers", function()
    B.type(B.editor, "draft :Em"); B.editor:Run("OnEscapePressed"); equal(suggesting(), false)
    local native, custom = B.nativeTabs or 0, B.customTabs or 0
    B.type(B.editor, "plain words"); B.editor:Run("OnTabPressed")
    equal(B.nativeTabs, native + 1); equal(B.customTabs, custom + 1, "previous ChatEdit_CustomTabPressed still runs")
end)

test("a native whisper list survives an active emote session", function()
    B.editor.autoCompleteSource = function() return { { name = "Bobby", priority = Enum.AutoCompletePriority.Other } } end
    B.editor.autoCompleteParams = {}
    B.type(B.editor, "hi :Em"); assert(suggesting())
    B.type(B.editor, "/w Bo"); equal(suggesting(), false)
    equal(AutoCompleteBox:IsShown(), true, "whisper list stays open"); equal(AutoCompleteButton1.nameInfo.name, "Bobby")
    AutoComplete_HideIfAttachedTo(B.editor); equal(B.editor:GetAltArrowKeyMode(), true)
    B.editor.autoCompleteSource, B.editor.autoCompleteParams = nil, nil; B.editor:SetText("")
end)

test("completion follows the focused editor and restores each box", function()
    local other = B.editorFrame(); E:AttachCompletion(other)
    B.type(other, ":Em"); equal(select(2, suggest():GetPoint()), other); equal(other:GetAltArrowKeyMode(), false)
    B.type(B.editor, ":Em"); equal(select(2, suggest():GetPoint()), B.editor); equal(other:GetAltArrowKeyMode(), true)
    B.editor:ClearFocus(); equal(suggesting(), false); equal(B.editor:GetAltArrowKeyMode(), true)
end)

test("chat lockdown and secret text disable completion before Core is called", function()
    local before = E.completeCalls
    B.combat = true; B.type(B.editor, ":Em"); equal(E.completeCalls, before); equal(suggesting(), false); B.combat = false
    B.chatLockdown = true; B.type(B.editor, ":Em"); equal(E.completeCalls, before); equal(suggesting(), false); B.chatLockdown = false
    B.editor.text = { secret = true }; B.editor:Run("OnTextChanged", true); equal(E.completeCalls, before)
    B.editor:SetText("")
end)

test("cursor movement invalidates stale suggestions before acceptance", function()
    B.type(B.editor, ":Em suffix", 3); assert(suggesting()); B.editor:SetCursorPosition(10); equal(suggesting(), false)
    B.type(B.editor, ":Em"); B.editor.text = "changed"; B.editor.cursor = 7
    local native = B.nativeTabs
    B.editor:Run("OnTabPressed"); equal(B.editor:GetText(), "changed"); equal(suggesting(), false); equal(B.nativeTabs, native)
end)

test("incoming lockdown closes suggestions before the direct API changes", function()
    B.type(B.editor, ":Em"); equal(B.chatLockdown, false); assert(suggesting())
    B.event("ADDON_RESTRICTION_STATE_CHANGED", Enum.AddOnRestrictionType.Chat, Enum.AddOnRestrictionState.Activating)
    equal(suggesting(), false)
    B.type(B.editor, ":Em"); B.event("PLAYER_REGEN_DISABLED"); equal(suggesting(), false)
end)

test("slash commands and native backspace suppression offer nothing", function()
    B.type(B.editor, "/s :Em"); equal(suggesting(), false); equal(AutoCompleteBox:IsShown(), false, "no emote rows in any list")
    B.editor.disallowAutoComplete = true; B.type(B.editor, "hey :Em"); equal(suggesting(), false); B.editor.disallowAutoComplete = nil
    B.editor:SetText("")
end)

test("a click on a row applies it, also after retail moved focus off the box", function()
    B.type(B.editor, "pick :Em"); suggest().mouseOver = true
    B.editor:ClearFocus(); assert(suggesting(), "focus lost to a click on the list keeps it open")
    suggest().rows[2]:Click(); equal(B.editor:GetText(), "pick Emote02"); equal(suggesting(), false)
    suggest().mouseOver = false
    B.type(B.editor, "x :Em"); B.editor:ClearFocus(); equal(suggesting(), false)
    B.editor:SetText("")
end)

test("completion refuses to overflow the chat line", function()
    local draft = string.rep("a", 248) .. " :Em"
    B.type(B.editor, draft); assert(suggesting()); B.editor:Run("OnTabPressed")
    equal(B.editor:GetText(), draft, "a completion past 255 bytes is not applied")
    B.type(B.editor, "short :Em"); B.editor:Run("OnTabPressed"); equal(B.editor:GetText(), "short Emote01")
    B.editor:SetText("")
end)

test("typing, choosing, accepting, escaping, losing focus and sending never touch Blizzard chat state", function()
    B.active = B.editor; B.resetTrace()
    B.type(B.editor, "draft :Em"); assert(suggesting())
    B.editor:Run("OnArrowPressed", "DOWN"); B.editor:Run("OnArrowPressed", "UP")
    B.editor:Run("OnTabPressed"); equal(B.editor:GetText(), "draft Emote01")
    B.type(B.editor, "more :Em"); B.editor:Run("OnEscapePressed")
    B.type(B.editor, "again :Em"); B.editor:ClearFocus()
    B.type(B.editor, "send :Em"); B.editor:Run("OnEnterPressed"); equal(B.sent, "send :Em")
    clean()
    -- Any addon text edit runs Blizzard's OnTextChanged tainted; it may only reset the box's own tab-completion scratch fields.
    local residual = { ["editor.lastTabComplete"] = true, ["editor.tabCompleteText"] = true, ["editor.tabCompleteTableIndex"] = true, ["editor.ignoreTextChange"] = true, ["AutoComplete_HideIfAttachedTo()"] = true }
    for _, entry in ipairs(B.tainted) do assert(residual[entry], "tainted Blizzard state: " .. entry) end
    equal(AutoCompleteBox.maxHeight, 70); equal(AutoCompleteBox.parent, nil)
    equal(B.editor.autoCompleteSource, nil); equal(B.editor.customAutoCompleteFunction, nil)
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
print(string.format("%d UI tests passed (%s profile)", passed, B.profileName))
