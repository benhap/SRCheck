-- Minimal WoW API stubs so SRCheck's logic files load under plain Lua 5.1.
-- Tests drive the fake group through TEST.raid.

TEST = { raid = {}, printed = {}, sent = {} }

local noopMeta = { __index = function() return function() end end }
function CreateFrame() return setmetatable({}, noopMeta) end

SlashCmdList, StaticPopupDialogs, RAID_CLASS_COLORS = {}, {}, {}
YES, NO, UNKNOWNOBJECT = "Yes", "No", "Unknown"
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) table.insert(TEST.printed, msg) end }
time, date = os.time, os.date
tinsert, tremove = table.insert, table.remove
C_Timer = { After = function(_, fn) fn() end }

function GetSpellInfo(id) return "Spell " .. id end
function GetItemInfo() return nil end
function SendChatMessage(msg, channel, _, target)
    table.insert(TEST.sent, { msg = msg, channel = channel, target = target })
end

local function member(unit)
    return TEST.raid[tonumber(unit:match("^raid(%d+)$") or -1)]
end

function IsInRaid() return #TEST.raid > 0 end
function IsInGroup() return #TEST.raid > 0 end
function GetNumGroupMembers() return #TEST.raid end
function GetNumSubgroupMembers() return 0 end
function GetRaidRosterInfo(i)
    local m = TEST.raid[i]
    if not m then return nil end
    return m.name, 0, 1, 60, m.class, m.class, "Zone", m.online ~= false, m.dead, m.raidRole, false, m.combatRole
end
function UnitExists(unit) return member(unit) ~= nil end
function UnitIsDeadOrGhost(unit) return member(unit).dead and true or false end
function UnitIsVisible(unit) return member(unit).visible ~= false end
function UnitIsConnected(unit) return member(unit).online ~= false end
-- buffs entries: spell id (name "Buff <id>") or { id, "Name" }
function UnitAura(unit, i)
    local b = (member(unit).buffs or {})[i]
    if not b then return nil end
    local id, name = b, "Buff " .. tostring(b)
    if type(b) == "table" then id, name = b[1], b[2] end
    return name, nil, 0, nil, 0, 0, nil, false, false, id
end
