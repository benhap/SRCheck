-- Static data and defaults: buff spell IDs, softres.it spec -> role mapping,
-- instance names and the preset rule profiles (BWL, AQ40, Test).

local _, SRC = ...

SRC.ROLES = { "DPS", "TANK", "HEALER" }
SRC.ROLE_LABEL = { DPS = "DPS", TANK = "Tank", HEALER = "Healer" }
SRC.ROLE_SHORT = { DPS = "D", TANK = "T", HEALER = "H" }
SRC.ROLE_COLOR = { DPS = "ffff7f7f", TANK = "ff7fbfff", HEALER = "ff7fff7f" }

------------------------------------------------------------
-- Buff groups used by the presets.
-- A group's spell list is a comma separated list of entries; each entry may
-- hold alternatives separated by "/" which count only once (e.g. the eight
-- Darkmoon Faire fortunes are a single world buff). Alternatives are spell
-- IDs, exact buff names, or a name prefix ending in "*". Rules then refer to
-- groups by name, e.g. "3 WB", "Flask" or "6 WB or 3 WB + Flask".
--
-- Each buff lists its IDs and its name, so a future ID change still matches.
------------------------------------------------------------
SRC.WORLD_BUFF_SPELLS = table.concat({
    -- Ony/Nef, ZG and Rend buffs got new IDs (3553xx) in a 2021 hotfix; Era uses those.
    "22888/355363/Rallying Cry of the Dragonslayer", -- Onyxia / Nefarian head
    "24425/355365/Spirit of Zandalar",               -- Hakkar heart
    "16609/355366/Warchief's Blessing",              -- Rend head
    "15366/Songflower Serenade",
    "22817/Fengus' Ferocity",                        -- Dire Maul tribute
    "22818/Mol'dar's Moxie",                         -- Dire Maul tribute
    "22820/Slip'kik's Savvy",                        -- Dire Maul tribute
    -- Darkmoon Faire: any of Sayge's eight fortunes (Damage, Agility, Intelligence,
    -- Spirit, Stamina, Strength, Armor, Resistance), counted once
    "23768/23736/23766/23738/23737/23735/23767/23769/Sayge's Dark Fortune of*",
}, ", ")

-- Any flask counts, once: a single entry with every flask as an alternative.
-- Only the Titans buff is called "Flask of ..."; the others show their effect name.
SRC.FLASK_SPELLS = table.concat({
    "17626", "Flask of the Titans",
    "17627", "Distilled Wisdom",
    "17628", "Supreme Power",
    "17629", "Chromatic Resistance",
    "17624", "Petrification", -- Flask of Petrification
    "Flask of*",
}, "/")

-- Spell IDs and the newer IDs of the same buff; used to upgrade saved lists.
SRC.SPELL_ID_ALIASES = { [22888] = { 355363 }, [24425] = { 355365 }, [16609] = { 355366 } }

-- Druid buffs for the Test profile; names too, so every rank counts.
SRC.MOTW_SPELLS = "Mark of the Wild/Gift of the Wild/1126/5232/6756/5234/8907/9884/9885/21849/21850"
SRC.THORNS_SPELLS = "Thorns/467/782/1075/8914/9756/9910"

------------------------------------------------------------
-- Profiles
--   base         SRs per role before any rule
--   groups       named buff lists used by rule conditions
--   rules        { name, condition, bonus, required, enabled, roles }:
--                each met rule adds its bonus (rules stack); a "required"
--                rule that is not met drops the allowance to 0
--   assignments  raid jobs picked per character in the Role menu, e.g.
--                Pull Hunter; they count as the given role (base + rules)
--   assigned     character name key -> assignment name (per profile)
--   instances    softres.it slugs that auto-select the profile
------------------------------------------------------------
local function allRoles() return { DPS = true, TANK = true, HEALER = true } end
local function wbGroup() return { name = "WB", spells = SRC.WORLD_BUFF_SPELLS } end
local function flaskGroup() return { name = "Flask", spells = SRC.FLASK_SPELLS } end

local function rule(name, condition, bonus, required)
    return { name = name, condition = condition, bonus = bonus, required = required or nil,
        enabled = true, roles = allRoles() }
end

-- Generic starting point for new profiles.
function SRC:BaseProfile(name)
    return {
        name = name or "Profile",
        base = { DPS = 1, TANK = 2, HEALER = 2 },
        groups = { wbGroup(), flaskGroup() },
        rules = { rule("World Buffs", "3 WB", 1), rule("Flask", "Flask", 1) },
        assignments = {},
        assigned = {},
        instances = {},
    }
