-- Frame stubs good enough to run SRCheck's UI code paths (layout calls are
-- no-ops; text, checked state, visibility, parents and scripts are tracked).
-- Load after wowstub.lua.

local Obj = {}
local function newObj(parent, kind)
    return setmetatable({ parent = parent, kind = kind, scripts = {}, shown = true }, Obj)
end

local methods = {
    SetScript = function(self, name, fn) self.scripts[name] = fn end,
    GetScript = function(self, name) return self.scripts[name] end,
    HookScript = function(self, name, fn) self.scripts[name] = fn end,
    Fire = function(self, name, ...)
        local fn = self.scripts[name]
        if fn then return fn(self, ...) end
    end,
    Show = function(self)
        local was = self.shown
        self.shown = true
        if not was then self:Fire("OnShow") end
    end,
    Hide = function(self)
        local was = self.shown
        self.shown = false
        if was then self:Fire("OnHide") end
    end,
    SetShown = function(self, v) if v then self:Show() else self:Hide() end end,
    IsShown = function(self)
        local o = self
        while o do
            if not rawget(o, "shown") then return false end
            o = rawget(o, "parent")
        end
        return true
    end,
    SetText = function(self, t) self.text_ = t end,
    GetText = function(self) return rawget(self, "text_") or "" end,
    SetChecked = function(self, v) self.checked = v and true or false end,
    GetChecked = function(self) return rawget(self, "checked") end,
    -- Like WoW: only one edit box has focus; clicking buttons does not take it away.
    SetFocus = function(self)
        local current = TEST.focused
        if current and current ~= self then current:ClearFocus() end
        TEST.focused = self
        self.focus = true
    end,
    ClearFocus = function(self)
        if rawget(self, "focus") then
            self.focus = false
            if TEST.focused == self then TEST.focused = nil end
            self:Fire("OnEditFocusLost")
        end
    end,
    HasFocus = function(self) return rawget(self, "focus") and true or false end,
    GetParent = function(self) return rawget(self, "parent") end,
    GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end,
    GetFrameLevel = function() return 1 end,
}

-- WoW widget methods are CamelCase; anything else is a plain (nil) field.
Obj.__index = function(_, k)
    if methods[k] then return methods[k] end
    if not k:match("^%u") then return nil end
    if k:match("^Create") then
        return function(self) return newObj(self, k) end
    end
    if k:match("^Get") then return function() return 0 end end
    if k:match("^Is") or k:match("^Has") then return function() return false end end
    return function() end
end

function CreateFrame(kind, _, parent)
    local o = newObj(parent, kind)
    o.shown = true
    return o
end

UIParent = newObj(nil, "UIParent")
UISpecialFrames = {}
GameTooltip = newObj(nil, "GameTooltip")
GameTooltip.SetText = function(_, line) TEST.tooltip = { line } end
GameTooltip.AddLine = function(_, line) table.insert(TEST.tooltip, line) end
function GameTooltip_Hide() end
function IsShiftKeyDown() return false end
function StaticPopup_Show(name, arg) TEST.popup = { name = name, arg = arg } end
