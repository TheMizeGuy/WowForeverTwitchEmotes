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
-- Text.lua contract: a result whose visible bytes exceed the limit is refused with a nil position; the real counter
-- is borrowed from Text.lua so markup in a draft is measured the way the shipped addon measures it.
do local T = {}; loadfile("TwitchEmotes/Text.lua")("TwitchEmotes", T); E.VisibleTextBytes = T.VisibleTextBytes end
function E:ApplyCompletion(text, completion, name, limit)
    local result = text:sub(1, completion.first - 1) .. name .. text:sub(completion.last + 1)
    if limit and self:VisibleTextBytes(result) > limit then return text, nil end
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

test("first panel and menu opened in combat keep every key flowing", function()
    B.combat = true
    E:InitializeUI(); E:OpenPanel()
    equal(E.ui.panel.propagate, true, "panel created in combat propagates"); equal(B.blocked, nil, "blocked propagation calls")
    E.ui.panel:Run("OnKeyDown", "W"); equal(E.ui.panel.propagate, true); equal(B.blocked, nil)
    assert(E:OpenEmoteMenu("Emote01")); local menu = E.ui.emoteMenu
    equal(menu.propagate, true, "menu created in combat propagates")
    menu:Run("OnKeyDown", "1"); menu:Run("OnKeyDown", "SPACE")
    equal(B.blocked, nil); equal(menu.propagate, true); equal(E:IsEmoteHidden("Emote01"), false)
    B.combat = false; menu:Hide(); E.ui.panel:Hide()
end)

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

