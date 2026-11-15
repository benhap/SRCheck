-- SRCheck
-- Verifies that each raider's number of soft-reserves (softres.it, imported
-- via its Gargul export string) matches what the guild's SR rules allow:
--
--   allowed = base SRs for the player's role (DPS / Tank / Healer)
--           + bonus of every rule the player complies with (3 world buffs,
--             flask, ...), checked by scanning raid members' buffs
--           + manual adjustment
--
-- Over-reserved players can be announced / whispered, and a corrected Gargul
-- string (their last-placed SRs dropped) can be exported or sent to Gargul.
--
-- Files: Codec (base64/JSON/CSV), Data (defaults), Core (this), Import
-- (softres parsing + corrected export), Verify (scan + evaluation + reports),
-- UI (main window + dialogs), Options (rule profiles).

local ADDON, SRC = ...

SRC.LABEL = "|cff33ccffSRCheck|r"
SRC.VERSION = "1.3.2"

-- A session (scans, adjustments) is kept when the same softres raid is
-- re-imported within this many seconds; otherwise a new one is started.
SRC.SESSION_MAX_AGE = 12 * 3600

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
function SRC:Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(SRC.LABEL .. ": " .. msg)
end

function SRC.Trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

------------------------------------------------------------
-- Names. softres.it names are typed by players, so match leniently:
-- case-insensitive (incl. Latin-1 capitals), accent-folded, and finally a
-- small edit distance (see Verify.lua).
------------------------------------------------------------
local byte, char = string.byte, string.char

local function lowerUTF8(s)
    s = s:gsub("\195([\128-\158])", function(c)
        local b = byte(c)
        if b ~= 0x97 then return "\195" .. char(b + 32) end -- skip U+00D7 multiplication sign
    end)
    return s:lower()
end
SRC.LowerUTF8 = lowerUTF8

-- "Name-Realm" -> "name"
function SRC.NameKey(name)
    name = SRC.Trim(name):match("^[^%-]*") or ""
    return lowerUTF8(name)
end

local FOLD = { ["\195\159"] = "ss" }
local function fold(from, to, ascii)
    for b = from, to do FOLD["\195" .. char(b)] = ascii end
end
fold(0xA0, 0xA5, "a"); fold(0xA6, 0xA6, "ae"); fold(0xA7, 0xA7, "c"); fold(0xA8, 0xAB, "e")
fold(0xAC, 0xAF, "i"); fold(0xB0, 0xB0, "d"); fold(0xB1, 0xB1, "n"); fold(0xB2, 0xB6, "o")
fold(0xB8, 0xB8, "o"); fold(0xB9, 0xBC, "u"); fold(0xBD, 0xBD, "y"); fold(0xBE, 0xBE, "th")
fold(0xBF, 0xBF, "y")

-- Accent-folds a NameKey: "aglaée" -> "aglaee"
function SRC.FoldName(key)
    return (key:gsub("\195[\128-\191]", FOLD))
end

