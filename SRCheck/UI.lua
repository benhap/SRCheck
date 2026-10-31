-- UI: main verification window, import dialog and copyable-text dialog.

local _, SRC = ...

local ROW_H = 18
local ICON_OK      = "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t"
local ICON_FAIL    = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:12|t"
local ICON_UNKNOWN = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:12|t"

local COLS = {
    { key = "check",   title = "",           x = 0,   w = 20 },
    { key = "name",    title = "Name",       x = 22,  w = 112 },
    { key = "role",    title = "Role",       x = 136, w = 80 },
    { key = "rules",   title = "Compliance", x = 220, w = 234 },
    { key = "adj",     title = "Adj",        x = 456, w = 34 },
    { key = "sr",      title = "SR",         x = 494, w = 28 },
    { key = "allowed", title = "Allowed",    x = 526, w = 52 },
    { key = "status",  title = "Status",     x = 582, w = 124 },
}
local COL = {}
for _, c in ipairs(COLS) do COL[c.key] = c end

local PROBLEMS = { OVER = true, UNKNOWN = true, ABSENT = true, SKIPPED = true }

local RULE_CHECK_TIP = { "Check now",
    "Untick a buff group to check it later, e.g. WB before the unboon while the flask is checked now.",
    "A group on hold can't cause deductions (a missing flask still fails '6 WB + Flask'); players whose "
    .. "result depends on it show as Pending. This raid only." }

local INCLUDE_TIP = { "Include in the check",
    "Untick players who will unboon (or buff) later, e.g. because of their role: they are not deducted "
    .. "and keep their SRs in the corrected string.",
    "Tick them again and scan once they have their buffs. This raid only." }

------------------------------------------------------------
-- Widget helpers (shared with Options.lua)
------------------------------------------------------------
function SRC:CreateWindow(name, width, height, titleText)
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(width, height)
    f:SetBackdrop({
        bgFile   = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.92)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetClampedToScreen(true)
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        SRC.db.pos[name] = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    local pos = SRC.db.pos[name]
    if pos then
        f:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    else
        f:SetPoint("CENTER")
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -10)
    title:SetText(titleText)
    f.title = title

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 1, 1)

    tinsert(UISpecialFrames, name) -- Escape closes it
    f:Hide()
    return f
end

local function showTooltip(owner, lines)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    for i, line in ipairs(lines) do
        if i == 1 then
            GameTooltip:SetText(line)
        else
            GameTooltip:AddLine(line, 1, 1, 1, true)
        end
    end
    GameTooltip:Show()
end
SRC.ShowTooltip = showTooltip

function SRC:Button(parent, text, width, onClick, tooltip)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    if tooltip then
        b:SetScript("OnEnter", function(self) showTooltip(self, tooltip) end)
        b:SetScript("OnLeave", GameTooltip_Hide)
    end
    return b
end

function SRC:CheckBox(parent, label, onClick, tooltip)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
    if label then
        local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
        fs:SetText(label)
        cb.label = fs
    end
    if tooltip then
        cb:SetScript("OnEnter", function(self) showTooltip(self, tooltip) end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
    end
    return cb
end

-- A multi-line edit box inside a scroll frame.
local function createTextArea(parent, left, top, right, bottom)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", left, top)
    scroll:SetPoint("BOTTOMRIGHT", right, bottom)

    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bg:SetPoint("TOPLEFT", scroll, -4, 4)
    bg:SetPoint("BOTTOMRIGHT", scroll, 4, -4)
    bg:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    bg:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    bg:SetFrameLevel(scroll:GetFrameLevel() - 1)

    local eb = CreateFrame("EditBox", nil, scroll)
    eb:SetMultiLine(true)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(0) -- softres strings for 40 players are several KB
    eb:SetFontObject("ChatFontNormal")
    eb:SetWidth(scroll:GetWidth() > 0 and scroll:GetWidth() or 460)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(eb)
    scroll:SetScript("OnSizeChanged", function(self, w) eb:SetWidth(w) end)
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() eb:SetFocus() end)
    return eb, scroll
end

------------------------------------------------------------
-- Main window
------------------------------------------------------------
local function cellText(row, key)
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", row, "LEFT", COL[key].x, 0)
    fs:SetWidth(COL[key].w)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

