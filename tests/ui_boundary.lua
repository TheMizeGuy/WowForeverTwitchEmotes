-- Copyright (c) 2026 TheMizeGuy. All rights reserved.
-- External WoW UI boundary used by the UI behavior tests.
local B = { frames = {}, focus = nil, combat = false, chatLockdown = false, time = 0, filters = {}, chats = {}, tickers = {}, callbacks = {}, after = {} }
local Frame = {}
Frame.__index = Frame
function Frame:SetScript(event, fn) self.scripts[event] = fn end
function Frame:GetScript(event) return self.scripts[event] end
function Frame:RegisterCallback(event, callback, owner)
    self.callbacks = self.callbacks or {}; self.callbacks[event] = { callback = callback, owner = owner }
end
function Frame:SetScrollPercentage(value)
    self.scrollPercentage = value
    local record = self.callbacks and self.callbacks.OnScroll
    if record then record.callback(record.owner, value) end
end
function Frame:SetVisibleExtentPercentage(value) self.visibleExtent = value end
function Frame:SetPanExtentPercentage(value) self.panExtent = value end
function Frame:HookScript(event, fn)
    local before = self.scripts[event]
    self.scripts[event] = function(frame, ...) if before then before(frame, ...) end; fn(frame, ...) end
end
function Frame:RegisterEvent(event) self.events = self.events or {}; self.events[event] = true end
function Frame:UnregisterEvent(event) if self.events then self.events[event] = nil end end
function Frame:AddOnDisplayRefreshedCallback(callback)
    self.displayCallbacks = self.displayCallbacks or {}; self.displayCallbacks[#self.displayCallbacks + 1] = callback
end
function Frame:RefreshDisplay() for _, callback in ipairs(self.displayCallbacks or {}) do callback(self) end end
function Frame:Run(event, ...) if self.scripts[event] then return self.scripts[event](self, ...) end end
function Frame:Show() local hidden = not self.shown; self.shown = true; if hidden then self:Run("OnShow") end end
function Frame:Hide() local shown = self.shown; self.shown = false; if shown then self:Run("OnHide") end end
function Frame:IsShown() return self.shown end
function Frame:IsVisible() return self.shown and (not self.parent or self.parent:IsVisible()) end
function Frame:IsMouseOver() return self.mouseOver or false end
function Frame:SetShown(value) if value then self:Show() else self:Hide() end end
function Frame:SetText(text)
    self.text = tostring(text); self.cursor = #self.text
    if self.font then self.font:SetText(self.text) end
    self:Run("OnTextChanged", false)
end
function Frame:GetText() return self.text or "" end
function Frame:SetCursorPosition(cursor) self.cursor = cursor; self:Run("OnCursorChanged", cursor, 0, 1, 14) end
function Frame:GetCursorPosition() return self.cursor or #self:GetText() end
function Frame:Insert(text)
    local cursor = self:GetCursorPosition()
    self:SetText(self:GetText():sub(1, cursor) .. text .. self:GetText():sub(cursor + 1))
    self:SetCursorPosition(cursor + #text)
end
function Frame:SetFocus()
    if B.focus == self then return end
    if B.focus then B.focus:ClearFocus() end
    B.focus = self; self:Run("OnEditFocusGained")
end
function Frame:ClearFocus() if B.focus == self then B.focus = nil; self:Run("OnEditFocusLost") end end
function Frame:HasFocus() return B.focus == self end
function Frame:SetSize(w, h) self.width = w; self.height = h end
function Frame:SetWidth(w) self.width = w end
function Frame:SetHeight(h) self.height = h end
function Frame:GetWidth() return self.width or 100 end
function Frame:GetHeight() return self.height or 30 end
function Frame:SetMinMaxValues(low, high) self.minimum, self.maximum=low,high end
function Frame:GetMinMaxValues() return self.minimum,self.maximum end
function Frame:SetValueStep(step) self.valueStep=step end
function Frame:SetObeyStepOnDrag(obey) self.obeyStep=obey end
function Frame:SetOrientation(orientation) self.orientation=orientation end
function Frame:SetValue(value)
    value=math.max(self.minimum,math.min(self.maximum,value))
    if self.value==value then return end
    self.value=value; self:Run("OnValueChanged",value)
end
function Frame:GetValue() return self.value end
function Frame:SetThumbTexture(path) self.thumb=self.thumb or self:CreateTexture(); self.thumb:SetTexture(path) end
function Frame:GetThumbTexture() return self.thumb end
function Frame:SetPoint(...) self.point = { ... } end
function Frame:GetPoint() return unpack(self.point or {}) end
function Frame:ClearAllPoints() self.point = nil end
function Frame:SetScale(scale) self.scale = scale end
function Frame:GetEffectiveScale() return self.scale or 1 end
function Frame:GetCenter() return 100, 100 end
function Frame:GetBottom() return 200 end
function Frame:GetParent() return self.parent end
function Frame:SetParent(parent) self.parent = parent end
function Frame:SetFrameLevel(level) self.frameLevel = level end
function Frame:GetFrameLevel() return self.frameLevel or (self.parent and self.parent:GetFrameLevel() + 1 or 0) end
function Frame:SetFrameStrata(strata) self.frameStrata = strata end
function Frame:GetFrameStrata() return self.frameStrata or (self.parent and self.parent:GetFrameStrata() or "MEDIUM") end
function Frame:GetName() return self.name end
function Frame:SetChecked(value) self.checked = value and true or false end
function Frame:GetChecked() return self.checked end
function Frame:SetEnabled(value) self.enabled = value end
function Frame:Enable() self.enabled = true end
function Frame:Disable() self.enabled = false end
function Frame:IsEnabled() return self.enabled end
function Frame:Click(button)
    if self.enabled == false then return end
    if self.kind == "CheckButton" then self.checked = not self.checked end
    self:Run("OnClick", button or "LeftButton")
end
function Frame:LockHighlight() self.highlighted = true end
function Frame:UnlockHighlight() self.highlighted = false end
function Frame:SetPropagateKeyboardInput(value) self.propagate = value end
function Frame:IsForbidden() return self.forbidden or false end
function Frame:CanBeAccessedInContext() return not self.inaccessible end
function Frame:HasAnyForbiddenAspects() return self.scriptedInput or false end
function Frame:SetAltArrowKeyMode(value) self.altArrows = value end
function Frame:GetAltArrowKeyMode() return self.altArrows end
function Frame:CreateFontString() return B.new("FontString", nil, self) end
function Frame:CreateTexture() return B.new("Texture", nil, self) end
function Frame:CreateMaskTexture() return B.new("MaskTexture", nil, self) end
function Frame:AddMaskTexture(mask) self.mask=mask end
function Frame:GetFontString() if not self.font then self.font = self:CreateFontString() end; return self.font end
function Frame:SetFontString(font) self.font = font end
function Frame:GetStringWidth()
    local images = 0
    local text = self:GetText():gsub("|T([^|]+)|t", function(texture)
        images = images + (tonumber(texture:match("^.-:%d+:(%d+)")) or 0); return ""
    end):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return #text * 7 + images
end
for _, method in ipairs({"SetAllPoints", "SetAutoFocus", "EnableMouse", "EnableMouseWheel", "EnableKeyboard", "SetClampedToScreen", "SetMovable", "RegisterForDrag", "RegisterForClicks", "StartMoving", "StopMovingOrSizing", "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetFontObject", "SetTextColor", "SetTexture", "SetTexCoord", "SetVertexColor", "SetColorTexture", "SetAtlas", "SetDesaturated", "SetDrawLayer", "SetHitRectInsets", "SetNormalFontObject", "SetHighlightFontObject", "SetDisabledFontObject", "SetMaxLetters", "HighlightText", "SetTextInsets", "SetNumeric", "Raise"}) do
    Frame[method] = function() end
end
function Frame:SetColorTexture(...) self.color={...} end
function Frame:SetTextColor(...) self.textColor={...} end
function Frame:SetTexture(path) self.texture=path end
function Frame:SetAtlas(atlas) self.atlas=atlas end
for _, state in ipairs({ "Normal", "Highlight", "Pushed", "Disabled", "Checked" }) do
    local field = state .. "Texture"
    Frame["Set" .. field] = function(self) if not self[field] then self[field] = self:CreateTexture() end end
    Frame["Get" .. field] = function(self) return self[field] end
end
function B.new(kind, name, parent, template)
    local frame = setmetatable({ kind = kind, name = name, parent = parent, template = template, scripts = {}, shown = true, enabled = true }, Frame)
    if kind == "Slider" then frame.Click=false; frame.LockHighlight=false; frame.UnlockHighlight=false end
    B.frames[#B.frames + 1] = frame
    if name then _G[name] = frame end
    if template == "BasicFrameTemplateWithInset" then
        frame.TitleText = frame:CreateFontString(); frame.CloseButton = B.new("Button", nil, frame)
        frame.CloseButton:SetScript("OnClick", function() frame:Hide() end)
    end
    if template == "UICheckButtonTemplate" then frame.Text = frame:CreateFontString() end
    return frame
end
_G.CreateFrame = B.new
_G.UIParent = B.new("Frame", "UIParent"); UIParent:SetSize(1280, 720)
-- Forever's rim is an overlay on MinimapBackdrop, one frame level above Minimap.
_G.MinimapCluster = B.new("Frame", "MinimapCluster", UIParent); MinimapCluster:SetFrameStrata("LOW")
MinimapCluster.MinimapContainer = B.new("Frame", nil, MinimapCluster)
_G.Minimap = B.new("Frame", "Minimap", MinimapCluster.MinimapContainer); Minimap:SetSize(198, 198)
_G.MinimapBackdrop = B.new("Frame", "MinimapBackdrop", Minimap)
_G.UISpecialFrames = {}
_G.GetCurrentKeyBoardFocus = function() return B.focus end
_G.GetTime = function() return B.time end
_G.UnitGUID = function(unit) assert(unit == "player"); return "Player-self" end
_G.SlashCmdList = {}
_G.C_Timer = { After = function(_, callback) B.after[#B.after + 1] = callback end, NewTicker = function(interval, callback)
    local ticker = { interval = interval, callback = callback }
    function ticker:Cancel() self.cancelled = true end
    B.tickers[#B.tickers + 1] = ticker; return ticker
end }
_G.EventRegistry = { RegisterCallback = function(_, name, callback, owner)
    B.callbacks[name] = B.callbacks[name] or {}; B.callbacks[name][#B.callbacks[name] + 1] = { callback = callback, owner = owner }
end }
_G.GetCursorPosition = function() return 210, 100 end
_G.InCombatLockdown = function() return B.combat end
_G.IsShiftKeyDown = function() return B.shift or false end
_G.C_ChatInfo = { InChatMessagingLockdown = function() return B.chatLockdown end }
_G.Enum = { ForbiddenAspect = { ScriptedInput = 1 }, AutoCompletePriority = { Other = 0 } }
Enum.AddOnRestrictionType = { Chat = 5 }; Enum.AddOnRestrictionState = { Activating = 1 }
_G.issecretvalue = function(value) return type(value) == "table" and value.secret == true end
_G.canaccessvalue = function(value) return not issecretvalue(value) end
_G.GameTooltip = { lines = {}, colors = {}, SetOwner = function(self, owner) self.owner=owner; self.lines = {}; self.colors={} end, AddLine = function(self, text, r, g, b) self.lines[#self.lines + 1] = text; self.colors[#self.lines]={r,g,b} end, GetOwner=function(self) return self.owner end, Show = function(self) self.shown=true end, Hide = function(self) self.shown=false end, IsShown=function(self) return self.shown end }
_G.Settings = {
    RegisterCanvasLayoutCategory = function(panel, title) B.canvas = panel; return { name = title } end,
    RegisterAddOnCategory = function() B.categories = (B.categories or 0) + 1 end,
}
_G.ChatFrameUtil = {
    GetActiveWindow = function() return B.active end,
    ChooseBoxForSend = function() return B.editor end,
    ActivateChat = function(editor) B.active = editor; editor:Show(); editor:SetFocus() end,
    AddMessageEventFilter = function(event, callback)
        B.filters[event] = B.filters[event] or {}; B.filters[event][#B.filters[event] + 1] = callback
    end,
    ForEachChatFrame = function(callback) for _, frame in ipairs(B.chats) do callback(frame) end end,
}

-- Model only native autocomplete's supported public extension points and key behavior.
_G.AUTOCOMPLETE_MAX_BUTTONS = 5
_G.AutoCompleteBox = B.new("Frame", "AutoCompleteBox", UIParent); AutoCompleteBox:Hide()
AutoCompleteBox.maxHeight = 70
for i = 1, AUTOCOMPLETE_MAX_BUTTONS do
    local button = B.new("Button", "AutoCompleteButton" .. i, AutoCompleteBox)
    button:SetSize(120, 14); button:GetFontString(); button:Hide()
end
_G.hooksecurefunc = function(name, callback)
    local original = assert(_G[name])
    _G[name] = function(...) local result = original(...); callback(...); return result end
end
_G.AutoCompleteEditBox_SetAutoCompleteSource = function(editor, source, ...)
    editor.autoCompleteSource = source; editor.autoCompleteParams = { ... }
end
_G.AutoCompleteEditBox_SetCustomAutoCompleteFunction = function(editor, callback) editor.customAutoCompleteFunction = callback end
_G.AutoComplete_UpdateResults = function(box, results)
    box.results, box.selectedIndex = results, 1
    local count, width = math.min(#results, AUTOCOMPLETE_MAX_BUTTONS), 120
    for i = 1, AUTOCOMPLETE_MAX_BUTTONS do
        local button = _G["AutoCompleteButton" .. i]
        button.nameInfo = results[i]
        if i <= count then
            button:SetText(results[i].name); button:Enable()
            width = math.max(width, button:GetFontString():GetStringWidth() + 30)
        end
        button:SetShown(i <= count)
    end
    box.numResults = count; box:SetHeight(count * AutoCompleteButton1:GetHeight() + 35); box:SetWidth(width)
    box:SetShown(count > 0)
end
_G.AutoComplete_Update = function(editor, query, cursor)
    local results = editor.autoCompleteSource(query, 6, cursor, true, unpack(editor.autoCompleteParams))
    AutoCompleteBox.parent = editor
    AutoComplete_UpdateResults(AutoCompleteBox, results, editor.autoCompleteContext)
end
_G.AutoComplete_HideIfAttachedTo = function(editor)
    if AutoCompleteBox.parent == editor then AutoCompleteBox.parent = nil; AutoCompleteBox:Hide() end
end
function B.editorFrame()
    local editor = B.new("EditBox", nil, UIParent); editor:SetText("")
    editor:SetScript("OnTabPressed", function(self)
        if AutoCompleteBox:IsShown() and AutoCompleteBox.parent == self then
            AutoCompleteBox.selectedIndex = AutoCompleteBox.selectedIndex % #AutoCompleteBox.results + 1
        else B.nativeTabs = (B.nativeTabs or 0) + 1 end
    end)
    editor:SetScript("OnArrowPressed", function(self, key)
        if AutoCompleteBox:IsShown() and AutoCompleteBox.parent == self then
            local delta = key == "UP" and -1 or 1
            AutoCompleteBox.selectedIndex = (AutoCompleteBox.selectedIndex - 1 + delta) % #AutoCompleteBox.results + 1
        end
    end)
    editor:SetScript("OnEscapePressed", function(self)
        if AutoCompleteBox:IsShown() and AutoCompleteBox.parent == self then AutoComplete_HideIfAttachedTo(self)
        else self:SetText(""); self:ClearFocus() end
    end)
    editor:SetScript("OnEnterPressed", function(self)
        if AutoCompleteBox:IsShown() and AutoCompleteBox.parent == self then
            local info = AutoCompleteBox.results[AutoCompleteBox.selectedIndex]
            AutoCompleteBox:Hide()
            if not (self.customAutoCompleteFunction and self.customAutoCompleteFunction(self, info.name, info, info.name)) then self:SetText(info.name) end
        else B.sent = self:GetText() end
    end)
    editor:SetScript("OnEditFocusLost", AutoComplete_HideIfAttachedTo)
    return editor
end
function B.find(text, parent)
    for _, frame in ipairs(B.frames) do
        if frame.text == text and (not parent or frame.parent == parent) then return frame end
        if frame.tooltipText == text and (not parent or frame.parent == parent) then return frame end
        if frame.Text and frame.Text.text == text and (not parent or frame.parent == parent) then return frame end
    end
end
function B.type(editor, text, cursor)
    editor:SetFocus(); editor.text = text; editor.cursor = cursor or #text
    editor:Run("OnTextChanged", true)
end
function B.event(event, ...)
    for _, frame in ipairs(B.frames) do if frame.events and frame.events[event] then frame:Run("OnEvent", event, ...) end end
end
function B.callback(event, ...)
    for _, record in ipairs(B.callbacks[event] or {}) do record.callback(record.owner, ...) end
end
function B.tick(now)
    B.time = now
    for _, ticker in ipairs(B.tickers) do if not ticker.cancelled then ticker.callback() end end
end
function B.nextFrame()
    local callbacks = B.after; B.after = {}
    for _, callback in ipairs(callbacks) do callback() end
end
function B.liveTickers()
    local count = 0; for _, ticker in ipairs(B.tickers) do if not ticker.cancelled then count = count + 1 end end
    return count
end
return B