-- Byte-wise Levenshtein distance, giving up (returns limit + 1) past limit.
function SRC.Levenshtein(a, b, limit)
    local la, lb = #a, #b
    if math.abs(la - lb) > limit then return limit + 1 end
    local prev, cur = {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur[0] = i
        local rowMin = i
        local ca = byte(a, i)
        for j = 1, lb do
            local cost = (ca == byte(b, j)) and 0 or 1
            local v = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            cur[j] = v
            if v < rowMin then rowMin = v end
        end
        if rowMin > limit then return limit + 1 end
        prev, cur = cur, prev
    end
    return prev[lb]
end

-- "death knight" / "Hunter" -> "DEATHKNIGHT" / "HUNTER"
function SRC.NormalizeClass(class)
    if type(class) ~= "string" or class == "" then return nil end
    return (class:upper():gsub("[%s_]", ""))
end

function SRC.ClassColor(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return "ffffffff" end
    return ("ff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
end

function SRC.ColorName(name, class)
    return "|c" .. SRC.ClassColor(class) .. name .. "|r"
end

------------------------------------------------------------
-- API shims (Era 1.15.x moved to the modern C_* namespaces; keep fallbacks)
------------------------------------------------------------
local GetSpellName = (C_Spell and C_Spell.GetSpellName) or function(id)
    return (GetSpellInfo(id))
end

function SRC.SpellName(id)
    return id and GetSpellName(id)
end

function SRC.ForEachBuff(unit, fn)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 64 do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
            if not aura then break end
            fn(aura.spellId, aura.name)
        end
    else
        for i = 1, 64 do
            local name, _, _, _, _, _, _, _, _, spellId = UnitAura(unit, i, "HELPFUL")
            if not name then break end
            fn(spellId, name)
        end
    end
end

local GetItemInfoShim = (C_Item and C_Item.GetItemInfo) or GetItemInfo

-- Returns an item link when cached, else a readable placeholder.
function SRC.ItemLink(id)
    local name, link = GetItemInfoShim(id)
    return link or ("item #" .. id), name
end

function SRC.ItemName(id)
    local name = GetItemInfoShim(id)
    return name or ("item #" .. id)
end

-- Asks the server for item data so names/links are ready for reports.
function SRC.RequestItem(id)
    if C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(id)
    else
        GetItemInfoShim(id)
    end
end

local SendChat = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage

function SRC.SendChat(msg, channel, target)
    SendChat(msg, channel, nil, target)
end

function SRC.GroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

------------------------------------------------------------
-- Saved variables
------------------------------------------------------------
local OPTION_DEFAULTS = {
    sticky = true,            -- remember buffs seen in earlier scans of this session
    scanOnReadyCheck = true,  -- rescan automatically when a ready check runs
}

function SRC:InitDB()
    SRCheckDB = SRCheckDB or {}
    local db = SRCheckDB
    db.profiles = db.profiles or {}
    db.instanceProfile = db.instanceProfile or {} -- softres instance slug -> profile name

    -- v7: Test became a real raid setup (3/4, +1 for "Flask or 3 WB"); replace
    -- whatever Test holds (editing bugs before 1.3.1 could leave it mixed up).
    -- Who is assigned what is kept.
    if (db.presetsVersion or 0) < 7 then
        for _, p in ipairs(db.profiles) do
            if p.name == "Test" then
                local fresh = self:PresetProfile("Test")
                p.base, p.groups, p.rules, p.assignments = fresh.base, fresh.groups, fresh.rules, fresh.assignments
            end
        end
    end

    -- v6: BWL is 3/4 + 1 for "3 WB + Flask or 6 WB" (was 2/3, +1 for 5 WB,
    -- +1 for a flask). Convert only the untouched preset.
    if (db.presetsVersion or 0) < 6 then
        for _, p in ipairs(db.profiles) do
            local r, b = p.rules, p.base
            if p.name == "BWL" and r and #r == 2 and r[1].condition == "5 WB" and r[1].bonus == 1
                and r[2].condition == "Flask" and r[2].bonus == 1
                and b and b.DPS == 2 and b.TANK == 3 and b.HEALER == 3 then
                local fresh = self:PresetProfile("BWL")
                p.base, p.rules = fresh.base, fresh.rules
            end
        end
    end

    -- v5: AQ40 is base + 1 for "6 WB + Flask" (earlier presets made it required,
    -- else 0 SR - as one rule, or split in two). Convert only untouched presets.
    if (db.presetsVersion or 0) < 5 then
        local function isOldAQ40(rules)
            if not rules then return false end
            if #rules == 1 then
                return rules[1].condition == "6 WB + Flask" and rules[1].required == true
            end
            return #rules == 2 and rules[1].condition == "6 WB" and rules[1].required == true
                and rules[2].condition == "Flask" and rules[2].required == true
        end
        for _, p in ipairs(db.profiles) do
            if p.name == "AQ40" and isOldAQ40(p.rules) then
                p.rules = self:PresetProfile("AQ40").rules
            end
        end
    end

    -- v3 fixed world buff IDs (Era uses 355363/355365/355366 for Ony, ZG, Rend)
    -- and added buff names; v4 counts any flask. Untouched default lists are
    -- replaced; edited ones just get the missing IDs.
    if (db.presetsVersion or 0) < 4 then
        local OLD_DEFAULTS = {
            ["22888, 24425, 16609, 15366, 22817, 22818, 22820, 23768/23736/23766/23738/23737/23735/23767/23769"]
                = SRC.WORLD_BUFF_SPELLS,
            ["17626, 17627, 17628, 17629"] = SRC.FLASK_SPELLS,
            ["17626/Flask of the Titans, 17627/Distilled Wisdom, 17628/Supreme Power, 17629/Chromatic Resistance"]
                = SRC.FLASK_SPELLS,
        }
        for _, p in ipairs(db.profiles) do
            for _, g in ipairs(p.groups or {}) do
                g.spells = OLD_DEFAULTS[g.spells] or SRC.AddSpellAliases(g.spells)
            end
        end
    end

    -- Add preset profiles this install hasn't seen yet (never overwrites).
    if (db.presetsVersion or 0) < SRC.PRESETS_VERSION then
        for _, name in ipairs(SRC.PRESET_ORDER) do
            local preset = self:PresetProfile(name)
            local exists = false
            for _, p in ipairs(db.profiles) do
                if p.name == preset.name then exists = true end
            end
            if not exists then table.insert(db.profiles, preset) end
            for _, slug in ipairs(preset.instances) do
                db.instanceProfile[slug] = db.instanceProfile[slug] or preset.name
            end
        end
        db.presetsVersion = SRC.PRESETS_VERSION
    end
    if #db.profiles == 0 then
        db.profiles[1] = self:BaseProfile("Default")
    end
    for _, p in ipairs(db.profiles) do
        p.base = p.base or { DPS = 0, TANK = 0, HEALER = 0 }
        p.groups = p.groups or {}
        p.rules = p.rules or {}
        p.assignments = p.assignments or {}
        p.assigned = p.assigned or {}
    end
    db.activeProfile = db.activeProfile or db.profiles[1].name
    db.roles = db.roles or {}                     -- manual role overrides: name key -> role
    db.specRoles = db.specRoles or {}             -- learned from softres CSV: name key -> { role, spec }
    db.pos = db.pos or {}
    db.options = db.options or {}
    for k, v in pairs(OPTION_DEFAULTS) do
        if db.options[k] == nil then db.options[k] = v end
    end
    self.db = db
end

function SRC:GetProfile(name)
    name = name or self.db.activeProfile
    for _, p in ipairs(self.db.profiles) do
        if p.name == name then return p end
    end
    self.db.activeProfile = self.db.profiles[1].name
    return self.db.profiles[1]
end

function SRC:SetActiveProfile(name, remember)
    self.db.activeProfile = name
    -- Remember the choice for the instance(s) of the loaded softres raid.
    if remember and self.data then
        for _, slug in ipairs(self.data.meta.instances) do
            self.db.instanceProfile[slug] = name
        end
    end
    self:RefreshUI()
end

function SRC:AutoSelectProfile()
    if not self.data then return end
    for _, slug in ipairs(self.data.meta.instances) do
        local name = self.db.instanceProfile[slug]
        if name then
            for _, p in ipairs(self.db.profiles) do
                if p.name == name then
                    self.db.activeProfile = name
                    return
                end
            end
        end
    end
end

------------------------------------------------------------
-- Slash commands
------------------------------------------------------------
local function help()
    SRC:Print("commands:")
    SRC:Print("  /src                 - toggle the window")
    SRC:Print("  /src import [string] - import a softres.it Gargul string (or open the import box)")
    SRC:Print("  /src gargul          - load the soft-reserves currently imported in Gargul")
    SRC:Print("  /src scan            - scan raid buffs now")
    SRC:Print("  /src announce        - post SR deductions to raid chat")
    SRC:Print("  /src whisper         - whisper over-reserved players what gets dropped")
    SRC:Print("  /src report          - full text report (copy to Discord)")
    SRC:Print("  /src fix             - corrected Gargul string (excess SRs dropped)")
    SRC:Print("  /src role <name> <tank|healer|dps|auto|assignment, e.g. Pull Hunter>")
    SRC:Print("  /src adj <name> <number>  - manual SR adjustment for this raid")
    SRC:Print("  /src skip <group>    - put a buff group on hold, e.g. WB before the unboon")
    SRC:Print("  /src check <group|all> - check it again")
    SRC:Print("  /src exclude <name>  - leave a player out of the check (e.g. unboons later)")
    SRC:Print("  /src include <name|all> - check them again")
    SRC:Print("  /src link <softres name> <character> - link a misspelled softres name")
    SRC:Print("  /src rules           - edit rule profiles")
    SRC:Print("  /src reset           - forget buff scans for this raid")
end

local ROLE_ARGS = { tank = "TANK", t = "TANK", healer = "HEALER", heal = "HEALER", h = "HEALER", dps = "DPS", d = "DPS" }

SLASH_SRCHECK1 = "/src"
SLASH_SRCHECK2 = "/srcheck"
SlashCmdList["SRCHECK"] = function(msg)
    msg = SRC.Trim(msg)
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" or cmd == "show" then
        SRC:ToggleUI()
    elseif cmd == "import" then
        if rest ~= "" then SRC:Import(rest) else SRC:ShowImport() end
    elseif cmd == "gargul" then
        SRC:ImportFromGargul()
    elseif cmd == "scan" or cmd == "verify" then
        SRC:Scan()
    elseif cmd == "announce" then
        SRC:Announce()
    elseif cmd == "whisper" then
        SRC:WhisperDeductions()
    elseif cmd == "report" then
        SRC:ShowReport()
    elseif cmd == "fix" or cmd == "export" then
        SRC:ShowCorrected()
    elseif cmd == "role" then
        local name, arg = rest:match("^(%S+)%s+(.+)$")
        local profile = SRC:GetProfile()
        local role = arg and ROLE_ARGS[arg:lower()]
        local assignment
        for _, a in ipairs(profile.assignments) do
            if arg and a.name:lower() == arg:lower() then assignment = a.name end
        end
        if not name or not (role or assignment or arg:lower() == "auto") then
            local names = {}
            for _, a in ipairs(profile.assignments) do names[#names + 1] = a.name end
            SRC:Print("usage: /src role <name> <tank|healer|dps|auto"
                .. (#names > 0 and ("|" .. table.concat(names, "|")) or "") .. ">")
        elseif assignment then
            SRC:SetAssignment(SRC.NameKey(name), assignment)
            SRC:Print(("%s is %s in profile %s."):format(name, assignment, profile.name))
        else
            SRC:SetAssignment(SRC.NameKey(name), nil)
            SRC:SetRole(SRC.NameKey(name), role)
            SRC:Print(("%s is now %s."):format(name, role and SRC.ROLE_LABEL[role] or "auto-detected"))
        end
    elseif cmd == "adj" then
        local name, n = rest:match("^(%S+)%s+([%+%-]?%d+)$")
        if not name then
            SRC:Print("usage: /src adj <name> <number>   (e.g. /src adj Bob +1)")
        elseif SRC:SetAdjustment(SRC.NameKey(name), tonumber(n)) then
            SRC:Print(("%s adjustment set to %+d."):format(name, tonumber(n)))
        end
    elseif cmd == "check" or cmd == "skip" then
        local checked = cmd == "check"
        local profile = SRC:GetProfile()
        local found
        for _, g in ipairs(profile.groups) do
            if rest:lower() == "all" or SRC.LowerUTF8(g.name) == SRC.LowerUTF8(rest) then
                found = SRC:SetGroupChecked(g.name, checked) or found
            end
        end
        if rest == "" or found == nil then
            local names = {}
            for _, g in ipairs(profile.groups) do names[#names + 1] = g.name end
            SRC:Print("usage: /src skip <buff group>   /src check <buff group|all>   groups: "
                .. table.concat(names, ", "))
        elseif not found then
            SRC:Print("import soft-reserves first.")
        else
            SRC:Print(checked and ("checking %s now."):format(rest) or ("%s is on hold (checked later)."):format(rest))
        end
    elseif cmd == "exclude" or cmd == "include" then
        local exclude = cmd == "exclude"
        if rest == "" then
            SRC:Print("usage: /src exclude <name>   /src include <name|all>")
        elseif rest:lower() == "all" then
            SRC:SetAllExcluded(exclude)
            SRC:Print(exclude and "everyone excluded from the check." or "everyone included in the check.")
        elseif SRC:SetExcluded(SRC.NameKey(rest), exclude) then
            SRC:Print(("%s %s the check."):format(rest, exclude and "excluded from" or "included in"))
        else
            SRC:Print("import soft-reserves first.")
        end
    elseif cmd == "link" then
        local srName, charName = rest:match("^(%S+)%s*(%S*)$")
        if not srName then
            SRC:Print("usage: /src link <softres name> <character>   (/src link <softres name> - to unlink)")
        else
            SRC:SetLink(SRC.NameKey(srName), SRC.NameKey(charName))
        end
    elseif cmd == "rules" or cmd == "options" or cmd == "config" then
        SRC:ToggleOptions()
    elseif cmd == "reset" then
        SRC:ResetScans()
    else
        help()
    end
end

------------------------------------------------------------
-- Events
------------------------------------------------------------
local ef = CreateFrame("Frame")
ef:RegisterEvent("PLAYER_LOGIN")
ef:RegisterEvent("READY_CHECK")
ef:RegisterEvent("READY_CHECK_FINISHED")
ef:RegisterEvent("GROUP_ROSTER_UPDATE")
ef:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        SRC:InitDB()
        SRC:RestoreSession()
        SRC:Print("loaded. Type |cffffff00/src|r to open, |cffffff00/src help|r for commands.")
    elseif event == "READY_CHECK" then
        -- Everyone is usually stacked at the entrance / boss: best time to scan.
        if SRC.db.options.scanOnReadyCheck and SRC.data then
            SRC:Scan(true)
        end
    elseif event == "READY_CHECK_FINISHED" then
        if SRC.db.options.scanOnReadyCheck and SRC.data then
            SRC:Scan()
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        SRC:RefreshUI()
    end
end)