end

-- The guild's raid setups, created on first run.
local PRESETS = {
    -- 2 SR DPS / 3 SR tank, healer, pull hunter, mage tank; +1 for 5+ WB, +1 for a flask
    BWL = function()
        local p = SRC:BaseProfile("BWL")
        p.instances = { "bwl" }
        p.base = { DPS = 2, TANK = 3, HEALER = 3 }
        p.rules = { rule("5 WB", "5 WB", 1), rule("Flask", "Flask", 1) }
        p.assignments = { { name = "Pull Hunter", role = "TANK" }, { name = "Mage Tank", role = "TANK" } }
        return p
    end,
    -- 3 SR DPS / 4 SR tank, healer, pull hunter, warlock tank; +1 for 6 WB and a
    -- flask together (4 / 5). Gear check and consumables are checked by hand.
    AQ40 = function()
        local p = SRC:BaseProfile("AQ40")
        p.instances = { "aq40" }
        p.base = { DPS = 3, TANK = 4, HEALER = 4 }
        p.rules = { rule("6 WB + Flask", "6 WB + Flask", 1) }
        p.assignments = { { name = "Pull Hunter", role = "TANK" }, { name = "Warlock Tank", role = "TANK" } }
        return p
    end,
    -- Detection check: 1 SR + 1 each for Mark of the Wild, Thorns, any world buff
    Test = function()
        local p = SRC:BaseProfile("Test")
        p.base = { DPS = 1, TANK = 1, HEALER = 1 }
        p.groups = {
            { name = "MotW", spells = SRC.MOTW_SPELLS },
            { name = "Thorns", spells = SRC.THORNS_SPELLS },
            wbGroup(),
        }
        p.rules = {
            rule("Mark of the Wild", "MotW", 1),
            rule("Thorns", "Thorns", 1),
            rule("World buff", "WB", 1),
        }
        return p
    end,
}
SRC.PRESET_ORDER = { "BWL", "AQ40", "Test" }
-- Bump when presets change so existing installs receive them (see InitDB).
SRC.PRESETS_VERSION = 5

function SRC:PresetProfile(name)
    return PRESETS[name] and PRESETS[name]()
end

------------------------------------------------------------
-- softres.it specs (as named in its CSV export) that are not DPS. Mirrors the
-- site's own role table, which also drives its @tank/@healer raid bonuses.
-- Key: "<class>:<spec>" lower case. Note softres "Feral" is DPS; feral tanks
-- pick "Guardian".
------------------------------------------------------------
SRC.SPEC_ROLES = {
    ["druid:guardian"]      = "TANK",
    ["druid:restoration"]   = "HEALER",
    ["paladin:protection"]  = "TANK",
    ["paladin:holy"]        = "HEALER",
    ["priest:discipline"]   = "HEALER",
    ["priest:holy"]         = "HEALER",
    ["shaman:restoration"]  = "HEALER",
    ["warrior:protection"]  = "TANK",
}

-- softres.it instance slugs (metadata.instances) -> display name
SRC.INSTANCE_NAMES = {
    mc = "Molten Core",
    onyxia = "Onyxia's Lair",
    bwl = "Blackwing Lair",
    zg = "Zul'Gurub",
    aq20 = "Ruins of Ahn'Qiraj",
    aq40 = "Temple of Ahn'Qiraj",
    naxxramas = "Naxxramas",
    lordkazzak = "Lord Kazzak",
    azuregos = "Azuregos",
    dragonsofnightmare = "Dragons of Nightmare",
}

-- Display order and colors for verification results.
SRC.STATUS = {
    OVER    = { order = 1, label = "DEDUCT",       color = "ffff4040" },
    UNKNOWN = { order = 2, label = "Not verified", color = "ffffb000" },
    PENDING = { order = 3, label = "Pending",      color = "ffd8c070" }, -- depends on rules on hold
    ABSENT  = { order = 4, label = "Not in group", color = "ff9d9d9d" },
    SKIPPED = { order = 5, label = "Not checked",  color = "ff9d9d9d" }, -- excluded (e.g. unboons later)
    UNDER   = { order = 6, label = "Can add",      color = "ff40c0ff" },
    NOSR    = { order = 7, label = "No SR",        color = "ffc0c0c0" },
    OK      = { order = 8, label = "OK",           color = "ff40ff40" },
}
