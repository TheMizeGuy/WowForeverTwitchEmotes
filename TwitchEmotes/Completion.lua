local addonName, E = ...
-- Copyright (c) 2026 TheMizeGuy. All rights reserved.

local attached = setmetatable({}, { __mode = "k" })
local owner, events
local preview, previewHooked
local PREVIEW_SIZE, PREVIEW_ROW_HEIGHT = 24, 32

local function restorePreview()
    if not preview then return false end
    for button, size in pairs(preview.rows) do button:SetSize(size.width, size.height) end
    _G.AutoCompleteBox.maxHeight = preview.maxHeight
    preview = nil
    return true
end

local function paintPreview(box, results)
    local state = owner and attached[owner]
    if not state or not state.updating or box.parent ~= owner then
        if restorePreview() and box:IsShown() then
            box:SetHeight(math.min(#results, _G.AUTOCOMPLETE_MAX_BUTTONS) * _G.AutoCompleteButton1:GetHeight() + 35)
        end
        return
    end
    if not preview then return end
    local width = box:GetWidth()
    for i, info in ipairs(results) do
        local button = _G["AutoCompleteButton" .. i]
        local entry = info.foreverEmote and E:GetEmote(info.foreverEmote)
        if button and entry then
            button:SetText(E:Render(entry, PREVIEW_SIZE) .. "  " .. entry.name)
            width = math.max(width, button:GetFontString():GetStringWidth() + 30)
        end
    end
    box:SetWidth(width)
    for button in pairs(preview.rows) do button:SetWidth(width) end
end

local function preparePreview()
    local box = _G.AutoCompleteBox
    if not box or not _G.AutoCompleteButton1 then return end
    if not previewHooked then
        -- Native selection hides the box before invoking our insertion callback.
        -- Restore presentation here without clearing the pending completion.
        box:HookScript("OnHide", restorePreview)
        _G.hooksecurefunc("AutoComplete_UpdateResults", paintPreview)
        previewHooked = true
    end
    if preview then return end
    preview = { rows = {}, maxHeight = box.maxHeight }
    for i = 1, _G.AUTOCOMPLETE_MAX_BUTTONS do
        local button = _G["AutoCompleteButton" .. i]
        if button then
            preview.rows[button] = { width = button:GetWidth(), height = button:GetHeight() }
            button:SetHeight(PREVIEW_ROW_HEIGHT)
        end
    end
    -- Native positioning must account for the taller rows before choosing above/below.
    box.maxHeight = _G.AUTOCOMPLETE_MAX_BUTTONS * PREVIEW_ROW_HEIGHT
end

local function dismiss(editor)
    local state = attached[editor]
    if not state or not state.active then return end
    if _G.AutoComplete_HideIfAttachedTo then _G.AutoComplete_HideIfAttachedTo(editor) end
    if editor.autoCompleteSource == state.source then
        editor.autoCompleteSource, editor.autoCompleteParams = state.previousSource, state.previousParams
    end
    if editor.customAutoCompleteFunction == state.callback then editor.customAutoCompleteFunction = state.previousCallback end
    if editor.autoCompleteContext == "none" then editor.autoCompleteContext = state.previousContext end
    state.active, state.completion, state.text, state.cursor = false, nil, nil, nil
    if owner == editor then owner = nil end
end

function E:DismissCompletion()
    if owner then dismiss(owner) end
end

local function update(editor)
    local state = attached[editor]
    if not state or state.applying then return end
    local text, cursor = E:GetSafeEditorText(editor)
    if not text or not E.db or not E.db.enabled or not editor:HasFocus() or not editor:IsShown() or editor.disallowAutoComplete then
        dismiss(editor); return
    end
    local completion = E:Complete(text, cursor, math.min(8, _G.AUTOCOMPLETE_MAX_BUTTONS or 5))
    if not completion or not completion.entries or #completion.entries == 0 then dismiss(editor); return end
    if owner and owner ~= editor then dismiss(owner) end
    if editor.autoCompleteSource ~= state.source then
        state.previousSource, state.previousParams = editor.autoCompleteSource, editor.autoCompleteParams
    end
    if editor.customAutoCompleteFunction ~= state.callback then state.previousCallback = editor.customAutoCompleteFunction end
    if not state.active or editor.autoCompleteContext ~= "none" then state.previousContext = editor.autoCompleteContext end
    state.active, state.completion, state.text, state.cursor = true, completion, text, cursor
    owner = editor
    _G.AutoCompleteEditBox_SetAutoCompleteSource(editor, state.source)
    _G.AutoCompleteEditBox_SetCustomAutoCompleteFunction(editor, state.callback)
    editor.autoCompleteContext = "none"
    -- A neutral query avoids native realm-name expansion for punctuation in emote names.
    -- Only this explicit call can receive our source entries: ChatFrameEditBox:OnChar
    -- also invokes autoCompleteSource and would otherwise replace the entire draft.
    preparePreview()
    state.updating = true
    _G.AutoComplete_Update(editor, ":", 1)
    state.updating = false
end

function E:AttachCompletion(editor)
    if _G.issecretvalue and _G.issecretvalue(editor) then return end
    if _G.canaccessvalue and not _G.canaccessvalue(editor) then return end
    if not editor or attached[editor] or not editor.HookScript then return end
    if not _G.AutoComplete_Update or not _G.AutoCompleteEditBox_SetAutoCompleteSource or not _G.AutoCompleteEditBox_SetCustomAutoCompleteFunction then return end
    if not events then
        events = _G.CreateFrame("Frame")
        events:SetScript("OnEvent", function(_, event, restrictionType, restrictionState)
            if event == "PLAYER_REGEN_DISABLED" then E:DismissCompletion()
            elseif restrictionType == _G.Enum.AddOnRestrictionType.Chat and restrictionState == _G.Enum.AddOnRestrictionState.Activating then
                E:DismissCompletion()
            end
        end)
        events:RegisterEvent("PLAYER_REGEN_DISABLED")
        if _G.Enum.AddOnRestrictionType and _G.Enum.AddOnRestrictionState then events:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED") end
    end
    local state = {}
    attached[editor] = state
    state.source = function()
        local results = {}
        if state.updating and state.active and state.completion then
            for i, entry in ipairs(state.completion.entries) do
                if i > math.min(8, _G.AUTOCOMPLETE_MAX_BUTTONS or 5) then break end
                results[i] = { name = entry.name, priority = _G.Enum.AutoCompletePriority.Other, foreverEmote = entry.name }
            end
        end
        return results
    end
    state.callback = function(box, newText, info, name)
        if not info or not info.foreverEmote then
            if state.previousCallback then return state.previousCallback(box, newText, info, name) end
            return false
        end
        local text, cursor = E:GetSafeEditorText(box)
        local completion = state.completion
        local valid = E.db.enabled and text and text == state.text and cursor == state.cursor and completion and E:GetEmote(info.foreverEmote)
        dismiss(box)
        if valid then
            local replacement, position = E:ApplyCompletion(text, completion, info.foreverEmote)
            state.applying = true
            box:SetText(replacement); box:SetCursorPosition(position)
            state.applying = false
        end
        -- Consume stale or restricted selections as well; native fallback replaces all text.
        return true
    end
    editor:HookScript("OnTextChanged", function(self) update(self) end)
    editor:HookScript("OnCursorChanged", function(self) update(self) end)
    editor:HookScript("OnEditFocusGained", function(self) update(self) end)
    editor:HookScript("OnEditFocusLost", function(self) dismiss(self) end)
    editor:HookScript("OnHide", function(self) dismiss(self) end)
    editor:HookScript("OnEscapePressed", function(self) dismiss(self) end)
    -- Native AutoCompleteBox handles Tab/arrows and invokes our callback on Enter/click.
    -- Its OnHide occurs BEFORE that callback, so restoring there would lose the draft.
end
