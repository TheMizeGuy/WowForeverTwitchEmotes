local addonName, E = ...
-- Copyright (c) 2026 TheMizeGuy. All rights reserved.

local ROWS, COLUMNS = 6, 2
local PAGE_SIZE = ROWS * COLUMNS
local GROUP_ROWS, SETUP_ROWS = 12, 16
local PANEL_WIDTH, PANEL_HEIGHT = 892, 590
local ui = { mode = "all", page = 1, groupID = "general", groupOffset = 0, setupOffset = 0, tab = "browse" }
E.ui = ui

local WHITE = "Interface\\Buttons\\WHITE8x8"
local theme = {
    background = { 0.055, 0.059, 0.078, 1 },
    surface = { 0.086, 0.090, 0.118, 1 },
    raised = { 0.122, 0.125, 0.165, 1 },
    border = { 0.235, 0.231, 0.294, 1 },
    selection = { 0.235, 0.133, 0.365, 1 },
    accent = { 145 / 255, 70 / 255, 1, 1 },
    bright = { 169 / 255, 112 / 255, 1, 1 },
    hover = { 169 / 255, 112 / 255, 1, 0.14 },
    text = { 0.957, 0.949, 0.984, 1 },
    muted = { 0.710, 0.694, 0.765, 1 },
}

local function tooltipLine(text, muted)
    local color = muted and theme.muted or theme.text
    _G.GameTooltip:AddLine(text, color[1], color[2], color[3])
end

local function fill(parent, color, layer)
    local texture = parent:CreateTexture(nil, layer or "BACKGROUND")
    texture:SetColorTexture(unpack(color)); texture:SetAllPoints(parent)
    return texture
end

local function outline(parent, color)
    local edges = {}
    for i, points in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
        local edge = parent:CreateTexture(nil, "BORDER")
        edge:SetColorTexture(unpack(color)); edge:SetPoint(points[1], parent, points[1]); edge:SetPoint(points[2], parent, points[2])
        if i <= 2 then edge:SetHeight(1) else edge:SetWidth(1) end
        edges[i] = edge
    end
    return edges
end

local function skinButton(control)
    control:SetNormalTexture(WHITE); control:GetNormalTexture():SetColorTexture(unpack(theme.raised))
    control:GetNormalTexture():SetDrawLayer("BACKGROUND")
    control:SetDisabledTexture(WHITE); control:GetDisabledTexture():SetColorTexture(unpack(theme.surface))
    control:GetDisabledTexture():SetDrawLayer("BACKGROUND")
    control:SetHighlightTexture(WHITE, "BLEND"); control:GetHighlightTexture():SetColorTexture(unpack(theme.hover))
    control:SetPushedTexture(WHITE); control:GetPushedTexture():SetColorTexture(unpack(theme.selection))
    control:GetPushedTexture():SetDrawLayer("BACKGROUND")
    control.edges = outline(control, theme.border)
    control.selection = fill(control, theme.bright, "OVERLAY")
    control.selection:ClearAllPoints(); control.selection:SetPoint("TOPLEFT", control, "TOPLEFT"); control.selection:SetPoint("BOTTOMLEFT", control, "BOTTOMLEFT"); control.selection:SetWidth(3)
    control.selection:Hide()
end

local function selected(control, active, strong)
    control:GetNormalTexture():SetColorTexture(unpack(active and (strong and theme.accent or theme.selection) or theme.raised))
    control:GetDisabledTexture():SetColorTexture(unpack(active and (strong and theme.accent or theme.selection) or theme.surface))
    control.selection:SetShown(active and not strong)
    if control.caption then control:SetDisabledFontObject(active and "GameFontHighlight" or "GameFontDisable") end
end

local function restricted(value)
    if _G.issecretvalue and _G.issecretvalue(value) then return true end
    if _G.canaccessvalue and not _G.canaccessvalue(value) then return true end
    return E.IsRestricted and E:IsRestricted(value) or false
end

-- Check native editbox access before reading text, comparing values, or mutating input.
function E:GetSafeEditorText(editor)
    if restricted(editor) or not editor then return nil end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return nil end
    if _G.C_ChatInfo and _G.C_ChatInfo.InChatMessagingLockdown then
        local locked = _G.C_ChatInfo.InChatMessagingLockdown()
        if restricted(locked) or locked then return nil end
    end
    if editor.CanBeAccessedInContext then
        local accessible = editor:CanBeAccessedInContext()
        if restricted(accessible) or not accessible then return nil end
    end
    if editor.IsForbidden then
        local forbidden = editor:IsForbidden()
        if restricted(forbidden) or forbidden then return nil end
    end
    if editor.HasAnyForbiddenAspects and _G.Enum and _G.Enum.ForbiddenAspect then
        local forbidden = editor:HasAnyForbiddenAspects(_G.Enum.ForbiddenAspect.ScriptedInput)
        if restricted(forbidden) or forbidden then return nil end
    end
    if not editor.GetText or not editor.GetCursorPosition then return nil end
    local text, cursor = editor:GetText(), editor:GetCursorPosition()
    if restricted(text) or restricted(cursor) then return nil end
    if type(text) ~= "string" or type(cursor) ~= "number" or cursor < 0 or cursor > #text then return nil end
    return text, cursor
end

local function display(value)
    return tostring(value or ""):gsub("|", "||")
end

local function label(parent, text, x, y, width, font)
    local region = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    region:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    region:SetJustifyH("LEFT")
    if width then region:SetWidth(width); region:SetWordWrap(false) end
    region:SetText(text)
    region:SetTextColor(unpack(font == "GameFontHighlightSmall" and theme.muted or theme.text))
    return region
end

local function button(parent, text, x, y, width, onClick)
    local control = _G.CreateFrame("Button", nil, parent)
    control:SetSize(width, 26)
    control:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    skinButton(control)
    control.caption = control:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    control.caption:SetPoint("CENTER", control, "CENTER"); control.caption:SetWidth(math.max(12, width - 16)); control.caption:SetWordWrap(false)
    control:SetFontString(control.caption)
    control:SetNormalFontObject("GameFontHighlight"); control:SetHighlightFontObject("GameFontHighlight"); control:SetDisabledFontObject("GameFontDisable")
    control:SetText(text)
    control:SetScript("OnClick", onClick)
    control:SetScript("OnEnter", function(self)
        if self.tooltipText and _G.GameTooltip then
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); tooltipLine(self.tooltipText); _G.GameTooltip:Show()
        end
    end)
    control:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    return control
end