test("insertion needs a chat box the player opened and never activates one", function()
    B.active = nil; B.editor:SetText("draft "); B.resetTrace()
    equal(B.call(E.InsertEmote, E, "Emote02"), false); equal(B.editor:GetText(), "draft ")
    equal(E.ui.hint:GetText(), "Press Enter to open chat, then Shift-click the emote.")
    E:OpenPanel("browse"); E.ui.rows[1]:Click(); E.ui.search:Run("OnEnterPressed")
    equal(B.editor:GetText(), "draft "); clean("no chat activation without an open box")
    B.active = B.editor; B.editor:SetText("/1 x")
    equal(B.call(E.InsertEmote, E, "Emote02"), false); equal(B.editor:GetText(), "/1 x"); clean()
    B.editor:SetText("")
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

test("minimap rim uses the Mainline atlas only where the client has it", function()
    local background = E.ui.minimap.background
    if B.mainline then
        equal(background.atlas, "ui-hud-minimap-button"); assert(C_Texture.GetAtlasInfo(background.atlas))
        equal(E.ui.minimap.border, nil)
    else
        equal(background.atlas, nil); equal(background.texture, "Interface\\Minimap\\UI-Minimap-Background")
        local border = E.ui.minimap.border
        equal(border.texture, "Interface\\Minimap\\MiniMap-TrackingBorder"); equal(border:GetWidth(), 52); equal(border:GetPoint(), "TOPLEFT")
        equal(E.ui.minimap:GetWidth(), 33)
    end
end)

test("square minimaps keep the launcher on the square's edge", function()
    local radius = Minimap:GetWidth() / 2 + 2
    local function offset() local point = E.ui.minimap.point; return point[4], point[5] end
    _G.GetMinimapShape = function() return "SQUARE" end
    E.db.minimapAngle = 45; E:RefreshUI()
    local x, y = offset(); assert(math.abs(x - radius) < 1 and math.abs(y - radius) < 1, "45 degrees sits on the corner: " .. x .. ", " .. y)
    E.db.minimapAngle = 30; E:RefreshUI(); x, y = offset()
    assert(math.abs(x - radius) < 1 and y > 0 and y < radius, "30 degrees rides the right edge: " .. x .. ", " .. y)
    _G.GetMinimapShape = nil; E.db.minimapAngle = 45; E:RefreshUI(); x, y = offset()
    assert(math.abs(x * x + y * y - radius * radius) < 1, "round minimaps keep the circle")
    E.db.minimapAngle = 220; E:RefreshUI()
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

test("channel toggles include Guild Discord where the client has it and fit the settings frame", function()
    E:OpenPanel("settings")
    local discord = E.ui.channels.CHAT_MSG_GUILD_DISCORD
    if B.mainline then assert(discord, "Guild Discord toggle missing"); equal(discord.Text:GetText(), "Guild Discord")
    else equal(discord, nil, "classic clients have no Guild Discord event") end
    local seen, count = {}, 0
    for _, control in pairs(E.ui.channels) do
        local _, _, _, x, y = control:GetPoint()
        assert(y <= -228 and y - control:GetHeight() >= -462, "channel toggle leaves the settings frame at y=" .. y)
        assert(not seen[x .. ":" .. y], "two channel toggles overlap"); seen[x .. ":" .. y] = true; count = count + 1
    end
    equal(count, B.mainline and 17 or 16)
end)

test("an idle panel lets Enter, Space and arrows reach the game; Tab over it starts navigation", function()
    E.ui.panel:Hide(); E:OpenPanel("browse"); B.focus = nil; E.ui.panel.mouseOver = false
    for _, key in ipairs({ "ENTER", "SPACE", "UP", "DOWN", "LEFT", "RIGHT", "TAB" }) do
        E.ui.panel:Run("OnKeyDown", key); equal(E.ui.panel.propagate, true, key .. " propagates"); equal(E.ui.tab, "browse"); equal(E.ui.keyboardControl, nil)
    end
    E.ui.panel.mouseOver = true
    E.ui.panel:Run("OnKeyDown", "TAB"); equal(E.ui.panel.propagate, false)
    E.ui.panel:Run("OnKeyDown", "ENTER"); equal(E.ui.panel.propagate, false)
    equal(E.ui.tab, "settings", "keyboard traversal skips the disabled current tab")
    B.editor:SetFocus(); E.ui.panel:Run("OnKeyDown", "A"); equal(E.ui.panel.propagate, true)
    B.editor:ClearFocus(); E.ui.panel.mouseOver = false
end)

test("keyboard capture is released before combat and never changed during it", function()
    E:OpenPanel("browse"); B.focus = nil; E.ui.panel.mouseOver = true
    E.ui.panel:Run("OnKeyDown", "TAB"); equal(E.ui.panel.propagate, false)
    B.event("PLAYER_REGEN_DISABLED"); B.combat = true; B.blocked = nil
    E.ui.panel:Run("OnKeyDown", "1"); E.ui.panel:Run("OnKeyDown", "TAB")
    equal(B.blocked, nil, "no restricted call in combat"); equal(E.ui.panel.propagate, true)
    B.combat = false
    E.ui.panel:Run("OnKeyDown", "TAB"); equal(E.ui.panel.propagate, false); E.ui.panel.CloseButton:Click()
    equal(E.ui.panel.propagate, true, "hiding the panel hands keys back")
    E:OpenEmoteMenu("Emote02"); local menu = E.ui.emoteMenu; menu.mouseOver = true
    menu:Run("OnKeyDown", "TAB"); equal(menu.propagate, false)
    B.event("PLAYER_REGEN_DISABLED"); B.combat = true
    menu:Run("OnKeyDown", "1"); menu:Run("OnKeyDown", "SPACE")
    equal(B.blocked, nil); equal(menu.propagate, true); equal(E:IsEmoteHidden("Emote02"), false)
    B.combat = false; menu.mouseOver = false; menu:Hide(); E.ui.panel.mouseOver = false
end)

test("the emote menu opens with nothing selected and acts only after keyboard focus moves into it", function()
    B.focus = nil; E:OpenEmoteMenu("Emote03"); local menu = E.ui.emoteMenu; menu.mouseOver = false
    equal(menu.hideEmote.highlighted, false, "nothing preselected")
    menu:Run("OnKeyDown", "ENTER"); equal(E:IsEmoteHidden("Emote03"), false); equal(menu.propagate, true)
    menu:Run("OnKeyDown", "SPACE"); equal(E:IsEmoteHidden("Emote03"), false); equal(menu.propagate, true)
    menu:Run("OnKeyDown", "TAB"); equal(menu.propagate, true, "Tab away from the menu reaches the game"); equal(menu.focusIndex, nil)
    menu.mouseOver = true
    menu:Run("OnKeyDown", "TAB"); equal(menu.focusIndex, 1); equal(menu.hideEmote.highlighted, true); equal(menu.propagate, false)
    menu:Run("OnKeyDown", "ENTER"); equal(E:IsEmoteHidden("Emote03"), true); equal(menu:IsShown(), false)
    E:SetEmoteHidden("Emote03", false)
    E:OpenEmoteMenu("Emote03"); equal(menu.focusIndex, nil)
    menu:Run("OnKeyDown", "ESCAPE"); equal(menu:IsShown(), false); equal(menu.propagate, false, "Escape stays with the menu")
    menu.mouseOver = false
end)

test("tooltips follow row content and only the owner's window hides them", function()
    E:OpenPanel("browse"); E.ui.mode = "all"; E.ui.page = 1; E:RefreshUI()
    local row = E.ui.rows[1]; row:Run("OnEnter"); equal(GameTooltip.lines[1], row.entry.name)
    E.ui.browse:Run("OnMouseWheel", -1); equal(E.ui.page, 2)
    equal(GameTooltip:GetOwner(), row); equal(GameTooltip.lines[1], row.entry.name, "tooltip names the emote now under the cursor")
    row.favorite:Run("OnEnter"); equal(GameTooltip.lines[1], "Add favorite")
    row.favorite:Click(); equal(GameTooltip.lines[1], "Remove favorite"); row.favorite:Click()
    local other = B.new("Frame", nil, UIParent)
    E:OpenEmoteMenu("Emote01"); GameTooltip:SetOwner(other); GameTooltip:Show()
    E.ui.emoteMenu:Hide(); equal(GameTooltip:IsShown(), true, "menu leaves a foreign tooltip alone")
    E.ui.panel:Hide(); equal(GameTooltip:IsShown(), true, "panel leaves a foreign tooltip alone")
    E:OpenPanel("browse"); E.ui.rows[2]:Run("OnEnter"); E.ui.panel:Hide(); equal(GameTooltip:IsShown(), false)
    E.ui.page = 1
end)

test("the size slider clears only the addon's own inputs, also in combat", function()
    E:OpenPanel("settings"); local slider = E.ui.options.size.slider
    E.ui.groupSearch:SetFocus(); B.combat = true
    slider:Run("OnMouseDown", "LeftButton"); B.combat = false
    equal(E.ui.groupSearch:HasFocus(), false); equal(E.ui.keyboardControl, slider)
    B.active = B.editor; B.editor:SetFocus(); B.resetTrace()
    slider:Run("OnMouseDown", "LeftButton"); equal(B.editor:HasFocus(), true, "chat focus stays with the player"); clean()
    B.editor:ClearFocus()
end)

test("Clear buttons never pull focus away from an open chat box", function()
    E:OpenPanel("browse"); B.active = B.editor; B.editor:SetText("draft"); B.editor:SetFocus(); B.resetTrace()
    E.ui.clear:Click(); equal(B.editor:HasFocus(), true); equal(E.ui.search:HasFocus(), false); clean()
    E:OpenPanel("setup"); E.ui.setupClear:Click(); equal(B.editor:HasFocus(), true, "the Setup tab's Clear is guarded too"); equal(E.ui.setupSearch:HasFocus(), false); clean()
    E:OpenPanel("browse"); B.editor:ClearFocus(); E.ui.clear:Click(); equal(E.ui.search:HasFocus(), true)
    E.ui.search:ClearFocus(); B.editor:Show(); B.editor:SetText("")
end)

test("combat alone does not disable insertion or completion; chat lockdown does", function()
    E:AttachCompletion(B.editor); B.active = B.editor; B.editor:SetText(""); B.combat = true; B.chatLockdown = false
    assert(E:InsertEmote("Emote04"), "insert works in combat without chat lockdown")
    B.type(B.editor, "fight :Em"); assert(suggesting(), "completion works in combat")
    B.chatLockdown = true; local calls = E.completeCalls
    equal(E:InsertEmote("Emote04"), false); B.type(B.editor, "fight :Em"); equal(suggesting(), false); equal(E.completeCalls, calls)
    B.combat = false; B.chatLockdown = false; B.editor:SetText("")
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

test("Escape closes chat as Blizzard does and Tab without suggestions keeps native and chained handlers", function()
    -- Blizzard's OnEscapePressed clears the line unless its own list is attached; the addon's list cannot change that.
    B.type(B.editor, "draft :Em"); B.editor:Run("OnEscapePressed"); equal(suggesting(), false)
    equal(B.editor:GetText(), "", "Escape clears the draft, as documented"); equal(B.editor:HasFocus(), false)
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
    equal(B.editor:GetAltArrowKeyMode(), false, "the native list keeps the arrows while it is open")
    B.type(B.editor, "/w Bob"); equal(AutoCompleteBox:IsShown(), true); equal(B.editor:GetAltArrowKeyMode(), false)
    -- Escape closes Blizzard's list the way the client does; the addon's hook then puts the arrow mode back.
    B.editor:Run("OnEscapePressed"); equal(AutoCompleteBox:IsShown(), false)
    equal(B.editor:GetAltArrowKeyMode(), true, "the arrow mode comes back once the native list is gone")
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
    B.combat = true; B.type(B.editor, ":Em"); assert(E.completeCalls > before, "combat alone keeps completion"); assert(suggesting()); B.combat = false
    before = E.completeCalls
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

test("a click on a suggestion row applies it and chat keeps focus on both engines", function()
    B.type(B.editor, "pick :Em"); assert(suggesting()); suggest().mouseOver = true
    B.mouseDown(suggest().rows[2]); assert(suggesting(), "a mouse-down on the list keeps it open"); equal(B.editor:HasFocus(), true, "chat keeps focus through the click")
    suggest().rows[2]:Click(); equal(B.editor:GetText(), "pick Emote02"); equal(suggesting(), false)
    equal(B.editor:HasFocus(), true, "chat is still focused after the pick"); equal(B.editor:IsShown(), true)
    suggest().mouseOver = false
    B.type(B.editor, "x :Em"); B.mouseDown(UIParent); equal(suggesting(), false); equal(B.editor:HasFocus(), false, "a click elsewhere still clears chat focus")
    B.editor:Show(); B.editor:SetText("")
end)

test("completion and insertion refuse to overflow the chat line", function()
    local draft = string.rep("a", 248) .. " :Em"
    B.type(B.editor, draft); assert(suggesting()); B.editor:Run("OnTabPressed")
    equal(B.editor:GetText(), draft, "a completion past 255 bytes is not applied")
    B.type(B.editor, "short :Em"); B.editor:Run("OnTabPressed"); equal(B.editor:GetText(), "short Emote01")
    -- Link markup does not count toward the chat box's visible-byte limit.
    local link = "|cff0070dd|Hitem:19019::::::::70:::::|h[Thunderfury, Blessed Blade of the Windseeker]|h|r"
    local linked = string.rep("a", 190) .. " " .. link .. " :Em"
    assert(#linked > 255, "raw bytes exceed the limit"); B.type(B.editor, linked); assert(suggesting()); B.editor:Run("OnTabPressed")
    equal(B.editor:GetText(), string.rep("a", 190) .. " " .. link .. " Emote01", "a completion that fits in visible bytes applies")
    B.active = B.editor; B.editor:SetText(string.rep("b", 250))
    equal(E:InsertEmote("Emote01"), false); equal(B.editor:GetText(), string.rep("b", 250)); equal(E.ui.hint:GetText(), "The chat line is full.")
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

test("every insertion path leaves chat activation and focus to the player", function()
    B.active = B.editor; B.editor:SetText("x "); B.editor:SetCursorPosition(2); B.resetTrace()
    E:OpenPanel("browse"); E.ui.mode = "all"; E:RefreshUI()
    local name = E.ui.rows[1].entry.name
    E.ui.rows[1]:Click(); assert(B.editor:GetText():find(name, 1, true))
    E.ui.search:Run("OnEnterPressed")
    E:OpenEmoteMenu("Emote05"); B.find("Insert name in chat", E.ui.emoteMenu):Click(); assert(B.editor:GetText():find("Emote05", 1, true))
    clean()
    B.active = nil; local before = B.editor:GetText()
    E:OpenEmoteMenu("Emote06"); B.find("Insert name in chat", E.ui.emoteMenu):Click()
    equal(B.editor:GetText(), before); clean(); B.editor:SetText("")
end)

test("whisper display toggles cover outgoing echoes and preserve other channels", function()
    E.db.channels.CHAT_MSG_CHANNEL = true; E.db.channels.CHAT_MSG_WHISPER = true; E.db.channels.CHAT_MSG_WHISPER_INFORM = true
    E:OpenPanel("settings"); B.find("Whispers"):Click()
    equal(E.db.channels.CHAT_MSG_WHISPER, false); equal(E.db.channels.CHAT_MSG_WHISPER_INFORM, false); equal(E.db.channels.CHAT_MSG_CHANNEL, true)
end)

for _, case in ipairs(tests) do
    local ok, err = pcall(case[2])
    if ok and #B.violations > 0 then ok, err = false, "addon touched Blizzard chat state: " .. table.concat(B.violations, ", ") end
    if not ok then io.stderr:write("FAIL " .. case[1] .. "\n" .. tostring(err) .. "\n"); os.exit(1) end
    passed = passed + 1; print("PASS " .. case[1])
end
print(string.format("%d UI tests passed (%s profile)", passed, B.profileName))