local function cellButton(row, key, onClick, tooltip)
    local b = CreateFrame("Button", nil, row)
    b:SetPoint("LEFT", row, "LEFT", COL[key].x - 2, 0)
    b:SetSize(COL[key].w, ROW_H)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", 2, 0)
    fs:SetWidth(COL[key].w - 2)
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    b.text = fs
    b:SetScript("OnClick", function(self, button) onClick(self:GetParent().data, button, self) end)
    b:SetScript("OnEnter", function(self) showTooltip(self, tooltip(self:GetParent().data)) end)
    b:SetScript("OnLeave", GameTooltip_Hide)
    return b
end

------------------------------------------------------------
-- Small popup menu (used for the Role cell)
------------------------------------------------------------
local MENU_LINE = 16
local CHECK = "|TInterface\\Buttons\\UI-CheckBox-Check:14|t"
local menu

-- entries: { { text, title = bool, checked = bool, onClick = fn }, ... }
function SRC:ShowMenu(anchor, entries)
    if not menu then
        menu = CreateFrame("Frame", "SRCheckMenu", UIParent, "BackdropTemplate")
        menu:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        menu:SetBackdropColor(0, 0, 0, 0.95)
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu:SetClampedToScreen(true)
        menu:EnableMouse(true)
        menu.buttons = {}
        -- Close once the mouse has been away from the menu for a moment.
        menu:SetScript("OnUpdate", function(self, elapsed)
            if self:IsMouseOver() or (self.anchor and self.anchor:IsMouseOver()) then
                self.idle = 0
            else
                self.idle = (self.idle or 0) + elapsed
                if self.idle > 1 then self:Hide() end
            end
        end)
        tinsert(UISpecialFrames, "SRCheckMenu")
        self.menu = menu
    end
    if menu:IsShown() and menu.anchor == anchor then
        menu:Hide()
        return
    end
    menu.anchor, menu.idle = anchor, 0

    local width = 120
    for i, e in ipairs(entries) do
        local b = menu.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, menu)
            b:SetHeight(MENU_LINE)
            b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * MENU_LINE)
            b:SetPoint("RIGHT", -6, 0)
            b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.text:SetPoint("LEFT", 4, 0)
            b.text:SetJustifyH("LEFT")
            b:SetScript("OnClick", function(self)
                menu:Hide()
                if self.onClick then self.onClick() end
            end)
            menu.buttons[i] = b
        end
        if e.title then
            b.text:SetText("|cffffd100" .. e.text .. "|r")
        else
            b.text:SetText((e.checked and (CHECK .. " ") or "      ") .. e.text)
        end
        b.onClick = e.onClick
        b:SetEnabled(not e.title)
        b:Show()
        width = math.max(width, b.text:GetStringWidth() + 20)
    end
    for i = #entries + 1, #menu.buttons do menu.buttons[i]:Hide() end

    menu:SetSize(width + 12, #entries * MENU_LINE + 12)
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, 0)
    menu:Show()
end

function SRC:HideMenu()
    if menu then menu:Hide() end
end

