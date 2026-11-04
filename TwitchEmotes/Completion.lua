local addonName, E = ...
-- Copyright (c) 2026 TheMizeGuy. All rights reserved.

-- Suggestions live in an addon-owned popup. Blizzard's shared AutoCompleteBox and the chat edit box's
-- Lua fields are never written: writing them taints ACTIVE_CHAT_EDIT_BOX for the session.
local attached = setmetatable({}, { __mode = "k" })
local MAX_ROWS, PREVIEW_SIZE, ROW_HEIGHT, PADDING, FOOTER = 8, 24, 30, 6, 16
local WHITE = "Interface\\Buttons\\WHITE8x8"
local popup, owner, events, tabHooked, previousTab, accept

local function restricted(value)
    if _G.issecretvalue and _G.issecretvalue(value) then return true end
    if _G.canaccessvalue and not _G.canaccessvalue(value) then return true end
    return E.IsRestricted and E:IsRestricted(value) or false
end

local function dismiss(editor)
    local state = attached[editor]
    if not state or not state.active then return end
    state.active, state.completion, state.text, state.cursor, state.selected = false, nil, nil, nil, nil
    if state.arrows ~= nil then editor:SetAltArrowKeyMode(state.arrows); state.arrows = nil end
    if owner == editor then
        owner = nil
        if popup then popup:Hide() end
    end
end

function E:DismissCompletion()
    if owner then dismiss(owner) end
end

local function leave()
    if owner and popup and not popup:IsMouseOver() and not owner:HasFocus() then dismiss(owner) end
end

local function createPopup()
    popup = _G.CreateFrame("Frame", "ForeverEmotesSuggest", _G.UIParent)
    popup:SetFrameStrata("TOOLTIP"); popup:SetClampedToScreen(true); popup:EnableMouse(true)
    local background = popup:CreateTexture(nil, "BACKGROUND")
    background:SetColorTexture(0.055, 0.059, 0.078, 0.96); background:SetAllPoints(popup)
    local accent = popup:CreateTexture(nil, "BORDER")
    accent:SetColorTexture(145 / 255, 70 / 255, 1, 1); accent:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT"); accent:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT"); accent:SetHeight(1)
    popup.rows = {}
    for i = 1, MAX_ROWS do
        local row = _G.CreateFrame("Button", nil, popup)
        row.index = i
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("TOPLEFT", popup, "TOPLEFT", PADDING, -PADDING - (i - 1) * ROW_HEIGHT)
        row:SetPoint("RIGHT", popup, "RIGHT", -PADDING, 0)
        row.selection = row:CreateTexture(nil, "BACKGROUND")
        row.selection:SetColorTexture(0.235, 0.133, 0.365, 1); row.selection:SetAllPoints(row); row.selection:Hide()
        row:SetHighlightTexture(WHITE, "ADD"); row:GetHighlightTexture():SetColorTexture(169 / 255, 112 / 255, 1, 0.14)
        row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.label:SetPoint("LEFT", row, "LEFT", 6, 0); row.label:SetJustifyH("LEFT"); row.label:SetWordWrap(false)
        row:SetScript("OnClick", function(self) if owner then accept(owner, self.index) end end)
        row:SetScript("OnLeave", leave)
        popup.rows[i] = row
    end
    popup.hint = popup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    popup.hint:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", PADDING + 6, PADDING - 2)
    popup.hint:SetText(type(_G.PRESS_TAB) == "string" and _G.PRESS_TAB or "Press Tab")
    popup:SetScript("OnLeave", leave)
    popup:Hide()
end

local function paintSelection(state)
    for i, row in ipairs(popup.rows) do row.selection:SetShown(i == state.selected) end
end