local function check(parent, text, x, y, onClick, favorite)
    local control = _G.CreateFrame("CheckButton", nil, parent)
    control:SetSize(26, 26)
    control:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    control:SetNormalTexture(WHITE); control:GetNormalTexture():SetColorTexture(unpack(theme.raised))
    control:GetNormalTexture():SetDrawLayer("BACKGROUND")
    control:SetHighlightTexture(WHITE, "BLEND"); control:GetHighlightTexture():SetColorTexture(unpack(theme.hover))
    control:SetCheckedTexture(WHITE)
    local mark = control:GetCheckedTexture()
    mark:SetAtlas(favorite and "collections-icon-favorites" or "checkmark-minimal")
    mark:SetDesaturated(true); mark:SetVertexColor(unpack(theme.bright))
    mark:ClearAllPoints(); mark:SetPoint("CENTER", control, "CENTER"); mark:SetSize(20, 20)
    if favorite then
        local unselected = control:GetNormalTexture()
        unselected:SetAtlas("collections-icon-favorites"); unselected:SetDesaturated(true); unselected:SetVertexColor(0.60, 0.58, 0.67, 0.6)
        unselected:ClearAllPoints(); unselected:SetPoint("CENTER", control, "CENTER"); unselected:SetSize(20, 20)
    else outline(control, theme.border) end
    control.Text = control:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    control.Text:SetPoint("LEFT", control, "RIGHT", 8, 0); control.Text:SetTextColor(unpack(theme.text))
    control.Text:SetText(text)
    if not favorite then control:SetHitRectInsets(0, -control.Text:GetStringWidth() - 8, 0, 0) end
    control:SetScript("OnClick", onClick)
    return control
end

local function input(parent)
    local control = _G.CreateFrame("EditBox", nil, parent)
    control:SetFontObject("GameFontHighlight"); control:SetTextInsets(8, 8, 0, 0); control:SetAutoFocus(false); control:EnableMouse(true)
    fill(control, theme.background)
    local edges = outline(control, theme.border)
    control:SetScript("OnEditFocusGained", function() for _, edge in ipairs(edges) do edge:SetColorTexture(unpack(theme.bright)) end end)
    control:SetScript("OnEditFocusLost", function() for _, edge in ipairs(edges) do edge:SetColorTexture(unpack(theme.border)) end end)
    return control
end

local function feedback(text)
    if ui.hint then ui.hint:SetText(text) end
end

function E:InsertEmote(name)
    if restricted(name) or type(name) ~= "string" or not self:GetEmote(name, true) then return false end
    local chat = _G.ChatFrameUtil
    local editor = chat and chat.GetActiveWindow and chat.GetActiveWindow()
    if not editor and chat and chat.ChooseBoxForSend then editor = chat.ChooseBoxForSend() end
    local text, cursor = self:GetSafeEditorText(editor)
    if not text then feedback("Chat input is unavailable."); return false end
    if chat and chat.ActivateChat then chat.ActivateChat(editor) else editor:SetFocus() end
    text, cursor = self:GetSafeEditorText(editor)
    if not text then return false end
    local before = cursor > 0 and not text:sub(cursor, cursor):match("%s") and " " or ""
    local after = text:sub(cursor + 1, cursor + 1):match("%s") and "" or " "
    editor:Insert(before .. name .. after)
    feedback("Inserted " .. display(name))
    return true
end

local function tooltip(entry, owner)
    if not entry or not _G.GameTooltip then return end
    local tip, pack = _G.GameTooltip, E.packs[entry.packID]
    local stats = E:Stats(entry.name)
    tip:SetOwner(owner, "ANCHOR_RIGHT")
    tooltipLine(display(entry.name))
    tooltipLine(display((pack and pack.title) or entry.packID))
    tooltipLine("Provider: " .. display(entry.provider or (pack and pack.provider) or "Unknown"), true)
    tooltipLine("Source credit: " .. display(entry.creator and entry.creator ~= "" and entry.creator or "Not provided"), true)
    tooltipLine("Sent " .. stats.sent .. "   Seen " .. stats.seen, true)
    tooltipLine(ui.mode == "hidden" and "Click to restore this emote." or "Click to insert. Right-click for options.", true)
    tip:Show()
end

local function groupEnabled(group)
    local enabled = 0
    for _, id in ipairs(group.packIDs) do if E.db.packs[id] ~= false then enabled = enabled + 1 end end
    return enabled
end

local function selectGroup(group)
    ui.groupID, ui.page = group.id, 1
    if ui.search then ui.search:SetText("") end
    E:RefreshUI()
end