local function onRoleClick(data, _, anchor)
    local key = data.key
    local profile = SRC:GetProfile()
    local autoRole, autoSource = SRC:AutoRole(key, data.player, data.member)
    local manual = SRC.db.roles[key]
    local entries = {
        { text = SRC.ColorName(data.name, data.class), title = true },
        {
            text = ("Auto: %s |cff9d9d9d(%s)|r"):format(SRC.ROLE_LABEL[autoRole], autoSource),
            checked = not manual and not data.assignment,
            onClick = function()
                SRC:SetAssignment(key, nil)
                SRC:SetRole(key, nil)
            end,
        },
    }
    for _, role in ipairs(SRC.ROLES) do
        entries[#entries + 1] = {
            text = SRC.ROLE_LABEL[role] .. " |cff9d9d9d(all raids)|r",
            checked = manual == role and not data.assignment,
            onClick = function()
                SRC:SetAssignment(key, nil)
                SRC:SetRole(key, role)
            end,
        }
    end
    if #profile.assignments > 0 then
        entries[#entries + 1] = { text = profile.name .. " assignments", title = true }
        for _, a in ipairs(profile.assignments) do
            entries[#entries + 1] = {
                text = ("%s |cff9d9d9d(as %s)|r"):format(a.name, SRC.ROLE_LABEL[a.role]),
                checked = data.assignment == a.name,
                onClick = function() SRC:SetAssignment(key, a.name) end,
            }
        end
    end
    SRC:ShowMenu(anchor, entries)
end

local function roleTooltip(data)
    return {
        "Role: " .. data.roleLabel,
        "Source: " .. data.roleSource,
        "|cff9d9d9dClick to change. DPS/Tank/Healer are kept for this character in all raids; "
            .. "assignments (Pull Hunter, ...) only in the current profile.|r",
    }
end

local function onAdjClick(data, button)
    local n = data.adj
    if IsShiftKeyDown() then
        n = 0
    elseif button == "RightButton" then
        n = n - 1
    else
        n = n + 1
    end
    SRC:SetAdjustment(data.key, n)
end

local function adjTooltip(data)
    return {
        ("Manual adjustment: %+d"):format(data.adj),
        "Extra (or fewer) SRs for any other reason, for this raid only.",
        "|cff9d9d9dLeft-click +1, right-click -1, shift-click reset.|r",
    }
end

-- "OK World Buffs  FAIL Flask" style compliance summary.
local function complianceText(data)
    local parts = {}
    for _, r in ipairs(data.rules) do
        local icon = (r.ok == true and ICON_OK) or (r.ok == false and ICON_FAIL) or ICON_UNKNOWN
        local label = r.rule.name
        local o = r.options[1]
        if #r.options == 1 and #o.terms == 1 and o.terms[1].need > 1 then
            local t = o.terms[1]
            label = ("%s %s/%d"):format(t.label, t.count or "?", t.need)
        end
        if r.pending then label = "|cff8f8f8f" .. label .. "|r" end -- on hold: shown, not counted
        parts[#parts + 1] = icon .. label
    end
    local text = table.concat(parts, "  ")
    if data.member and data.state ~= "ok" then
        text = text .. "  |cff9d9d9d(" .. SRC.StateText(data) .. ")|r"
    elseif not data.member then
        text = "|cff9d9d9dnot in group|r"
    end
    return text
end

local function auraLabel(hit)
    if type(hit) == "number" then return SRC.SpellName(hit) or ("spell " .. hit) end
    return hit
end

local function rowTooltip(data)
    local lines = { SRC.ColorName(data.name, data.class) }
    if data.player and data.member and data.player.key ~= data.member.key then
        lines[#lines + 1] = ("softres name: %s (%s match)"):format(data.player.name, data.linkKind or "?")
    end
    lines[#lines + 1] = ("Role: %s |cff9d9d9d(%s)|r"):format(data.roleLabel, data.roleSource)
    if data.excluded then
        local would = SRC.STATUS[data.wouldStatus].label
        if data.wouldStatus == "OVER" then
            would = ("%s -%d (%s)"):format(would, data.wouldDeduct, SRC.MissingText(data))
        end
        lines[#lines + 1] = "|cffffb000Excluded from the check|r - would currently be: " .. would
    end

    lines[#lines + 1] = " "
    lines[#lines + 1] = ("Allowed: %s SR"):format(SRC.AllowedText(data))
    lines[#lines + 1] = ("   base %d (%s)"):format(data.base, data.roleLabel)
    for _, r in ipairs(data.rules) do
        local icon = (r.ok == true and ICON_OK) or (r.ok == false and ICON_FAIL) or ICON_UNKNOWN
        local detail = r.ok == false and (" |cff9d9d9d" .. SRC.RuleShortfall(r) .. "|r") or ""
        if r.pending then
            local now = (r.met == true and "met") or (r.met == false and SRC.RuleShortfall(r, true)) or "not scanned"
            local waiting = {}
            for label in pairs(r.waiting) do waiting[#waiting + 1] = label end
            detail = (" |cffd8c070waiting for %s|r |cff9d9d9d(now: %s)|r"):format(table.concat(waiting, ", "), now)
        end
        local effect = r.rule.required and "required (else 0 SR):" or ("%+d"):format(r.rule.bonus or 0)
        lines[#lines + 1] = ("   %s %s %s (%s)%s"):format(icon, effect, r.rule.name,
            SRC.Trim(r.rule.condition), detail)
    end
    if data.adj ~= 0 then lines[#lines + 1] = ("   manual %+d"):format(data.adj) end

    if #data.groups > 0 then
        lines[#lines + 1] = " "
        for _, g in ipairs(data.groups) do
            local names = {}
            for _, hit in ipairs(g.matched) do names[#names + 1] = auraLabel(hit) end
            lines[#lines + 1] = ("%s: %d %s"):format(g.group.name, g.count,
                #names > 0 and ("|cff9d9d9d(" .. table.concat(names, ", ") .. ")|r") or "")
        end
    end

    if data.player then
        lines[#lines + 1] = " "
        lines[#lines + 1] = ("Soft-reserves (%d):"):format(data.reserved)
        local dropFrom = data.deduct and (data.reserved - data.deduct + 1) or math.huge
        for i, item in ipairs(data.player.items) do
            local name = SRC.ItemName(item.id)
            if i >= dropFrom then
                lines[#lines + 1] = ("   %d. |cffff4040%s - dropped|r"):format(i, name)
            else
                lines[#lines + 1] = ("   %d. %s"):format(i, name)
            end
        end
    end

    lines[#lines + 1] = " "
    if data.scannedAt then
        lines[#lines + 1] = ("|cff9d9d9dLast scan %s: %s|r"):format(date("%H:%M", data.scannedAt), SRC.StateText(data))
    else
        lines[#lines + 1] = "|cff9d9d9d" .. SRC.StateText(data) .. "|r"
    end
    return lines
end

local function createRow(parent, i)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:SetPoint("RIGHT", parent, "RIGHT")
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    if i % 2 == 0 then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.04)
    end

    local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    check:SetSize(20, 20)
    check:SetPoint("LEFT", row, "LEFT", COL.check.x, 0)
    check:SetScript("OnClick", function(self)
        SRC:SetExcluded(row.data.key, not self:GetChecked())
    end)
    check:SetScript("OnEnter", function(self) showTooltip(self, INCLUDE_TIP) end)
    check:SetScript("OnLeave", GameTooltip_Hide)
    row.check = check

    row.name = cellText(row, "name")
    row.role = cellButton(row, "role", onRoleClick, roleTooltip)
    row.rules = cellText(row, "rules")
    row.adj = cellButton(row, "adj", onAdjClick, adjTooltip)
    row.sr = cellText(row, "sr")
    row.allowed = cellText(row, "allowed")
    row.status = cellText(row, "status")

    row:SetScript("OnEnter", function(self) showTooltip(self, rowTooltip(self.data)) end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    return row
end

local function fillRow(row, data)
    row.data = data
    local name = SRC.ColorName(data.name, data.class)
    if data.linkKind == "fuzzy" or data.linkKind == "manual" then name = name .. " |cffffb000~|r" end
    row.name:SetText(name)
    row.role.text:SetText(("|c%s%s%s|r"):format(SRC.ROLE_COLOR[data.role], data.roleLabel,
        (data.manualRole and not data.assignment) and "*" or ""))
    row.rules:SetText(complianceText(data))
    row.adj.text:SetText(data.adj ~= 0 and ("%+d"):format(data.adj) or "|cff5f5f5f-|r")
    row.sr:SetText(tostring(data.reserved))
    row.allowed:SetText(SRC.AllowedText(data))

    -- Only players with soft-reserves can be left out of the check.
    row.check:SetShown(data.player ~= nil)
    row.check:SetChecked(not data.excluded)
    local alpha = data.excluded and 0.45 or 1
    for _, cell in ipairs({ row.name, row.role, row.rules, row.adj, row.sr, row.allowed }) do
        cell:SetAlpha(alpha)
    end

    local st = SRC.STATUS[data.status]
    local label = st.label
    if data.status == "OVER" then
        label = ("%s -%d"):format(label, data.deduct)
    elseif data.status == "UNDER" then
        label = ("%s +%d"):format(label, data.extra)
    elseif data.status == "SKIPPED" and data.wouldStatus == "OVER" then
        label = ("%s (-%d)"):format(label, data.wouldDeduct)
    end
    row.status:SetText("|c" .. st.color .. label .. "|r")
    row:Show()
end

function SRC:BuildMain()
    if self.main then return end
    local f = self:CreateWindow("SRCheckMainFrame", 760, 500, "SRCheck - soft-reserve verification")

    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOP", 0, -28)
    f.subtitle = subtitle

    -- Toolbar
    local import = self:Button(f, "Import", 70, function() SRC:ShowImport() end,
        { "Import", "Paste the softres.it Gargul export (or CSV export)." })
    import:SetPoint("TOPLEFT", 12, -44)
    local fromGargul = self:Button(f, "From Gargul", 90, function() SRC:ImportFromGargul() end,
        { "From Gargul", "Load the softres.it data you already imported into Gargul (/gl sr)." })
    fromGargul:SetPoint("LEFT", import, "RIGHT", 4, 0)
    local scan = self:Button(f, "Scan buffs", 90, function() SRC:Scan() end,
        { "Scan buffs", "Check every raid member's buffs now.",
          "Players must be within ~100 yards. Also runs automatically on ready checks." })
    scan:SetPoint("LEFT", fromGargul, "RIGHT", 4, 0)

    local profLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profLabel:SetPoint("LEFT", scan, "RIGHT", 16, 0)
    profLabel:SetText("Profile:")
    local prev = self:Button(f, "<", 22, function() SRC:CycleProfile(-1) end)
    prev:SetPoint("LEFT", profLabel, "RIGHT", 4, 0)
    local profName = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    profName:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    profName:SetWidth(110)
    profName:SetWordWrap(false)
    f.profName = profName
    local nextB = self:Button(f, ">", 22, function() SRC:CycleProfile(1) end)
    nextB:SetPoint("LEFT", profName, "RIGHT", 4, 0)
    local rules = self:Button(f, "Rules...", 64, function() SRC:ToggleOptions() end,
        { "Rules", "Edit base SRs, buff groups and rules of the profiles." })
    rules:SetPoint("LEFT", nextB, "RIGHT", 6, 0)

    local problems = self:CheckBox(f, "Problems only", function(checked)
        SRC.db.options.problemsOnly = checked
        SRC:RefreshUI()
    end, { "Problems only", "Show only deductions, unverified players, SRs of players not in the group "
        .. "and players excluded from the check." })
    problems:SetPoint("TOPRIGHT", -96, -44)
    f.problems = problems

    -- Rules to check now (one checkbox per rule, built in RefreshUI)
    local checkLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    checkLabel:SetPoint("TOPLEFT", 14, -76)
    checkLabel:SetText("Check now:")
    local checkHover = CreateFrame("Frame", nil, f)
    checkHover:SetAllPoints(checkLabel)
    checkHover:SetScript("OnEnter", function(self) showTooltip(self, RULE_CHECK_TIP) end)
    checkHover:SetScript("OnLeave", GameTooltip_Hide)
    f.checkLabel = checkLabel
    f.ruleChecks = {}

    -- Column headers; the first one includes/excludes everyone.
    local all = self:CheckBox(f, nil, function(checked) SRC:SetAllExcluded(not checked) end,
        { "Include everyone", "Untick to leave everyone out of the check, tick to include everyone again." })
    all:SetSize(20, 20)
    all:SetPoint("TOPLEFT", 12 + COL.check.x, -92)
    f.includeAll = all
    for _, c in ipairs(COLS) do
        local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", 12 + c.x, -96)
        h:SetText(c.title)
    end

    -- Result list
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -112)
    scroll:SetPoint("BOTTOMRIGHT", -32, 62)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(710, 1)
    scroll:SetScrollChild(content)
    f.content = content
    f.rows = {}

    local empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("CENTER", scroll, "CENTER")
    empty:SetWidth(520)
    empty:SetText("No soft-reserves loaded.\n\nClick |cffffffffImport|r and paste the softres.it Gargul export,\n"
        .. "or |cffffffffFrom Gargul|r if you already imported it there.")
    f.empty = empty

    local summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("BOTTOMLEFT", 14, 42)
    summary:SetPoint("RIGHT", -14, 0)
    summary:SetJustifyH("LEFT")
    f.summary = summary

    -- Actions
    local announce = self:Button(f, "Announce", 90, function() SRC:Announce() end,
        { "Announce", "Post SR deductions and unverified players to raid chat." })
    announce:SetPoint("BOTTOMLEFT", 10, 10)
    local whisper = self:Button(f, "Whisper", 80, function() SRC:WhisperDeductions() end,
        { "Whisper", "Tell each over-reserved player why and which of their SRs are removed." })
    whisper:SetPoint("LEFT", announce, "RIGHT", 4, 0)
    local report = self:Button(f, "Report", 80, function() SRC:ShowReport() end,
        { "Report", "Full plain-text report to copy (e.g. to Discord)." })
    report:SetPoint("LEFT", whisper, "RIGHT", 4, 0)

    local send = self:Button(f, "Send to Gargul", 120, function() SRC:SendToGargul() end,
        { "Send to Gargul", "Import the corrected soft-reserves straight into Gargul",
          "(over-reserved players lose their last-placed SRs). Gargul then shares it with the raid as usual." })
    send:SetPoint("BOTTOMRIGHT", -10, 10)
    f.send = send
    local corrected = self:Button(f, "Corrected string", 130, function() SRC:ShowCorrected() end,
        { "Corrected string", "Gargul string with each over-reserved player's last-placed SRs removed.",
          "Paste it into Gargul (/gl sr) instead of the original." })
    corrected:SetPoint("RIGHT", send, "LEFT", -4, 0)

    f:SetScript("OnShow", function() SRC:RefreshUI() end)
    f:SetScript("OnHide", function() SRC:HideMenu() end)
    self.main = f
end

function SRC:CycleProfile(delta)
    local profiles = self.db.profiles
    local cur = 1
    for i, p in ipairs(profiles) do
        if p.name == self.db.activeProfile then cur = i end
    end
    local nextIndex = (cur - 1 + delta) % #profiles + 1
    self:SetActiveProfile(profiles[nextIndex].name, true)
    if self.options and self.options:IsShown() then self:RefreshOptions() end
end

function SRC:RefreshUI()
    local f = self.main
    if not f or not f:IsShown() then return end

    local s = self.db.session
    f.profName:SetText(self:GetProfile().name)
    f.problems:SetChecked(self.db.options.problemsOnly)
    f.send:SetEnabled(_G.Gargul ~= nil and self.data ~= nil)

    if not self.data or not s then
        f.subtitle:SetText("")
        f.summary:SetText("")
        f.empty:Show()
        for _, row in ipairs(f.rows) do row:Hide() end
        return
    end
    f.empty:Hide()

    local parts = { self:RaidTitle(), ("%d softres players"):format(#self.data.players) }
    if s.importedAt then parts[#parts + 1] = "imported " .. date("%H:%M", s.importedAt) end
    parts[#parts + 1] = s.lastScanAt and ("scanned " .. date("%H:%M", s.lastScanAt)) or "|cffffb000not scanned yet|r"
    if s.sentAt then parts[#parts + 1] = "|cff40ff40sent to Gargul " .. date("%H:%M", s.sentAt) .. "|r" end
    f.subtitle:SetText(table.concat(parts, "  -  "))

    local rows, summary = self:Evaluate()
    local shown = 0
    for _, data in ipairs(rows) do
        if not self.db.options.problemsOnly or PROBLEMS[data.status] then
            shown = shown + 1
            f.rows[shown] = f.rows[shown] or createRow(f.content, shown)
            fillRow(f.rows[shown], data)
        end
    end
    for i = shown + 1, #f.rows do f.rows[i]:Hide() end
    f.content:SetHeight(math.max(1, shown * ROW_H))

    f.includeAll:SetChecked(summary.SKIPPED == 0)
    self:RefreshRuleChecks()

    local st = SRC.STATUS
    local parts = { ("|c%s%d to deduct (%d SR)|r"):format(st.OVER.color, summary.OVER, summary.deduct) }
    for _, item in ipairs({ { "UNKNOWN", "not verified" }, { "PENDING", "pending" }, { "ABSENT", "not in group" },
        { "SKIPPED", "not checked" }, { "UNDER", "can add" }, { "NOSR", "without SR" }, { "OK", "OK" } }) do
        local n = summary[item[1]]
        if n > 0 then parts[#parts + 1] = ("|c%s%d %s|r"):format(st[item[1]].color, n, item[2]) end
    end
    f.summary:SetText(table.concat(parts, "   "))
end

-- One checkbox per buff group of the active profile, laid out in a row.
function SRC:RefreshRuleChecks()
    local f = self.main
    local x = 16 + f.checkLabel:GetStringWidth()
    local shown = 0
    for _, g in ipairs(self:GetProfile().groups) do
        shown = shown + 1
        local cb = f.ruleChecks[shown]
        if not cb then
            cb = self:CheckBox(f, "", function(checked) SRC:SetGroupChecked(cb.groupName, checked) end,
                RULE_CHECK_TIP)
            cb:SetSize(20, 20)
            f.ruleChecks[shown] = cb
        end
        cb.groupName = g.name
        cb.label:SetText(g.name)
        cb:SetChecked(self:IsGroupChecked(g.name))
        cb:ClearAllPoints()
        cb:SetPoint("TOPLEFT", 12 + x, -71)
        cb:Show()
        x = x + 24 + cb.label:GetStringWidth() + 12
    end
    for i = shown + 1, #f.ruleChecks do f.ruleChecks[i]:Hide() end
end

function SRC:ToggleUI()
    self:BuildMain()
    if self.main:IsShown() then self.main:Hide() else self.main:Show() end
end

------------------------------------------------------------
-- Import dialog
------------------------------------------------------------
function SRC:ShowImport()
    if not self.importFrame then
        local f = self:CreateWindow("SRCheckImportFrame", 520, 320, "Import soft-reserves")
        f:SetFrameStrata("DIALOG")

        local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT", 14, -30)
        hint:SetPoint("RIGHT", -14, 0)
        hint:SetJustifyH("LEFT")
        hint:SetText("Paste the softres.it |cffffffffGargul|r export (the same string you give Gargul).\n"
            .. "|cff9d9d9dTip: the softres.it CSV export also works and includes each player's spec, "
            .. "so tanks/healers are detected automatically.|r")

        local eb = createTextArea(f, 16, -64, -34, 44)
        f.edit = eb

        local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        status:SetPoint("BOTTOMLEFT", 14, 16)
        status:SetPoint("RIGHT", -200, 0)
        status:SetJustifyH("LEFT")
        f.status = status

        local importB = self:Button(f, "Import", 90, function()
            local ok, err = SRC:Import(eb:GetText(), true)
            if ok then
                f:Hide()
                SRC:BuildMain()
                SRC.main:Show()
            else
                status:SetText("|cffff4040" .. err .. "|r")
            end
        end)
        importB:SetPoint("BOTTOMRIGHT", -12, 10)
        local clear = self:Button(f, "Clear", 70, function()
            eb:SetText("")
            status:SetText("")
            eb:SetFocus()
        end)
        clear:SetPoint("RIGHT", importB, "LEFT", -4, 0)

        self.importFrame = f
    end
    local f = self.importFrame
    f.status:SetText("")
    f.edit:SetText("")
    f:Show()
    f.edit:SetFocus()
end

------------------------------------------------------------
-- Copyable text dialog (report, corrected string)
------------------------------------------------------------
function SRC:ShowText(title, text, hint)
    if not self.textFrame then
        local f = self:CreateWindow("SRCheckTextFrame", 600, 400, "")
        f:SetFrameStrata("DIALOG")

        local eb = createTextArea(f, 16, -34, -34, 44)
        -- Read-only: undo any typing, keep it easy to copy.
        eb:SetScript("OnTextChanged", function(self, userInput)
            if userInput then
                self:SetText(f.fixedText)
                self:HighlightText()
            end
        end)
        eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        f.edit = eb

        local hintFs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        hintFs:SetPoint("BOTTOMLEFT", 14, 16)
        hintFs:SetPoint("RIGHT", -14, 0)
        hintFs:SetJustifyH("LEFT")
        f.hint = hintFs

        self.textFrame = f
    end
    local f = self.textFrame
    f.title:SetText(title)
    f.fixedText = text
    f.edit:SetText(text)
    f.hint:SetText(hint or "")
    f:Show()
    f.edit:SetFocus()
    f.edit:HighlightText()
end