local function show(editor, state)
    if not popup then createPopup() end
    local entries, width = state.completion.entries, 0
    for i, row in ipairs(popup.rows) do
        local entry = entries[i]
        row.entry = entry
        if entry then
            row.label:SetText(E:Render(entry, PREVIEW_SIZE) .. "  " .. entry.name)
            width = math.max(width, row.label:GetStringWidth())
        end
        row:SetShown(entry ~= nil)
    end
    paintSelection(state)
    popup:SetSize(math.max(160, width + 2 * PADDING + 16), math.min(#entries, MAX_ROWS) * ROW_HEIGHT + 2 * PADDING + FOOTER)
    popup:ClearAllPoints(); popup:SetPoint("BOTTOMLEFT", editor, "TOPLEFT", 0, 2)
    -- The chat box ignores plain arrows; the native list lifts that while it is shown, and so does this one.
    if state.arrows == nil then state.arrows = editor:GetAltArrowKeyMode() and true or false; editor:SetAltArrowKeyMode(false) end
    popup:Show(); popup:Raise()
end

local function update(editor)
    local state = attached[editor]
    if not state or state.applying then return end
    local text, cursor = E:GetSafeEditorText(editor)
    if not text or not E.db or not E.db.enabled or not editor:HasFocus() or not editor:IsShown() or editor.disallowAutoComplete or text:sub(1, 1) == "/" then
        dismiss(editor); return
    end
    local completion = E:Complete(text, cursor, MAX_ROWS)
    if not completion or type(completion.entries) ~= "table" or #completion.entries == 0 then dismiss(editor); return end
    if owner and owner ~= editor then dismiss(owner) end
    local same = state.active and state.text == text and state.cursor == cursor and state.selected and state.selected <= #completion.entries
    state.active, state.completion, state.text, state.cursor, state.selected = true, completion, text, cursor, same and state.selected or 1
    owner = editor
    show(editor, state)
end

-- Enter is never captured: it always sends the line as typed. Only Tab or a click applies a suggestion.
accept = function(editor, index)
    local state = attached[editor]
    if not state or not state.active or owner ~= editor then return false end
    local completion = state.completion
    local entry = completion.entries[index or state.selected]
    local text, cursor = E:GetSafeEditorText(editor)
    local valid = E.db and E.db.enabled and text and text == state.text and cursor == state.cursor and entry and E:GetEmote(entry.name)
    dismiss(editor)
    if not valid then return true end
    local limit = editor.GetVisibleTextByteLimit and editor:GetVisibleTextByteLimit()
    if restricted(limit) or type(limit) ~= "number" or limit <= 0 then limit = nil end
    local replacement, position = E:ApplyCompletion(text, completion, entry.name, limit)
    if type(replacement) ~= "string" or type(position) ~= "number" then return true end
    if limit and (E.VisibleTextBytes and E:VisibleTextBytes(replacement) or #replacement) > limit then return true end
    state.applying = true
    editor:SetText(replacement); editor:SetCursorPosition(position)
    state.applying = false
    return true
end

-- Blizzard calls this global through securecall from ChatFrameEditBoxMixin:OnTabPressed for addon tab completion.
local function tabPressed(editBox, ...)
    if not restricted(editBox) and editBox ~= nil and owner == editBox and accept(editBox) then return true end
    if previousTab then return previousTab(editBox, ...) end
end

local function arrow(editor, key)
    local state = attached[editor]
    if not state or not state.active or owner ~= editor or not popup then return end
    local count = math.min(#state.completion.entries, MAX_ROWS)
    if key == "UP" then state.selected = (state.selected - 2) % count + 1
    elseif key == "DOWN" then state.selected = state.selected % count + 1
    else return end
    paintSelection(state)
end

local function focusLost(editor)
    -- Retail clears edit focus on mouse down outside sticky frames; keep the list for the click that follows.
    if owner == editor and popup and popup:IsShown() and popup:IsMouseOver() then return end
    dismiss(editor)
end

function E:AttachCompletion(editor)
    if restricted(editor) or not editor or attached[editor] or not editor.HookScript then return end
    if not events then
        events = _G.CreateFrame("Frame")
        events:SetScript("OnEvent", function(_, event, restrictionType, restrictionState)
            if event == "PLAYER_REGEN_DISABLED" then E:DismissCompletion()
            elseif restrictionType == _G.Enum.AddOnRestrictionType.Chat and restrictionState == _G.Enum.AddOnRestrictionState.Activating then
                E:DismissCompletion()
            end
        end)
        events:RegisterEvent("PLAYER_REGEN_DISABLED")
        if _G.Enum and _G.Enum.AddOnRestrictionType and _G.Enum.AddOnRestrictionState then events:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED") end
    end
    if not tabHooked then
        tabHooked = true
        previousTab = _G.ChatEdit_CustomTabPressed
        _G.ChatEdit_CustomTabPressed = tabPressed
    end
    attached[editor] = {}
    editor:HookScript("OnTextChanged", function(self) update(self) end)
    editor:HookScript("OnCursorChanged", function(self) update(self) end)
    editor:HookScript("OnEditFocusGained", function(self) update(self) end)
    editor:HookScript("OnEditFocusLost", focusLost)
    editor:HookScript("OnHide", function(self) dismiss(self) end)
    editor:HookScript("OnEscapePressed", function(self) dismiss(self) end)
    editor:HookScript("OnArrowPressed", arrow)
end