local function matchingGroups(query)
    local groups = {}
    for _, group in ipairs(ui.groups) do
        if group.title:lower():find(query:lower(), 1, true) then groups[#groups + 1] = group end
    end
    return groups
end

local function releaseKeyboardControl()
    local control = ui.keyboardControl
    if not control then return end
    if control.UnlockHighlight then control:UnlockHighlight() end
    if control.focusBorder then for _, edge in ipairs(control.focusBorder) do edge:Hide() end end
end

local function setTab(tab)
    ui.tab = tab
    if ui.search then ui.search:ClearFocus() end
    if ui.groupSearch then ui.groupSearch:ClearFocus() end
    if ui.setupSearch then ui.setupSearch:ClearFocus() end
    releaseKeyboardControl()
    ui.keyboardIndex, ui.keyboardControl = nil, nil
    E:RefreshUI()
end

local function focusControl(index)
    releaseKeyboardControl()
    local controls = ui.controls or {}
    if #controls == 0 then return end
    index = ((index - 1) % #controls) + 1
    local control = controls[index]
    ui.keyboardIndex, ui.keyboardControl = index, control
    if control == ui.search or control == ui.groupSearch or control == ui.setupSearch then control:SetFocus()
    elseif control.LockHighlight then control:LockHighlight() end
    if control.focusBorder then for _, edge in ipairs(control.focusBorder) do edge:Show() end end
end

local function inputTab(self)
    self:ClearFocus()
    for i, control in ipairs(ui.controls) do
        if control == self then focusControl(i + (_G.IsShiftKeyDown() and -1 or 1)); return end
    end
end

local function keyboard(_, key)
    local focus = _G.GetCurrentKeyBoardFocus and _G.GetCurrentKeyBoardFocus()
    ui.panel:SetPropagateKeyboardInput(true)
    if focus then return end
    if ui.keyboardControl and ui.keyboardControl.emoteSizeSlider and (key == "LEFT" or key == "RIGHT") then
        local slider = ui.keyboardControl
        slider:SetValue(slider:GetValue() + (key == "RIGHT" and 1 or -1))
    elseif key == "TAB" or key == "DOWN" or key == "RIGHT" or key == "UP" or key == "LEFT" then
        local reverse = key == "UP" or key == "LEFT" or (key == "TAB" and _G.IsShiftKeyDown())
        focusControl((ui.keyboardIndex or 0) + (reverse and -1 or 1))
    elseif key == "ENTER" or key == "SPACE" then
        if ui.keyboardControl and ui.keyboardControl.Click then ui.keyboardControl:Click() end
    elseif key == "ESCAPE" then ui.panel:Hide()
    else return end
    ui.panel:SetPropagateKeyboardInput(false)
end

local function scrollBar(parent, x, y, height, callback)
    local scroll = _G.CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    scroll:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    scroll:SetHeight(height)
    scroll:RegisterCallback("OnScroll", function(_, percentage) callback(percentage) end, ui)
    return scroll
end

local function createGroups(parent)
    local sidebar = _G.CreateFrame("Frame", nil, parent)
    sidebar:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -82)
    sidebar:SetSize(166, 454)
    fill(sidebar, theme.surface)
    ui.sidebar = sidebar
    label(sidebar, "Groups", 4, 0, 146, "GameFontNormal")
    ui.groupSearch = input(sidebar)
    ui.groupSearch:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 8, -20)
    ui.groupSearch:SetSize(138, 26); ui.groupSearch:SetAutoFocus(false); ui.groupSearch:SetMaxLetters(64)
    ui.groupSearch:SetScript("OnTextChanged", function() ui.groupOffset = 0; E:RefreshUI() end)
    ui.groupSearch:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    ui.groupSearch:SetScript("OnTabPressed", inputTab)
    ui.groupSearch:SetScript("OnEnterPressed", function(self)
        self:ClearFocus(); if ui.filteredGroups[1] then selectGroup(ui.filteredGroups[1]) end
    end)
    ui.groupRows = {}
    for i = 1, GROUP_ROWS do
        local control = button(sidebar, "", 0, -56 - (i - 1) * 30, 146, function(self) if self.group then selectGroup(self.group) end end)
        control:GetFontString():SetWidth(110); control:GetFontString():SetWordWrap(false)
        control:GetFontString():ClearAllPoints(); control:GetFontString():SetPoint("LEFT", control, "LEFT", 10, 0); control:GetFontString():SetJustifyH("LEFT")
        control.enabledMark = control:CreateTexture(nil, "OVERLAY")
        control.enabledMark:SetAtlas("checkmark-minimal"); control.enabledMark:SetDesaturated(true)
        control.enabledMark:SetVertexColor(unpack(theme.bright)); control.enabledMark:SetSize(16, 16)
        control.enabledMark:SetPoint("RIGHT", control, "RIGHT", -6, 0)
        control:SetScript("OnEnter", function(self)
            if self.group and _G.GameTooltip then
                _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); tooltipLine(display(self.group.title))
                tooltipLine(groupEnabled(self.group) > 0 and "Enabled in chat" or "Preview available. Enable this group in Browse.", true)
                _G.GameTooltip:Show()
            end
        end)
        control:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
        ui.groupRows[i] = control
    end
    ui.groupScroll = scrollBar(sidebar, 156, -56, 354, function(percentage)
        local offset = math.floor(math.max(0, #ui.filteredGroups - GROUP_ROWS) * percentage + 0.5)
        if ui.groupOffset ~= offset then ui.groupOffset = offset; E:RefreshUI() end
    end)
    sidebar:EnableMouseWheel(true)
    sidebar:SetScript("OnMouseWheel", function(_, delta) ui.groupOffset = ui.groupOffset - delta * 3; E:RefreshUI() end)
    ui.groupPrevious = button(sidebar, "Previous", 0, -424, 78, function() ui.groupOffset = ui.groupOffset - GROUP_ROWS; E:RefreshUI() end)
    ui.groupNext = button(sidebar, "Next", 84, -424, 78, function() ui.groupOffset = ui.groupOffset + GROUP_ROWS; E:RefreshUI() end)
end

local function previewSize(entry)
    return math.min(40, 76 * entry.height / entry.width)
end

local function stopPreview(row)
    row:SetScript("OnUpdate", nil)
    row.previewElapsed = nil
end

local function updatePreview(row, elapsed)
    local entry = row.entry
    if not entry or not E.db.animate or not row:IsVisible() then stopPreview(row); return end
    row.previewElapsed = (row.previewElapsed or 0) + elapsed
    if row.previewElapsed < 1 / 30 then return end
    row.previewElapsed = 0
    row.preview:SetText(E:Render(entry, previewSize(entry), _G.GetTime()))
end

local function createBrowse(parent)
    local browse = _G.CreateFrame("Frame", nil, parent)
    browse:SetPoint("TOPLEFT", parent, "TOPLEFT", 202, -82)
    browse:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -18, 46)
    ui.browse = browse
    label(browse, "Search emotes", 4, 0)
    ui.search = input(browse)
    ui.search:SetSize(558, 26)
    ui.search:SetPoint("TOPLEFT", browse, "TOPLEFT", 8, -20)
    ui.search:SetAutoFocus(false)
    ui.search:SetMaxLetters(128)
    ui.search:SetScript("OnTextChanged", function() ui.page = 1; E:RefreshUI() end)
    ui.search:SetScript("OnEscapePressed", function(self) self:ClearFocus(); ui.panel:Hide() end)
    ui.search:SetScript("OnEnterPressed", function()
        local entry = ui.results and ui.results[(ui.page - 1) * PAGE_SIZE + 1]
        if entry then
            if ui.mode == "hidden" then E:SetEmoteHidden(entry.name, false) else E:InsertEmote(entry.name) end
        end
    end)
    ui.search:SetScript("OnTabPressed", inputTab)
    ui.clear = button(browse, "Clear", 582, -20, 90, function() ui.search:SetText(""); ui.search:SetFocus() end)
    ui.modes = {}
    for i, mode in ipairs({ { "all", "All" }, { "favorites", "Favorites" }, { "recent", "Recent" }, { "hidden", "Hidden" } }) do
        local key = mode[1]
        ui.modes[i] = button(browse, mode[2], (i - 1) * 112, -56, 104, function()
            ui.mode, ui.page = key, 1; E:RefreshUI()
        end)
    end
    ui.groupTitle = label(browse, "", 4, -95, 450, "GameFontNormal")
    ui.browseEnabled = check(browse, "Enabled in chat", 475, -88, function(self)
        if ui.selectedGroup then E:SetGroupEnabled(ui.selectedGroup.id, self:GetChecked()) end
    end)
    ui.rows = {}
    for i = 1, PAGE_SIZE do
        local column, rowIndex = (i - 1) % COLUMNS, math.floor((i - 1) / COLUMNS)
        local row = _G.CreateFrame("Button", nil, browse)
        row:SetSize(324, 44)
        row:SetPoint("TOPLEFT", browse, "TOPLEFT", column * 344, -126 - rowIndex * 48)
        skinButton(row)
        row.preview = label(row, "", 4, -2, 80)
        row.preview:SetHeight(40); row.preview:SetJustifyH("CENTER"); row.preview:SetJustifyV("MIDDLE")
        row.name = label(row, "", 90, -5, 196)
        row.usage = label(row, "", 90, -25, 196, "GameFontHighlightSmall")
        row.favorite = check(row, "", 294, -9, function() if row.entry then E:ToggleFavorite(row.entry.name) end end, true)
        row.favorite:SetScript("OnEnter", function(self)
            if _G.GameTooltip then
                _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                tooltipLine(row.entry and E.db.favorites[row.entry.name] and "Remove favorite" or "Add favorite")
                _G.GameTooltip:Show()
            end
        end)
        row.favorite:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", function(_, mouseButton)
            if not row.entry then return end
            if mouseButton == "RightButton" then E:OpenEmoteMenu(row.entry.name)
            elseif ui.mode == "hidden" then E:SetEmoteHidden(row.entry.name, false)
            else E:InsertEmote(row.entry.name) end
        end)
        row:SetScript("OnEnter", function(self)
            tooltip(self.entry, self)
            if self.entry and self.entry.frames > 1 and E.db.animate and self:IsVisible() then
                self.previewElapsed = 0; self:SetScript("OnUpdate", updatePreview)
            end
        end)
        row:SetScript("OnLeave", function(self) stopPreview(self); if _G.GameTooltip then _G.GameTooltip:Hide() end end)
        row:SetScript("OnHide", stopPreview)
        ui.rows[i] = row
    end
    ui.empty = label(browse, "No emotes found. Try another search or group.", 12, -164, 640)
    ui.previous = button(browse, "Previous page", 0, -424, 116, function() ui.page = math.max(1, ui.page - 1); E:RefreshUI() end)
    ui.next = button(browse, "Next page", 562, -424, 110, function() ui.page = ui.page + 1; E:RefreshUI() end)
    ui.pageText = label(browse, "", 132, -429, 410)
    browse:EnableMouseWheel(true)
    browse:SetScript("OnMouseWheel", function(_, delta)
        ui.page = ui.page + (delta > 0 and -1 or 1); E:RefreshUI()
    end)
