-- Options: rule profiles (base SRs per role, raid assignments, buff groups,
-- rules) and general options.
--
-- Every edit box saves on each keystroke, so what is shown is what is stored:
-- nothing is lost on Escape, on clicking a button or on closing the window.
-- Rows are bound to an index of the active profile, so anything that changes
-- which data a row shows (switching profile, adding/deleting rows) first takes
-- focus away from every box - otherwise typing would continue into the wrong
-- profile or row.

local _, SRC = ...

local MAX_GROUPS, MAX_RULES, MAX_ASSIGNMENTS = 5, 6, 3
local LINE_H = 26
local ASSIGN_Y, GROUP_TOP, RULE_TOP = -93, -160, -356

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local copy = {}
    for k, val in pairs(v) do copy[k] = deepCopy(val) end
    return copy
end

local function label(parent, text, x, y, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

local editBoxes = {}

local function editBox(parent, width, onChange, tooltip)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetSize(width, 20)
    eb:SetAutoFocus(false)
    eb:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end -- our own SetText
        onChange(self, SRC.Trim(self:GetText()))
        SRC:RefreshOptions()
        SRC:RefreshUI()
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    eb:SetScript("OnEditFocusLost", function(self)
        self:HighlightText(0, 0)
        SRC:RefreshOptions() -- show what is stored (e.g. an empty name is not taken)
    end)
    if tooltip then
        eb:SetScript("OnEnter", function(self) SRC.ShowTooltip(self, tooltip(self)) end)
        eb:SetScript("OnLeave", GameTooltip_Hide)
    end
    editBoxes[#editBoxes + 1] = eb
    return eb
end

local function setText(eb, text)
    if not eb:HasFocus() then
        eb:SetText(text or "")
        eb:SetCursorPosition(0)
    end
end

local function profile() return SRC:GetProfile() end

------------------------------------------------------------
-- Tooltips
------------------------------------------------------------
local function spellsTooltip(eb)
    local lines = { "Buffs in this group",
        "Comma separated spell IDs or exact buff names; a name ending in * matches any buff starting with it. "
        .. "Alternatives joined with / count once (e.g. a buff's old and new ID, or the eight Darkmoon Faire fortunes)." }
    for _, entry in ipairs(SRC.ParseSpellList(eb:GetText())) do
        local names = {}
        for _, l in ipairs(entry.labels) do
            local id = tonumber(l)
            if id then
                local name = SRC.SpellName(id)
                names[#names + 1] = name and (name .. " |cff9d9d9d" .. id .. "|r") or ("|cffff4040unknown spell " .. id .. "|r")
            else
                names[#names + 1] = l
            end
        end
        lines[#lines + 1] = "- " .. table.concat(names, " / ")
    end
    return lines
end

local function conditionTooltip(eb)
    local lines = { "Condition",
        "Buff group names with counts; 'or' for alternatives, '+' (or 'and') for combinations.",
        "|cffffffffExamples:|r  3 WB   -   Flask   -   6 WB or 3 WB + Flask" }
    local rule = profile().rules[eb.index]
    local err = rule and SRC.ValidateRule(profile(), rule)
    if err then lines[#lines + 1] = "|cffff4040" .. err .. "|r" end
    for _, name in ipairs(rule and not err and SRC.RuleEmptyGroups(profile(), rule) or {}) do
        lines[#lines + 1] = ("|cffffb000Group '%s' has no buffs listed, so it never counts.|r"):format(name)
    end
    return lines
end

------------------------------------------------------------
-- Build
------------------------------------------------------------
function SRC:BuildOptions()
    if self.options then return end
    local f = self:CreateWindow("SRCheckOptionsFrame", 740, 630, "SRCheck - rules")
    f:SetFrameStrata("DIALOG")

    -- Profile row
    label(f, "Profile:", 16, -38)
    local prev = self:Button(f, "<", 22, function() SRC:CycleProfile(-1) end)
    prev:SetPoint("TOPLEFT", 66, -32)
    f.profName = editBox(f, 150, function(_, text)
        local p = profile()
        if text == "" or text == p.name then return end
        for _, other in ipairs(SRC.db.profiles) do
            if other.name == text then return SRC:Print("a profile named '" .. text .. "' already exists.") end
        end
        for slug, name in pairs(SRC.db.instanceProfile) do
            if name == p.name then SRC.db.instanceProfile[slug] = text end
        end
        p.name = text
        SRC.db.activeProfile = text
    end, function() return { "Profile name", "Edit to rename." } end)
    f.profName:SetPoint("TOPLEFT", 98, -33)
    local nextB = self:Button(f, ">", 22, function() SRC:CycleProfile(1) end)
    nextB:SetPoint("TOPLEFT", 254, -32)

    local function addProfile(p)
        local base, n = p.name, 1
        local function taken(name)
            for _, other in ipairs(SRC.db.profiles) do
                if other.name == name then return true end
            end
        end
        while taken(p.name) do
            n = n + 1
            p.name = base .. " " .. n
        end
        table.insert(SRC.db.profiles, p)
        SRC:SetActiveProfile(p.name, true)
        SRC:RefreshOptions(true)
    end
    self:Button(f, "New", 54, function() addProfile(SRC:BaseProfile("Profile")) end,
        { "New profile", "Start from basic rules (3 WB +1, Flask +1). Selecting a profile while a raid is loaded "
            .. "remembers it for that instance (e.g. aq40)." }):SetPoint("TOPLEFT", 284, -32)
    self:Button(f, "Copy", 54, function()
        local p = deepCopy(profile())
        p.name = p.name .. " copy"
        addProfile(p)
    end):SetPoint("TOPLEFT", 342, -32)
    local delete = self:Button(f, "Delete", 64, nil)
    delete:SetPoint("TOPLEFT", 400, -32)
    delete:SetScript("OnClick", function(self)
        if #SRC.db.profiles <= 1 then return SRC:Print("can't delete the last profile.") end
        if not self.armed then
            self.armed = true
            self:SetText("Sure?")
            C_Timer.After(3, function() self.armed = nil; self:SetText("Delete") end)
            return
        end
        self.armed = nil
        self:SetText("Delete")
        local name = profile().name
        for i, p in ipairs(SRC.db.profiles) do
            if p.name == name then table.remove(SRC.db.profiles, i) break end
        end
        for slug, pname in pairs(SRC.db.instanceProfile) do
            if pname == name then SRC.db.instanceProfile[slug] = nil end
        end
        SRC:SetActiveProfile(SRC.db.profiles[1].name)
        SRC:RefreshOptions(true)
    end)
    f.usedFor = label(f, "", 474, -38, "GameFontHighlightSmall")

    -- Base SRs
    label(f, "Base SRs (no rules met):", 16, -68)
    f.base = {}
    local x = 170
    for _, role in ipairs(SRC.ROLES) do
        label(f, SRC.ROLE_LABEL[role], x, -68, "GameFontHighlightSmall")
        local eb = editBox(f, 30, function(_, text)
            local n = tonumber(text)
            if n then profile().base[role] = n end
        end)
        eb:SetPoint("TOPLEFT", x + 44, -63)
        f.base[role] = eb
        x = x + 100
    end

    -- Raid assignments: name + the role whose base SRs and rules they get
    local assignTip = { "Raid assignments",
        "Jobs like Pull Hunter or Mage Tank. Pick them per character in the Role menu of the main window;",
        "they get the base SRs and rules of the role shown here. Saved per character, for this profile only." }
    local assignLabel = label(f, "Raid assignments:", 16, ASSIGN_Y - 5)
    local assignHover = CreateFrame("Frame", nil, f)
    assignHover:SetAllPoints(assignLabel)
    assignHover:SetScript("OnEnter", function(self) SRC.ShowTooltip(self, assignTip) end)
    assignHover:SetScript("OnLeave", GameTooltip_Hide)
    f.assignments = {}
    for i = 1, MAX_ASSIGNMENTS do
        local ax = 132 + (i - 1) * 186
        local slot = {}
        local function assignment() return profile().assignments[i] end
        slot.name = editBox(f, 100, function(_, text)
            local a, p = assignment(), profile()
            if not a or text == "" or text == a.name then return end
            for key, name in pairs(p.assigned) do
                if name == a.name then p.assigned[key] = text end
            end
            a.name = text
        end, function() return assignTip end)
        slot.name:SetPoint("TOPLEFT", ax, ASSIGN_Y)
        slot.role = self:Button(f, "Tank", 52, function()
            local a = assignment()
            if not a then return end
            for r, role in ipairs(SRC.ROLES) do
                if role == a.role then
                    a.role = SRC.ROLES[r % #SRC.ROLES + 1]
                    break
                end
            end
            SRC:RefreshOptions()
            SRC:RefreshUI()
        end, { "Counts as", "Click to switch between DPS, Tank and Healer." })
        slot.role:SetPoint("TOPLEFT", ax + 104, ASSIGN_Y + 1)
        slot.del = self:Button(f, "X", 24, function()
            local a, p = assignment(), profile()
            if not a then return end
            for key, name in pairs(p.assigned) do
                if name == a.name then p.assigned[key] = nil end
            end
            table.remove(p.assignments, i)
            SRC:RefreshOptions(true)
            SRC:RefreshUI()
        end, { "Delete assignment" })
        slot.del:SetPoint("TOPLEFT", ax + 158, ASSIGN_Y + 1)
        f.assignments[i] = slot
    end
    f.addAssignment = self:Button(f, "+", 24, function()
        local list = profile().assignments
        if #list < MAX_ASSIGNMENTS then
            list[#list + 1] = { name = "Assignment " .. (#list + 1), role = "TANK" }
            SRC:RefreshOptions(true)
        end
    end, { "Add raid assignment" })

    -- Buff groups
    label(f, "Buff groups", 16, GROUP_TOP + 32, "GameFontNormal")
    label(f, "Name", 20, GROUP_TOP + 14)
    label(f, "Buffs (spell IDs or names, comma separated; a/b = either one counts once; Name* = prefix)", 120, GROUP_TOP + 14)
    f.groups = {}
    for i = 1, MAX_GROUPS do
        local y = GROUP_TOP - (i - 1) * LINE_H
        local row = {}
        row.name = editBox(f, 90, function(_, text)
            local g = profile().groups[i]
            if g and text ~= "" then g.name = text end
        end, function() return { "Group name", "Used in rule conditions, e.g. '3 WB'." } end)
        row.name:SetPoint("TOPLEFT", 22, y)
        row.spells = editBox(f, 476, function(_, text)
            local g = profile().groups[i]
            if g then g.spells = text end
        end, spellsTooltip)
        row.spells:SetPoint("TOPLEFT", 122, y)
        row.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.status:SetPoint("TOPLEFT", 606, y - 4)
        row.status:SetWidth(82)
        row.status:SetJustifyH("LEFT")
        row.status:SetWordWrap(false)
        row.del = self:Button(f, "X", 24, function()
            table.remove(profile().groups, i)
            SRC:RefreshOptions(true)
            SRC:RefreshUI()
        end, { "Delete group" })
        row.del:SetPoint("TOPLEFT", 690, y + 1)
        f.groups[i] = row
    end
    f.addGroup = self:Button(f, "+ Group", 80, function()
        local groups = profile().groups
        if #groups < MAX_GROUPS then
            groups[#groups + 1] = { name = "Group" .. (#groups + 1), spells = "" }
            SRC:RefreshOptions(true)
        end
    end)

    -- Rules
    label(f, "Rules", 16, RULE_TOP + 32, "GameFontNormal")
    label(f, "Each rule whose condition is met adds its bonus; rules stack. A missed 'Req' rule means 0 SR.",
        64, RULE_TOP + 31, "GameFontHighlightSmall")
    label(f, "On", 16, RULE_TOP + 14)
    label(f, "Name", 48, RULE_TOP + 14)
    label(f, "Condition (e.g. 3 WB  /  Flask  /  6 WB or 3 WB + Flask)", 162, RULE_TOP + 14)
    label(f, "Bonus", 468, RULE_TOP + 14)
    label(f, "Req", 508, RULE_TOP + 14)
    for r, role in ipairs(SRC.ROLES) do
        label(f, SRC.ROLE_SHORT[role], 541 + (r - 1) * 24, RULE_TOP + 14)
    end
    f.rules = {}
    for i = 1, MAX_RULES do
        local y = RULE_TOP - (i - 1) * LINE_H
        local row = {}
        local function rule() return profile().rules[i] end
        row.enabled = self:CheckBox(f, nil, function(checked)
            if rule() then rule().enabled = checked end
            SRC:RefreshUI()
        end, { "Enabled" })
        row.enabled:SetPoint("TOPLEFT", 14, y + 1)
        row.name = editBox(f, 104, function(_, text)
            if rule() and text ~= "" then rule().name = text end
        end)
        row.name:SetPoint("TOPLEFT", 48, y)
        row.condition = editBox(f, 296, function(_, text)
            if rule() then rule().condition = text end
        end, conditionTooltip)
        row.condition.index = i
        row.condition:SetPoint("TOPLEFT", 162, y)
        row.bonus = editBox(f, 34, function(_, text)
            local n = tonumber(text)
            if rule() and n then rule().bonus = n end
        end, function() return { "Bonus", "SRs added when the condition is met (negative = penalty)." } end)
        row.bonus:SetPoint("TOPLEFT", 470, y)
        row.required = self:CheckBox(f, nil, function(checked)
            if rule() then rule().required = checked or nil end
            SRC:RefreshOptions()
            SRC:RefreshUI()
        end, { "Required", "If the condition is not met the player gets 0 SR (the bonus is ignored)." })
        row.required:SetPoint("TOPLEFT", 508, y + 1)
        row.roles = {}
        for r, role in ipairs(SRC.ROLES) do
            local cb = self:CheckBox(f, nil, function(checked)
                if rule() then
                    rule().roles = rule().roles or { DPS = true, TANK = true, HEALER = true }
                    rule().roles[role] = checked or nil
                end
                SRC:RefreshUI()
            end, { "Applies to " .. SRC.ROLE_LABEL[role] })
            cb:SetPoint("TOPLEFT", 534 + (r - 1) * 24, y + 1)
            row.roles[role] = cb
        end
        row.err = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.err:SetPoint("TOPLEFT", 610, y - 4)
        row.err:SetWidth(76)
        row.err:SetJustifyH("LEFT")
        row.err:SetWordWrap(false)
        row.del = self:Button(f, "X", 24, function()
            table.remove(profile().rules, i)
            SRC:RefreshOptions(true)
            SRC:RefreshUI()
        end, { "Delete rule" })
        row.del:SetPoint("TOPLEFT", 690, y + 1)
        f.rules[i] = row
    end
    f.addRule = self:Button(f, "+ Rule", 80, function()
        local rules = profile().rules
        if #rules < MAX_RULES then
            local firstGroup = profile().groups[1]
            rules[#rules + 1] = {
                name = "Rule " .. (#rules + 1), condition = firstGroup and firstGroup.name or "",
                bonus = 1, enabled = true, roles = { DPS = true, TANK = true, HEALER = true },
            }
            SRC:RefreshOptions(true)
            SRC:RefreshUI()
        end
    end)

    -- General options
    local sticky = self:CheckBox(f, "Remember buffs seen earlier in the raid", function(checked)
        SRC.db.options.sticky = checked
        SRC:RefreshUI()
    end, { "Sticky scans", "A buff seen in any scan of this raid keeps counting (world buffs are lost on death).",
        "Turn off to judge only by the latest scan." })
    sticky:SetPoint("BOTTOMLEFT", 14, 38)
    f.sticky = sticky
    local ready = self:CheckBox(f, "Scan automatically on ready check", function(checked)
        SRC.db.options.scanOnReadyCheck = checked
    end)
    ready:SetPoint("BOTTOMLEFT", 14, 14)
    f.ready = ready

    self:Button(f, "Reset profile to defaults", 170, function()
        -- Presets (BWL, AQ40, Test) go back to their preset; others to the basic rules.
        -- Who is assigned what is kept.
        local p = profile()
        local fresh = SRC:PresetProfile(p.name) or SRC:BaseProfile(p.name)
        p.base, p.groups, p.rules, p.assignments = fresh.base, fresh.groups, fresh.rules, fresh.assignments
        SRC:RefreshOptions(true)
        SRC:RefreshUI()
    end, { "Reset profile", "BWL, AQ40 and Test go back to their preset rules; other profiles to the basic rules." })
        :SetPoint("BOTTOMRIGHT", -12, 12)

    local problems = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    problems:SetPoint("BOTTOMLEFT", 16, 66)
    problems:SetPoint("RIGHT", -16, 0)
    problems:SetJustifyH("LEFT")
    f.problems = problems

    f:SetScript("OnShow", function() SRC:RefreshOptions(true) end)
    f:SetScript("OnHide", function()
        for _, eb in ipairs(editBoxes) do
            if eb:HasFocus() then eb:ClearFocus() end
        end
    end)
    self.options = f
end

------------------------------------------------------------
-- Refresh
------------------------------------------------------------
-- clearFocus: the rows now show different data (profile switch, rows added or
-- deleted), so stop editing first.
function SRC:RefreshOptions(clearFocus)
    local f = self.options
    if not f or not f:IsShown() then return end
    if clearFocus then
        for _, eb in ipairs(editBoxes) do
            if eb:HasFocus() then eb:ClearFocus() end
        end
    end
    local p = profile()
    local used = {}
    for _, r in ipairs(p.rules) do
        if r.enabled ~= false then
            for _, terms in ipairs((SRC.ParseCondition(r.condition))) do
                for _, t in ipairs(terms) do used[t.group] = true end
            end
        end
    end

    setText(f.profName, p.name)
    local used = {}
    for slug, name in pairs(self.db.instanceProfile) do
        if name == p.name then used[#used + 1] = SRC.INSTANCE_NAMES[slug] or slug end
    end
    table.sort(used)
    f.usedFor:SetText(#used > 0 and ("|cff9d9d9dauto-selected for: " .. table.concat(used, ", ") .. "|r") or "")

    for role, eb in pairs(f.base) do setText(eb, tostring(p.base[role] or 0)) end

    for i, slot in ipairs(f.assignments) do
        local a = p.assignments[i]
        for _, w in pairs(slot) do w:SetShown(a ~= nil) end
        if a then
            setText(slot.name, a.name)
            slot.role:SetText(SRC.ROLE_LABEL[a.role])
        end
    end
    f.addAssignment:SetPoint("TOPLEFT", 132 + #p.assignments * 186, ASSIGN_Y + 1)
    f.addAssignment:SetShown(#p.assignments < MAX_ASSIGNMENTS)

    for i, row in ipairs(f.groups) do
        local g = p.groups[i]
        for _, w in pairs(row) do if g then w:Show() else w:Hide() end end
        if g then
            setText(row.name, g.name)
            setText(row.spells, g.spells)
            local key = SRC.LowerUTF8(SRC.Trim(g.name or ""))
            local duplicate = false
            for j, other in ipairs(p.groups) do
                if j ~= i and SRC.LowerUTF8(SRC.Trim(other.name or "")) == key then duplicate = true end
            end
            if duplicate then
                row.status:SetText("|cffff4040duplicate name|r")
            elseif #SRC.ParseSpellList(g.spells) == 0 then
                row.status:SetText("|cffff4040empty|r")
            elseif not used[key] then
                row.status:SetText("|cff9d9d9dnot used|r")
            else
                row.status:SetText("")
            end
        end
    end
    f.addGroup:SetPoint("TOPLEFT", 20, GROUP_TOP - #p.groups * LINE_H)
    f.addGroup:SetShown(#p.groups < MAX_GROUPS)

    for i, row in ipairs(f.rules) do
        local r = p.rules[i]
        row.enabled:SetShown(r ~= nil)
        row.name:SetShown(r ~= nil)
        row.condition:SetShown(r ~= nil)
        row.bonus:SetShown(r ~= nil)
        row.required:SetShown(r ~= nil)
        row.err:SetShown(r ~= nil)
        row.del:SetShown(r ~= nil)
        for _, cb in pairs(row.roles) do cb:SetShown(r ~= nil) end
        if r then
            row.enabled:SetChecked(r.enabled ~= false)
            setText(row.name, r.name)
            setText(row.condition, r.condition)
            setText(row.bonus, tostring(r.bonus or 0))
            row.bonus:SetAlpha(r.required and 0.35 or 1)
            row.required:SetChecked(r.required and true or false)
            for role, cb in pairs(row.roles) do cb:SetChecked(not r.roles or r.roles[role]) end
            local err = SRC.ValidateRule(p, r)
            local empty = not err and SRC.RuleEmptyGroups(p, r)[1]
            row.err:SetText((err and "|cffff4040invalid (hover)|r") or (empty and "|cffffb000empty group|r") or "")
        end
    end
    f.addRule:SetPoint("TOPLEFT", 20, RULE_TOP - #p.rules * LINE_H)
    f.addRule:SetShown(#p.rules < MAX_RULES)

    f.sticky:SetChecked(self.db.options.sticky)
    f.ready:SetChecked(self.db.options.scanOnReadyCheck)

    local problems = self:ProfileProblems(p)
    f.problems:SetText(#problems > 0 and ("|cffff4040Problems: " .. table.concat(problems, "; ") .. "|r") or "")
end

function SRC:ToggleOptions()
    self:BuildOptions()
    if self.options:IsShown() then self.options:Hide() else self.options:Show() end
end