end

local function createSettings(parent)
    local settings = _G.CreateFrame("Frame", nil, parent)
    settings:SetPoint("TOPLEFT", parent, "TOPLEFT", 202, -82)
    settings:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -18, 46)
    ui.settings, ui.options, ui.settingControls = settings, {}, {}
    for i, option in ipairs({ { "enabled", "Show emotes in chat" }, { "animate", "Animate emotes" }, { "minimap", "Show minimap button" } }) do
        local key = option[1]
        local control = check(settings, option[2], 0, -(i - 1) * 30, function(self) E:SetOption(key, self:GetChecked()) end)
        ui.options[key] = control; ui.settingControls[#ui.settingControls + 1] = control
    end
    label(settings, "Emote size", 2, -101, 180)
    local sizeValue = label(settings, "", 208, -101, 62)
    local sizeSlider = _G.CreateFrame("Slider", nil, settings)
    sizeSlider.emoteSizeSlider = true
    sizeSlider:SetPoint("TOPLEFT", settings, "TOPLEFT", 2, -124); sizeSlider:SetSize(254, 18)
    sizeSlider:SetOrientation("HORIZONTAL"); sizeSlider:SetMinMaxValues(12, 40)
    sizeSlider:SetValueStep(1); sizeSlider:SetObeyStepOnDrag(true); sizeSlider:EnableMouse(true)
    sizeSlider.focusBorder = outline(sizeSlider, theme.bright)
    for _, edge in ipairs(sizeSlider.focusBorder) do edge:Hide() end
    local rail = fill(sizeSlider, theme.raised)
    rail:ClearAllPoints(); rail:SetPoint("LEFT", sizeSlider, "LEFT"); rail:SetPoint("RIGHT", sizeSlider, "RIGHT"); rail:SetHeight(4)
    local amount = fill(sizeSlider, theme.bright)
    amount:ClearAllPoints(); amount:SetPoint("LEFT", sizeSlider, "LEFT"); amount:SetHeight(4)
    sizeSlider:SetThumbTexture(WHITE)
    sizeSlider:GetThumbTexture():SetSize(10, 18); sizeSlider:GetThumbTexture():SetVertexColor(unpack(theme.text))
    sizeSlider:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value + 0.5)
        if value ~= E.db.size then E:SetOption("size", value) end
    end)
    sizeSlider:SetScript("OnMouseDown", function(self)
        local focus = _G.GetCurrentKeyBoardFocus and _G.GetCurrentKeyBoardFocus()
        if focus and E:GetSafeEditorText(focus) then focus:ClearFocus() end
        for i, control in ipairs(ui.controls or {}) do if control == self then focusControl(i); break end end
    end)
    sizeSlider:SetScript("OnEnter", function(self)
        if _G.GameTooltip then
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); tooltipLine("Chat emote size")
            tooltipLine("Drag to resize. Left/right arrows adjust one pixel.", true); _G.GameTooltip:Show()
        end
    end)
    sizeSlider:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    ui.options.size = { slider = sizeSlider, label = sizeValue, amount = amount }
    ui.settingControls[#ui.settingControls + 1] = sizeSlider
    label(settings, "Preview", 278, -87, 62, "GameFontHighlightSmall")
    ui.sizePreview = label(settings, "", 274, -104, 64); ui.sizePreview:SetHeight(48); ui.sizePreview:SetJustifyH("CENTER"); ui.sizePreview:SetJustifyV("MIDDLE")
    for _, option in ipairs({ { "animationFPS", "Animation FPS", 15, 60, { 15, 30, 60 } } }) do
        local key, title, minimum, maximum, choices = unpack(option)
        local y = -168
        label(settings, title, 2, y + 1, 132)
        local function adjust(direction)
            local value = E.db[key] + direction
            if choices then
                value = direction > 0 and maximum or minimum
                for _, choice in ipairs(choices) do
                    if direction > 0 and choice > E.db[key] then value = choice; break end
                    if direction < 0 and choice < E.db[key] then value = choice end
                end
            end
            E:SetOption(key, math.max(minimum, math.min(maximum, value)))
        end
        local decrease = button(settings, "-", 146, y + 6, 28, function() adjust(-1) end)
        local value = label(settings, "", 188, y + 1, 36)
        local increase = button(settings, "+", 230, y + 6, 28, function() adjust(1) end)
        decrease.tooltipText = "Decrease " .. title:lower(); increase.tooltipText = "Increase " .. title:lower()
        ui.options[key] = { label = value, decrease = decrease, increase = increase, minimum = minimum, maximum = maximum }
        ui.settingControls[#ui.settingControls + 1] = decrease; ui.settingControls[#ui.settingControls + 1] = increase
    end
    label(settings, "Selected group", 350, 0, 318, "GameFontNormal")
    ui.settingsGroupTitle = label(settings, "", 350, -26, 318)
    ui.groupEnabled = check(settings, "Enable this group", 350, -48, function(self)
        if ui.selectedGroup then E:SetGroupEnabled(ui.selectedGroup.id, self:GetChecked()) end
    end)
    ui.priorityButton = button(settings, "Use for shared names", 350, -82, 220, function()
        if ui.selectedGroup then E:SetOption("preferredGroup", ui.selectedGroup.id) end
    end)
    ui.priorityStatus = label(settings, "", 350, -114, 318, "GameFontHighlightSmall")
    label(settings, "Only enabled groups supply emotes.", 350, -136, 318, "GameFontHighlightSmall")
    ui.manageGroups = button(settings, "Choose channels", 350, -157, 180, function() E:OpenSetup() end)
    ui.manageGroups.tooltipText = "Open the channel picker with your current selections."
    ui.manageHidden = button(settings, "Hidden emotes", 540, -157, 132, function()
        ui.mode, ui.page = "hidden", 1; ui.search:SetText(""); E:OpenPanel("browse")
    end)
    ui.settingControls[#ui.settingControls + 1] = ui.groupEnabled
    ui.settingControls[#ui.settingControls + 1] = ui.priorityButton
    ui.settingControls[#ui.settingControls + 1] = ui.manageGroups
    ui.settingControls[#ui.settingControls + 1] = ui.manageHidden
    label(settings, "Chat channels", 2, -206, 300, "GameFontNormal")
    ui.channels = {}
    local defaults = {
        { "CHAT_MSG_SAY", "Say" }, { "CHAT_MSG_YELL", "Yell" },
        { "CHAT_MSG_WHISPER", "Whispers" }, { "CHAT_MSG_BN_WHISPER", "Battle.net whispers" },
        { "CHAT_MSG_GUILD", "Guild" }, { "CHAT_MSG_OFFICER", "Officer" },
        { "CHAT_MSG_CHANNEL", "Public channels" }, { "CHAT_MSG_EMOTE", "Emotes" },
        { "CHAT_MSG_PARTY", "Party" }, { "CHAT_MSG_PARTY_LEADER", "Party leader" },
        { "CHAT_MSG_RAID", "Raid" }, { "CHAT_MSG_RAID_LEADER", "Raid leader" },
        { "CHAT_MSG_RAID_WARNING", "Raid warnings" }, { "CHAT_MSG_INSTANCE_CHAT", "Instance" },
        { "CHAT_MSG_INSTANCE_CHAT_LEADER", "Instance leader" }, { "CHAT_MSG_COMMUNITIES_CHANNEL", "Communities" },
    }
    for i, channel in ipairs(defaults) do
        local key = channel[1]
        local title = E.channelLabels and E.channelLabels[key] or channel[2]
        local control = check(settings, title, i > 8 and 350 or 0, -232 - ((i - 1) % 8) * 28, function(self)
            local channels = {}; for id, enabled in pairs(E.db.channels) do channels[id] = enabled end
            channels[key] = self:GetChecked()
            if key == "CHAT_MSG_WHISPER" or key == "CHAT_MSG_BN_WHISPER" then channels[key .. "_INFORM"] = channels[key] end
            E:SetOption("channels", channels)
        end)
        ui.channels[key] = control; ui.settingControls[#ui.settingControls + 1] = control
    end
end

local function createSetup(parent)
    local setup = _G.CreateFrame("Frame", nil, parent)
    setup:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, -82)
    setup:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -18, 46)
    ui.setup = setup
    label(setup, "Choose your channels", 4, 0, 820, "GameFontNormalLarge")
    label(setup, "General contains provider-wide emotes. Add the channels you want to see in chat.", 4, -25, 820)
    label(setup, "Find channel", 4, -57, 100)
    ui.setupSearch = input(setup)
    ui.setupSearch:SetPoint("TOPLEFT", setup, "TOPLEFT", 112, -49)
    ui.setupSearch:SetSize(568, 26); ui.setupSearch:SetAutoFocus(false); ui.setupSearch:SetMaxLetters(64)
    ui.setupSearch:SetScript("OnTextChanged", function() ui.setupOffset = 0; E:RefreshUI() end)
    ui.setupSearch:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    ui.setupSearch:SetScript("OnTabPressed", inputTab)
    ui.setupClear = button(setup, "Clear search", 700, -49, 132, function() ui.setupSearch:SetText(""); ui.setupSearch:SetFocus() end)
    ui.setupRows = {}
    for i = 1, SETUP_ROWS do
        local control = check(setup, "", ((i - 1) % 2) * 420, -88 - math.floor((i - 1) / 2) * 40, function(self)
            if self.group then E:SetGroupEnabled(self.group.id, self:GetChecked()) end
        end)
        control.Text:SetWidth(366); control.Text:SetWordWrap(false)
        control:SetHitRectInsets(0, -374, 0, 0)
        ui.setupRows[i] = control
    end
    ui.setupScroll = scrollBar(setup, 846, -88, 306, function(percentage)
        local offset = math.floor(math.max(0, #ui.setupGroups - SETUP_ROWS) * percentage + 0.5)
        if ui.setupOffset ~= offset then ui.setupOffset = offset; E:RefreshUI() end
    end)
    setup:EnableMouseWheel(true)
    setup:SetScript("OnMouseWheel", function(_, delta) ui.setupOffset = ui.setupOffset - delta * 4; E:RefreshUI() end)
    ui.setupPrevious = button(setup, "Previous channels", 0, -424, 146, function() ui.setupOffset = ui.setupOffset - SETUP_ROWS; E:RefreshUI() end)
    ui.setupNext = button(setup, "Next channels", 156, -424, 140, function() ui.setupOffset = ui.setupOffset + SETUP_ROWS; E:RefreshUI() end)
    ui.setupCount = label(setup, "", 314, -429, 270, "GameFontHighlightSmall")
    ui.setupDone = button(setup, "Done", 610, -424, 236, function()
        E:SetOption("setupComplete", true); setTab("browse")
    end)
    selected(ui.setupDone, true, true)
end

local function createPanel()
    local panel = _G.CreateFrame("Frame", "ForeverEmotesPanel", _G.UIParent)
    ui.panel = panel
    panel:SetSize(PANEL_WIDTH, PANEL_HEIGHT)
    panel:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 0)
    panel:SetFrameStrata("DIALOG")
    panel:SetClampedToScreen(true)
    panel:SetMovable(true); panel:EnableMouse(true); panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:EnableKeyboard(true); panel:SetPropagateKeyboardInput(true)
    panel:SetScript("OnKeyDown", keyboard)
    for i = 3, 1, -1 do
        local shadow = fill(panel, { 0, 0, 0, 0.16 }, "BACKGROUND")
        shadow:ClearAllPoints(); shadow:SetPoint("TOPLEFT", panel, "TOPLEFT", -i * 3, i * 3); shadow:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", i * 3, -i * 3)
    end
    fill(panel, theme.background); outline(panel, theme.border)
    local header = fill(panel, theme.surface)
    header:ClearAllPoints(); header:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1); header:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -1); header:SetHeight(71)
    local accent = fill(panel, theme.accent, "BORDER")
    accent:ClearAllPoints(); accent:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -71); accent:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -71); accent:SetHeight(2)
    panel.TitleText = label(panel, E.title, 20, -16, 780, "GameFontNormalLarge")
    panel.CloseButton = button(panel, "×", PANEL_WIDTH - 48, -13, 30, function() panel:Hide() end)
    panel.CloseButton:SetHeight(30); panel.CloseButton.tooltipText = "Close"
    if _G.UISpecialFrames then _G.UISpecialFrames[#_G.UISpecialFrames + 1] = "ForeverEmotesPanel" end
    ui.browseTab = button(panel, "Browse", 202, -42, 104, function() setTab("browse") end)
    ui.settingsTab = button(panel, "Settings", 312, -42, 104, function() setTab("settings") end)
    ui.channelsTab = button(panel, "Channels", 422, -42, 104, function() E:OpenSetup() end)
    createGroups(panel); createBrowse(panel); createSettings(panel); createSetup(panel)
    ui.hint = label(panel, "Click to insert. Right-click for options. Type : to complete a name.", 20, -565, 610, "GameFontHighlightSmall")
    ui.credit = label(panel, "Made by TheMizeGuy", 0, 0, 240, "GameFontHighlightSmall")
    ui.credit:ClearAllPoints(); ui.credit:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -20, 12); ui.credit:SetJustifyH("RIGHT")
    panel:SetScript("OnHide", function()
        ui.search:ClearFocus(); ui.groupSearch:ClearFocus(); ui.setupSearch:ClearFocus()
        for _, row in ipairs(ui.rows) do stopPreview(row) end
        if _G.GameTooltip then _G.GameTooltip:Hide() end
        releaseKeyboardControl()
        ui.keyboardControl, ui.keyboardIndex = nil, nil
    end)
    panel:Hide()
end

local function updateMinimap()
    if not ui.minimap or not E.db then return end
    local angle = math.rad(E.db.minimapAngle or 220)
    local radius = _G.Minimap:GetWidth() / 2 + 2
    ui.minimap:ClearAllPoints()
    ui.minimap:SetPoint("CENTER", _G.Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
    ui.minimap:SetShown(E.db.minimap)
end

function E:RefreshUI()
    updateMinimap()
    if ui.emoteMenu then ui.emoteMenu:Hide() end
    if self.db and not self.db.enabled and self.DismissCompletion then self:DismissCompletion() end
    if not ui.panel or not ui.panel:IsShown() or not self.db then return end
    ui.groups = self:GetGroups()
    ui.selectedGroup = nil
    for _, group in ipairs(ui.groups) do if group.id == ui.groupID then ui.selectedGroup = group; break end end
    ui.selectedGroup = ui.selectedGroup or ui.groups[1]
    ui.groupID = ui.selectedGroup and ui.selectedGroup.id
    local packSet = {}
    if ui.selectedGroup then for _, id in ipairs(ui.selectedGroup.packIDs) do packSet[id] = true end end
    ui.browse:SetShown(ui.tab == "browse"); ui.settings:SetShown(ui.tab == "settings"); ui.setup:SetShown(ui.tab == "setup")
    ui.sidebar:SetShown(ui.tab ~= "setup"); ui.hint:SetShown(ui.tab == "browse")
    ui.browseTab:SetEnabled(ui.tab ~= "browse"); ui.settingsTab:SetEnabled(ui.tab ~= "settings"); ui.channelsTab:SetEnabled(ui.tab ~= "setup")
    selected(ui.browseTab, ui.tab == "browse", true); selected(ui.settingsTab, ui.tab == "settings", true); selected(ui.channelsTab, ui.tab == "setup", true)
    ui.controls = { ui.browseTab, ui.settingsTab, ui.channelsTab, ui.panel.CloseButton }
    if ui.tab ~= "setup" then
        ui.filteredGroups = matchingGroups(ui.groupSearch:GetText())
        local maximum = math.max(0, #ui.filteredGroups - GROUP_ROWS)
        ui.groupOffset = math.max(0, math.min(maximum, ui.groupOffset))
        ui.groupScroll:SetVisibleExtentPercentage(math.min(1, GROUP_ROWS / math.max(1, #ui.filteredGroups)))
        ui.groupScroll:SetPanExtentPercentage(maximum > 0 and 1 / maximum or 0)
        ui.groupScroll:SetScrollPercentage(maximum > 0 and ui.groupOffset / maximum or 0, true)
        ui.groupScroll:SetShown(maximum > 0)
        ui.controls[#ui.controls + 1] = ui.groupSearch
        for i, control in ipairs(ui.groupRows) do
            control.group = ui.filteredGroups[ui.groupOffset + i]
            control:SetShown(control.group ~= nil)
            if control.group then
                control:SetText(display(control.group.title))
                selected(control, control.group.id == ui.groupID)
                local enabled = groupEnabled(control.group) > 0
                control.enabledMark:SetShown(enabled)
                if enabled and control.group.id ~= ui.groupID then control:GetNormalTexture():SetColorTexture(unpack(theme.selection)) end
                ui.controls[#ui.controls + 1] = control
            end
        end
        ui.groupPrevious:SetEnabled(ui.groupOffset > 0); ui.groupNext:SetEnabled(ui.groupOffset < maximum)
        ui.controls[#ui.controls + 1] = ui.groupPrevious; ui.controls[#ui.controls + 1] = ui.groupNext
    end
    if ui.tab == "browse" then
        local hidden = ui.mode == "hidden"
        local sourceCount = hidden and #(self.hiddenNames or {}) or #(self.browseNames or self.names)
        ui.results = self:Search(ui.search:GetText(), math.max(1, sourceCount), ui.mode, not hidden and packSet or nil, true)
        local pages = math.max(1, math.ceil(#ui.results / PAGE_SIZE))
        ui.page = math.max(1, math.min(pages, ui.page))
        ui.groupTitle:SetText(hidden and "Hidden emotes · all groups" or (ui.selectedGroup and display(ui.selectedGroup.title) or "No groups installed"))
        ui.browseEnabled:SetShown(not hidden); ui.browseEnabled:SetEnabled(ui.selectedGroup ~= nil)
        ui.browseEnabled:SetChecked(ui.selectedGroup and groupEnabled(ui.selectedGroup) > 0)
        ui.controls[#ui.controls + 1] = ui.browseEnabled
        ui.controls[#ui.controls + 1] = ui.search; ui.controls[#ui.controls + 1] = ui.clear
        for i, mode in ipairs({ "all", "favorites", "recent", "hidden" }) do
            ui.modes[i]:SetEnabled(ui.mode ~= mode); selected(ui.modes[i], ui.mode == mode); ui.controls[#ui.controls + 1] = ui.modes[i]
        end
        for i, row in ipairs(ui.rows) do
            stopPreview(row)
            local entry = ui.results[(ui.page - 1) * PAGE_SIZE + i]
            row.entry = entry; row:SetShown(entry ~= nil)
            if entry then
                row.preview:SetText(self:Render(entry, previewSize(entry)))
                row.name:SetText(display(entry.name))
                local stats = self:Stats(entry.name)
                row.usage:SetText(hidden and "Hidden · click to restore" or ("Sent " .. stats.sent .. "   Seen " .. stats.seen))
                row.favorite:SetShown(not hidden)
                row.favorite:SetChecked(self.db.favorites[entry.name])
                ui.controls[#ui.controls + 1] = row; ui.controls[#ui.controls + 1] = row.favorite
            end
        end
        ui.empty:SetShown(#ui.results == 0)
        ui.empty:SetText(hidden and "No hidden emotes match. Click a chat emote for options." or "No emotes found. Try another search or group.")
        ui.previous:SetEnabled(ui.page > 1); ui.next:SetEnabled(ui.page < pages)
        ui.pageText:SetText("Page " .. ui.page .. " of " .. pages .. "   ·   " .. #ui.results .. " emotes")
        ui.controls[#ui.controls + 1] = ui.previous; ui.controls[#ui.controls + 1] = ui.next
    elseif ui.tab == "settings" then
        for key, control in pairs(ui.options) do
            if control.slider then
                control.label:SetText(self.db[key] .. " px"); control.slider:SetValue(self.db[key])
                control.amount:SetWidth(math.max(1, control.slider:GetWidth() * (self.db[key] - 12) / 28))
            elseif control.label then
                control.label:SetText(self.db[key]); control.decrease:SetEnabled(self.db[key] > control.minimum); control.increase:SetEnabled(self.db[key] < control.maximum)
            else control:SetChecked(self.db[key]) end
        end
        local preview = self:GetEmote("Kappa", true) or self.names[1]
        ui.sizePreview:SetText(preview and self:Render(preview, self.db.size) or "Aa")
        local group = ui.selectedGroup
        ui.settingsGroupTitle:SetText(group and display(group.title) or "No groups installed")
        ui.groupEnabled:SetEnabled(group ~= nil); ui.groupEnabled:SetChecked(group and groupEnabled(group) > 0)
        ui.priorityButton:SetEnabled(group ~= nil and self.db.preferredGroup ~= group.id)
        local priorityTitle
        for _, candidate in ipairs(ui.groups) do if candidate.id == self.db.preferredGroup then priorityTitle = candidate.title; break end end
        ui.priorityStatus:SetText(priorityTitle and ("Shared names prefer " .. display(priorityTitle)) or "Shared names use the default order.")
        for key, control in pairs(ui.channels) do control:SetChecked(self.db.channels[key] ~= false) end
        for _, control in ipairs(ui.settingControls) do ui.controls[#ui.controls + 1] = control end
    else
        ui.setupGroups = matchingGroups(ui.setupSearch:GetText())
        local maximum = math.max(0, #ui.setupGroups - SETUP_ROWS)
        ui.setupOffset = math.max(0, math.min(maximum, ui.setupOffset))
        ui.setupScroll:SetVisibleExtentPercentage(math.min(1, SETUP_ROWS / math.max(1, #ui.setupGroups)))
        ui.setupScroll:SetPanExtentPercentage(maximum > 0 and 2 / maximum or 0)
        ui.setupScroll:SetScrollPercentage(maximum > 0 and ui.setupOffset / maximum or 0, true)
        ui.setupScroll:SetShown(maximum > 0)
        ui.controls[#ui.controls + 1] = ui.setupSearch; ui.controls[#ui.controls + 1] = ui.setupClear
        for i, control in ipairs(ui.setupRows) do
            control.group = ui.setupGroups[ui.setupOffset + i]
            control:SetShown(control.group ~= nil)
            if control.group then
                control.Text:SetText(display(control.group.title)); control:SetChecked(groupEnabled(control.group) > 0)
                ui.controls[#ui.controls + 1] = control
            end
        end
        ui.setupPrevious:SetEnabled(ui.setupOffset > 0); ui.setupNext:SetEnabled(ui.setupOffset < maximum)
        ui.setupCount:SetText(#ui.setupGroups .. " groups")
        ui.controls[#ui.controls + 1] = ui.setupPrevious; ui.controls[#ui.controls + 1] = ui.setupNext; ui.controls[#ui.controls + 1] = ui.setupDone
    end
    local available = {}
    for _, control in ipairs(ui.controls) do
        if control:IsShown() and (not control.IsEnabled or control:IsEnabled()) then available[#available + 1] = control end
    end
    ui.controls = available
    if ui.keyboardControl then
        local current
        for i, control in ipairs(available) do if control == ui.keyboardControl then current = i; break end end
        if current then ui.keyboardIndex = current
        else
            releaseKeyboardControl()
            ui.keyboardControl, ui.keyboardIndex = nil, nil
        end
    end
end

function E:OpenPanel(tab)
    if not ui.panel then createPanel() end
    if tab == "settings" or tab == "browse" or tab == "setup" then ui.tab = tab end
    ui.panel:SetScale(math.max(0.1, math.min(1, (_G.UIParent:GetWidth() - 32) / PANEL_WIDTH, (_G.UIParent:GetHeight() - 32) / PANEL_HEIGHT)))
    ui.panel:Show(); ui.panel:Raise(); self:RefreshUI()
end

function E:OpenSetup()
    self:OpenPanel("setup")
    ui.setupSearch:SetText(""); ui.setupSearch:ClearFocus()
end

function E:OpenEmoteMenu(name)
    if restricted(name) or type(name) ~= "string" then return false end
    local entry = self:GetEmote(name, true)
    if not entry then return false end
    if not ui.emoteMenu then
        local menu = _G.CreateFrame("Frame", "ForeverEmotesMenu", _G.UIParent)
        ui.emoteMenu = menu
        menu:SetSize(280, 246); menu:SetFrameStrata("FULLSCREEN_DIALOG"); menu:SetClampedToScreen(true)
        menu:EnableMouse(true); menu:EnableKeyboard(true); menu:SetPropagateKeyboardInput(true)
        fill(menu, theme.background); outline(menu, theme.bright)
        menu.preview = label(menu, "", 12, -12, 70); menu.preview:SetHeight(36); menu.preview:SetJustifyH("CENTER")
        menu.title = label(menu, "", 92, -14, 146, "GameFontNormal")
        menu.source = label(menu, "", 92, -36, 166, "GameFontHighlightSmall")
        local close = button(menu, "×", 246, -10, 24, function() menu:Hide() end)
        close.tooltipText = "Close"
        label(menu, "Applies to this name in every channel.", 12, -65, 256, "GameFontHighlightSmall")
        menu.hideEmote = button(menu, "Hide this emote", 12, -88, 256, function()
            local target = menu.emoteName; menu:Hide()
            E:SetEmoteHidden(target, not E:IsEmoteHidden(target))
        end)
        selected(menu.hideEmote, true, true)
        menu.favorite = button(menu, "Add favorite", 12, -120, 256, function()
            local target = menu.emoteName; menu:Hide(); E:ToggleFavorite(target)
        end)
        menu.insert = button(menu, "Insert name in chat", 12, -152, 256, function()
            local target = menu.emoteName; menu:Hide(); E:InsertEmote(target)
        end)
        menu.settings = button(menu, "Emote settings", 12, -184, 256, function() menu:Hide(); E:OpenPanel("settings") end)
        label(menu, "Restore hidden emotes in Browse > Hidden.", 12, -222, 256, "GameFontHighlightSmall")
        menu.controls = { menu.hideEmote, menu.favorite, menu.insert, menu.settings, close }
        menu:SetScript("OnKeyDown", function(self, key)
            self:SetPropagateKeyboardInput(true)
            if key == "ESCAPE" then self:Hide()
            elseif _G.GetCurrentKeyBoardFocus and _G.GetCurrentKeyBoardFocus() then return
            elseif key == "TAB" or key == "DOWN" or key == "UP" then
                self.controls[self.focusIndex]:UnlockHighlight()
                local reverse = key == "UP" or (key == "TAB" and _G.IsShiftKeyDown())
                self.focusIndex = (self.focusIndex - 1 + (reverse and -1 or 1)) % #self.controls + 1
                self.controls[self.focusIndex]:LockHighlight()
            elseif key == "ENTER" or key == "SPACE" then self.controls[self.focusIndex]:Click()
            else return end
            self:SetPropagateKeyboardInput(false)
        end)
        menu:SetScript("OnEvent", function(self) if not self:IsMouseOver() then self:Hide() end end)
        menu:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
        menu:SetScript("OnHide", function(self)
            self:UnregisterEvent("GLOBAL_MOUSE_DOWN")
            for _, control in ipairs(self.controls) do control:UnlockHighlight() end
            if _G.GameTooltip then _G.GameTooltip:Hide() end
        end)
        if _G.UISpecialFrames then _G.UISpecialFrames[#_G.UISpecialFrames + 1] = "ForeverEmotesMenu" end
        menu:Hide()
    end
    local menu = ui.emoteMenu
    menu:Hide(); menu.emoteName = name; menu.focusIndex = 1
    menu.preview:SetText(self:Render(entry, previewSize(entry)))
    menu.title:SetText(display(name)); menu.source:SetText(display(entry.provider))
    menu.hideEmote:SetText(self:IsEmoteHidden(name) and "Restore this emote" or "Hide this emote")
    menu.favorite:SetText(self.db.favorites[name] and "Remove favorite" or "Add favorite")
    local x, y = _G.GetCursorPosition(); local scale = menu:GetEffectiveScale()
    menu:ClearAllPoints(); menu:SetPoint("TOPLEFT", _G.UIParent, "BOTTOMLEFT", x / scale, y / scale)
    if _G.GameTooltip then _G.GameTooltip:Hide() end
    menu:Show(); menu:Raise(); menu.controls[1]:LockHighlight()
    return true
end

function E:InitializeUI()
    if not self.db then return end
    if not ui.minimap and _G.Minimap then
        local control = _G.CreateFrame("Button", nil, _G.Minimap)
        ui.minimap = control; control:SetSize(24, 24)
        -- The native rim's OVERLAY textures cover buttons at its own frame level.
        control:SetFrameLevel((_G.MinimapBackdrop or _G.Minimap):GetFrameLevel() + 1)
        control:SetHitRectInsets(-2, -2, -2, -2)
        control.background = control:CreateTexture(nil, "BACKGROUND")
        control.background:SetAtlas("ui-hud-minimap-button"); control.background:SetAllPoints(control)
        local mask = control:CreateMaskTexture(nil, "ARTWORK")
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetSize(20, 20); mask:SetPoint("CENTER", control, "CENTER")
        control.face = control:CreateTexture(nil, "BORDER")
        control.face:SetColorTexture(unpack(theme.accent)); control.face:SetAllPoints(mask); control.face:AddMaskTexture(mask)
        control.icon = control:CreateTexture(nil, "ARTWORK")
        control.icon:SetTexture("Interface\\AddOns\\TwitchEmotes\\Media\\UI\\TwitchGlitch.tga")
        control.icon:SetSize(15, 15); control.icon:SetPoint("CENTER", control, "CENTER"); control.icon:AddMaskTexture(mask)
        control:SetHighlightTexture(WHITE, "BLEND")
        control:GetHighlightTexture():SetColorTexture(1, 1, 1, 0.14); control:GetHighlightTexture():AddMaskTexture(mask)
        control:SetPushedTexture(WHITE)
        control:GetPushedTexture():SetColorTexture(0, 0, 0, 0.25); control:GetPushedTexture():AddMaskTexture(mask)
        control:RegisterForDrag("LeftButton")
        control:SetScript("OnClick", function() E:OpenPanel() end)
        control:SetScript("OnDragStart", function(self)
            self:SetScript("OnUpdate", function()
                local x, y = _G.GetCursorPosition()
                local scale = _G.Minimap:GetEffectiveScale()
                local centerX, centerY = _G.Minimap:GetCenter()
                if centerX and centerY then
                    E.db.minimapAngle = math.deg(math.atan2(y / scale - centerY, x / scale - centerX)) % 360
                    updateMinimap()
                end
            end)
        end)
        control:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        control:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)
        control:SetScript("OnEnter", function(self)
            if not _G.GameTooltip then return end
            _G.GameTooltip:SetOwner(self, "ANCHOR_LEFT"); tooltipLine(E.title)
            tooltipLine("Click to browse emotes. Drag to move.", true); _G.GameTooltip:Show()
        end)
        control:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
    end
    if not ui.category and _G.Settings and _G.Settings.RegisterCanvasLayoutCategory and _G.Settings.RegisterAddOnCategory then
        local canvas = _G.CreateFrame("Frame")
        label(canvas, self.title, 16, -16, nil, "GameFontNormalLarge")
        label(canvas, "Browse emotes and manage chat display, animation, and channels.", 16, -52, 560)
        button(canvas, "Open emote settings", 16, -86, 190, function() E:OpenPanel("settings") end)
        ui.category = _G.Settings.RegisterCanvasLayoutCategory(canvas, self.title)
        _G.Settings.RegisterAddOnCategory(ui.category)
    end
    updateMinimap()
end
