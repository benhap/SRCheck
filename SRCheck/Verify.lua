-- Verify: scans raid members' buffs, works out each player's role and allowed
-- SR count from the active rule profile, and compares it with what they
-- reserved on softres.it. Also produces the chat announcements and reports.
--
-- Buff scans only see players the client has "visible" (roughly 100 yards),
-- so far/offline/dead players come out as "Not verified" instead of being
-- deducted. Scans are sticky by default: a buff seen once in this raid counts
-- for the rest of it (world buffs fall off on death).

local _, SRC = ...

------------------------------------------------------------
-- Buff group spell lists: "id, id, id/id/id, Buff Name" -> entries of alternatives
------------------------------------------------------------
local listCache = {}

function SRC.ParseSpellList(text)
    text = text or ""
    local entries = listCache[text]
    if entries then return entries end
    entries = {}
    for part in text:gmatch("[^,;\n]+") do
        local entry = { ids = {}, names = {}, prefixes = {}, labels = {} }
        for alt in part:gmatch("[^/]+") do
            alt = SRC.Trim(alt)
            if alt ~= "" then
                local id = tonumber(alt)
                if id then
                    entry.ids[id] = true
                elseif alt:sub(-1) == "*" then -- "Sayge's Dark Fortune of*"
                    entry.prefixes[#entry.prefixes + 1] = SRC.LowerUTF8(SRC.Trim(alt:sub(1, -2)))
                else
                    entry.names[SRC.LowerUTF8(alt)] = true
                end
                entry.labels[#entry.labels + 1] = alt
            end
        end
        if #entry.labels > 0 then entries[#entries + 1] = entry end
    end
    listCache[text] = entries
    return entries
end

-- Adds newer IDs of the same buff (SPELL_ID_ALIASES) to every entry that
-- lists an old one: "22888, 16609" -> "22888/355363, 16609/355366".
function SRC.AddSpellAliases(text)
    local parts = {}
    for part in (text or ""):gmatch("[^,]+") do
        local alts, have = {}, {}
        for alt in part:gmatch("[^/]+") do
            alt = SRC.Trim(alt)
            alts[#alts + 1] = alt
            have[alt] = true
        end
        for _, alt in ipairs({ unpack(alts) }) do
            for _, alias in ipairs(SRC.SPELL_ID_ALIASES[tonumber(alt)] or {}) do
                if not have[tostring(alias)] then
                    alts[#alts + 1] = tostring(alias)
                    have[tostring(alias)] = true
                end
            end
        end
        parts[#parts + 1] = table.concat(alts, "/")
    end
    return table.concat(parts, ", ")
end

-- auras = { ids = { [spellId] = true }, names = { [lower name] = true } }
-- Returns the number of entries present and the matched spell ids/names.
function SRC.CountMatches(entries, auras)
    local count, matched = 0, {}
    for _, entry in ipairs(entries) do
        local hit
        for id in pairs(entry.ids) do
            if auras.ids[id] then hit = id; break end
        end
        if not hit then
            for name in pairs(entry.names) do
                if auras.names[name] then hit = name; break end
            end
        end
        if not hit and #entry.prefixes > 0 then
            for name in pairs(auras.names) do
                for _, prefix in ipairs(entry.prefixes) do
                    if name:sub(1, #prefix) == prefix then hit = name; break end
                end
                if hit then break end
            end
        end
        if hit then
            count = count + 1
            matched[#matched + 1] = hit
        end
    end
    return count, matched
end

------------------------------------------------------------
-- Rule conditions: alternatives ("or" / "|") of requirements ("+" / "and" /
-- "&"), each "<N> <group>" with N defaulting to 1. Examples:
--   "3 WB"   "Flask"   "6 WB or 3 WB + Flask"
-- Parsed to { { {n = 6, group = "wb"} }, { {n = 3, group = "wb"}, {n = 1, group = "flask"} } }
------------------------------------------------------------
local condCache = {}

function SRC.ParseCondition(text)
    text = SRC.Trim(text)
    local cached = condCache[text]
    if cached then return cached.options, cached.err end

    local options, err = {}, nil
    local normalized = (" " .. text .. " "):gsub("%s[Oo][Rr]%s", "|"):gsub("%s[Aa][Nn][Dd]%s", "+")
    for optionText in normalized:gmatch("[^|]+") do
        local terms = {}
        for termText in optionText:gmatch("[^+&]+") do
            termText = SRC.Trim(termText)
            if termText ~= "" then
                local n, group = termText:match("^(%d+)%s*(.*)$")
                if n then
                    group = group:gsub("^[xX]%s+", "") -- "3x WB" / "3 x WB"
                else
                    group = termText
                end
                group = SRC.Trim(group)
                if group == "" then
                    err = "missing buff group in '" .. termText .. "'"
                else
                    terms[#terms + 1] = { n = tonumber(n) or 1, group = SRC.LowerUTF8(group), label = group }
                end
            end
        end
        if #terms > 0 then options[#options + 1] = terms end
    end
    if #options == 0 then err = err or "empty condition" end

    condCache[text] = { options = options, err = err }
    return options, err
end

-- lower-case group name -> group
local function groupIndex(profile)
    local index = {}
    for _, g in ipairs(profile.groups or {}) do
        if g.name and SRC.Trim(g.name) ~= "" then index[SRC.LowerUTF8(SRC.Trim(g.name))] = g end
    end
    return index
end

-- Returns an error string when the rule can't be evaluated (typo etc.).
function SRC.ValidateRule(profile, rule)
    local options, err = SRC.ParseCondition(rule.condition)
    if err then return err end
    local groups = groupIndex(profile)
    for _, terms in ipairs(options) do
        for _, t in ipairs(terms) do
            if not groups[t.group] then return "unknown buff group '" .. t.label .. "'" end
        end
    end
end

-- Three-valued AND / OR over values[1..n] (nil = unknown, so no ipairs).
local function allOf(values, n)
    local result = true
    for i = 1, n do
        if values[i] == false then return false end
        if values[i] == nil then result = nil end
    end
    return result
end

local function anyOf(values, n)
    local result = false
    for i = 1, n do
        if values[i] == true then return true end
        if values[i] == nil then result = nil end
    end
    return result
end

-- counts: lower group name -> number of entries of that group present (nil
-- when the player has not been scanned). held: lower group names on hold,
-- whose terms count as unknown, so "6 WB + Flask" still fails on a missing
-- flask while WB is on hold. Returns
--   { rule, ok, met, pending, waiting,
--     options = { { ok, met, terms = { {label, count, need, met, ok, held} } } } }
-- ok: true|false|nil (nil = can't tell yet); met: the same ignoring holds.
function SRC.EvaluateRule(profile, rule, counts, held)
    local options = SRC.ParseCondition(rule.condition)
    local groups = groupIndex(profile)
    local r = { rule = rule, options = {}, waiting = {} }
    local optionOks, optionMets = {}, {}
    for i, terms in ipairs(options) do
        local o = { terms = {} }
        local termOks, termMets = {}, {}
        for j, t in ipairs(terms) do
            local count = counts and counts[t.group]
            local term = { label = groups[t.group].name, count = count, need = t.n }
            if count then term.met = count >= t.n end
            term.held = held and held[t.group] or nil
            if not term.held then term.ok = term.met end
            if term.held and counts then r.waiting[term.label] = true end
            o.terms[j], termOks[j], termMets[j] = term, term.ok, term.met
        end
        o.ok, o.met = allOf(termOks, #terms), allOf(termMets, #terms)
        r.options[i], optionOks[i], optionMets[i] = o, o.ok, o.met
    end
    r.ok, r.met = anyOf(optionOks, #options), anyOf(optionMets, #options)
    r.pending = counts ~= nil and r.ok == nil -- scanned, but decided by a group on hold
    return r
end

------------------------------------------------------------
-- Group roster
------------------------------------------------------------
function SRC:GetRoster()
    local roster = {}
    local function add(unit, name, class, online, raidRole, combatRole)
        if not name or name == "" or name == UNKNOWNOBJECT then return end
        name = name:match("^[^%-]+")
        roster[#roster + 1] = {
            unit = unit, name = name, key = SRC.NameKey(name), class = class,
            online = online and true or false, raidRole = raidRole, combatRole = combatRole,
        }
    end

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name, _, _, _, _, class, _, online, _, raidRole, _, combatRole = GetRaidRosterInfo(i)
            add("raid" .. i, name, class, online, raidRole, combatRole)
        end
    else
        local units = { "player" }
        for i = 1, GetNumSubgroupMembers() do units[#units + 1] = "party" .. i end
        for _, unit in ipairs(units) do
            if UnitExists(unit) then
                local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
                add(unit, UnitName(unit), select(2, UnitClass(unit)), UnitIsConnected(unit), nil, role)
            end
        end
    end
    return roster
end

-- Links softres players to group members.
-- Returns link[p.key] = member and how[p.key] = "manual"|"exact"|"accents"|"fuzzy".
function SRC:MatchRoster(players, roster)
    local link, how, used = {}, {}, {}
    local byKey, byFold = {}, {}
    for _, m in ipairs(roster) do
        byKey[m.key] = m
        local f = SRC.FoldName(m.key)
        byFold[f] = (byFold[f] == nil) and m or false -- false: ambiguous
    end

    local function bind(p, m, kind)
        link[p.key], how[p.key], used[m] = m, kind, p
    end

    local links = (self.db.session and self.db.session.links) or {}
    for _, p in ipairs(players) do
        local m = links[p.key] and byKey[links[p.key]]
        if m and not used[m] then bind(p, m, "manual") end
    end
    for _, p in ipairs(players) do
        local m = byKey[p.key]
        if not link[p.key] and m and not used[m] then bind(p, m, "exact") end
    end
    for _, p in ipairs(players) do
        local m = byFold[SRC.FoldName(p.key)]
        if not link[p.key] and m and not used[m] then bind(p, m, "accents") end
    end
    -- Typos: a single unclaimed member of the same class within edit distance.
    for _, p in ipairs(players) do
        if not link[p.key] then
            local fp = SRC.FoldName(p.key)
            local limit = (#fp <= 5) and 1 or 2
            local found, count = nil, 0
            for _, m in ipairs(roster) do
                if not used[m] and (not p.class or not m.class or p.class == m.class)
                    and SRC.Levenshtein(fp, SRC.FoldName(m.key), limit) <= limit then
                    found, count = m, count + 1
                end
            end
            if count == 1 then bind(p, found, "fuzzy") end
        end
    end
    return link, how
end

------------------------------------------------------------
-- Scanning
------------------------------------------------------------
function SRC:Scan(quiet)
    local s = self.db.session
    if not self.data or not s then
        self:Print("import a softres.it Gargul string first (|cffffff00/src import|r).")
        return
    end

    local now = time()
    local tally = { ok = 0, far = 0, offline = 0, dead = 0 }
    s.last = {}
    for _, m in ipairs(self:GetRoster()) do
        local state
        if not m.online then
            state = "offline"
        elseif UnitIsDeadOrGhost(m.unit) then
            state = "dead"
        elseif not UnitIsVisible(m.unit) then
            state = "far"
        else
            state = "ok"
            local auras = { ids = {}, names = {} }
            SRC.ForEachBuff(m.unit, function(id, name)
                if id then auras.ids[id] = true end
                if name then auras.names[SRC.LowerUTF8(name)] = true end
            end)
            s.last[m.key] = auras

            local seen = s.seen[m.key] or { ids = {}, names = {} }
            for id in pairs(auras.ids) do seen.ids[id] = true end
            for name in pairs(auras.names) do seen.names[name] = true end
            s.seen[m.key] = seen
        end
        s.states[m.key] = { state = state, at = now }
        tally[state] = tally[state] + 1
    end
    s.lastScanAt = now

    self:RefreshUI()
    if not quiet then
        local _, summary = self:Evaluate()
        local missed = {}
        if tally.far > 0 then missed[#missed + 1] = tally.far .. " out of range" end
        if tally.offline > 0 then missed[#missed + 1] = tally.offline .. " offline" end
        if tally.dead > 0 then missed[#missed + 1] = tally.dead .. " dead" end
        self:Print(("scanned %d players%s - |cffff4040%d to deduct|r, %d not verified%s%s.%s"):format(
            tally.ok, #missed > 0 and (" (" .. table.concat(missed, ", ") .. " skipped)") or "",
            summary.OVER, summary.UNKNOWN,
            summary.PENDING > 0 and (", %d pending"):format(summary.PENDING) or "",
            summary.SKIPPED > 0 and (", %d excluded from the check"):format(summary.SKIPPED) or "",
            self:CheckNote(self:GetProfile())))
    end
end

function SRC:ResetScans()
    local s = self.db.session
    if not s then return end
    s.seen, s.last, s.states, s.lastScanAt = {}, {}, {}, nil
    self:Print("buff scans for this raid cleared.")
    self:RefreshUI()
end

------------------------------------------------------------
-- Manual overrides
------------------------------------------------------------
function SRC:SetRole(key, role)
    self.db.roles[key] = role
    self:RefreshUI()
end

function SRC:SetAdjustment(key, n)
    local s = self.db.session
    if not s then
        self:Print("import soft-reserves first.")
        return false
    end
    s.adj[key] = (n and n ~= 0) and n or nil
    self:RefreshUI()
    return true
end

function SRC:SetLink(srKey, charKey)
    local s = self.db.session
    if not s then return self:Print("import soft-reserves first.") end
    if not self.data.byKey[srKey] then
        return self:Print("no softres player named '" .. srKey .. "'.")
    end
    s.links[srKey] = (charKey ~= "" and charKey ~= srKey) and charKey or nil
    self:Print(s.links[srKey] and ("linked softres '%s' to %s."):format(srKey, charKey)
        or ("unlinked softres '%s'."):format(srKey))
    self:RefreshUI()
end

-- Buff groups can be put on hold for this raid, e.g. check the flask now and
-- the world buffs after the unboon. A group on hold can't cause deductions.
function SRC:HeldGroups()
    local s = self.db.session
    return (s and s.heldGroups) or {}
end

function SRC:IsGroupChecked(name)
    return not self:HeldGroups()[SRC.LowerUTF8(SRC.Trim(name))]
end

function SRC:SetGroupChecked(name, checked)
    local s = self.db.session
    if not s then return false end
    s.heldGroups = s.heldGroups or {}
    s.heldGroups[SRC.LowerUTF8(SRC.Trim(name))] = (not checked) or nil
    self:RefreshUI()
    return true
end

-- Names of the profile's buff groups being checked now / on hold.
function SRC:GroupCheckLists(profile)
    local checked, onHold = {}, {}
    for _, g in ipairs(profile.groups) do
        local list = self:IsGroupChecked(g.name) and checked or onHold
        list[#list + 1] = g.name
    end
    return checked, onHold
end

-- " (checked: Flask; later: WB)" when some groups are on hold, else "".
function SRC:CheckNote(profile)
    local checked, onHold = self:GroupCheckLists(profile)
    if #onHold == 0 then return "" end
    return (" (checked: %s; later: %s)"):format(#checked > 0 and table.concat(checked, ", ") or "nothing",
        table.concat(onHold, ", "))
end

-- Leave a player out of the check for this raid (e.g. they unboon later).
-- Excluded players are never deducted; their SRs stay as reserved.
function SRC:SetExcluded(key, excluded)
    local s = self.db.session
    if not s then return false end
    s.excluded = s.excluded or {}
    s.excluded[key] = excluded or nil
    self:RefreshUI()
    return true
end

-- Include (or exclude) every player with soft-reserves.
function SRC:SetAllExcluded(excluded)
    local s = self.db.session
    if not s then return end
    s.excluded = {}
    if excluded then
        for _, row in ipairs((self:Evaluate())) do
            if row.player then s.excluded[row.key] = true end
        end
    end
    self:RefreshUI()
end

-- Raid assignment (Pull Hunter, Mage Tank, ...) in the active profile only.
function SRC:SetAssignment(key, name)
    self:GetProfile().assigned[key] = name
    self:RefreshUI()
end

function SRC.FindAssignment(profile, name)
    if not name then return nil end
    for _, a in ipairs(profile.assignments or {}) do
        if a.name == name then return a end
    end
end

-- Role precedence: raid assignment in this profile > manual role > softres
-- spec (this import) > softres spec remembered from an earlier CSV import >
-- raid Main Tank flag / assigned group role > DPS.
-- Returns role, source text and the assignment name (if any).
function SRC:ResolveRole(key, p, m, profile)
    profile = profile or self:GetProfile()
    local assigned = profile.assigned and (profile.assigned[key] or (p and profile.assigned[p.key]))
    local a = SRC.FindAssignment(profile, assigned)
    if a then
        return a.role, ("%s in profile %s (counts as %s)"):format(a.name, profile.name, SRC.ROLE_LABEL[a.role]), a.name
    end
    local manual = self.db.roles[key] or (p and self.db.roles[p.key])
    if manual then return manual, "set manually (all raids)" end
    return self:AutoRole(key, p, m)
end

-- The role SRCheck detects on its own, ignoring manual choices.
function SRC:AutoRole(key, p, m)
    local db = self.db
    if p and p.specRole then return p.specRole, "softres spec: " .. p.spec end
    local learned = db.specRoles[key] or (p and db.specRoles[p.key])
    if learned then return learned.role, "softres spec (earlier CSV): " .. (learned.spec or "?") end
    if m then
        if m.raidRole == "MAINTANK" then return "TANK", "raid Main Tank" end
        if m.combatRole == "TANK" or m.combatRole == "HEALER" then
            return m.combatRole, "assigned group role"
        end
    end
    return "DPS", "default"
end

------------------------------------------------------------
-- Evaluation
------------------------------------------------------------
function SRC:EvaluateRow(profile, p, m, how)
    local s = self.db.session
    local key = m and m.key or p.key
    local row = {
        key = key, player = p, member = m, linkKind = how,
        name = m and m.name or p.name,
        class = (m and m.class) or (p and p.class),
        reserved = p and #p.items or 0,
        adj = s.adj[key] or 0,
    }
    row.role, row.roleSource, row.assignment = self:ResolveRole(key, p, m, profile)
    row.roleLabel = row.assignment or SRC.ROLE_LABEL[row.role]
    row.manualRole = self.db.roles[key] ~= nil

    local scan = m and s.states[m.key]
    row.state = scan and scan.state or "unscanned"
    row.scannedAt = scan and scan.at
    local auras = m and (self.db.options.sticky and s.seen[m.key] or s.last[m.key])

    -- Buff group counts, e.g. { wb = 4, flask = 1 }, plus what matched (tooltip).
    local counts
    row.groups = {}
    if auras then
        counts = {}
        for _, g in ipairs(profile.groups or {}) do
            local count, matched = SRC.CountMatches(SRC.ParseSpellList(g.spells), auras)
            counts[SRC.LowerUTF8(SRC.Trim(g.name or ""))] = count
            row.groups[#row.groups + 1] = { group = g, count = count, matched = matched }
        end
    end

    local base = profile.base[row.role] or 0
    local minA, maxA = base, base
    local requiredFailed, requiredUnknown = false, false
    row.base = base
    row.rules = {}
    for _, rule in ipairs(profile.rules) do
        if rule.enabled ~= false and (not rule.roles or rule.roles[row.role])
            and not SRC.ValidateRule(profile, rule) then
            local r = SRC.EvaluateRule(profile, rule, counts, self:HeldGroups())
            if rule.required then
                if r.ok == false then
                    requiredFailed = true
                elseif r.ok == nil then
                    requiredUnknown = true
                end
            else
                local bonus = rule.bonus or 0
                if r.ok then
                    minA, maxA = minA + bonus, maxA + bonus
                elseif r.ok == nil then -- not scanned yet: could go either way
                    if bonus > 0 then maxA = maxA + bonus else minA = minA + bonus end
                end
            end
            row.rules[#row.rules + 1] = r
        end
    end
    -- A missed required rule means no SRs at all (the manual adjustment still applies).
    if requiredFailed then
        minA, maxA = 0, 0
    elseif requiredUnknown then
        minA = 0
    end
    row.minAllowed = math.max(0, minA + row.adj)
    row.maxAllowed = math.max(0, maxA + row.adj)

    if p and row.reserved > row.maxAllowed then
        row.status, row.deduct = "OVER", row.reserved - row.maxAllowed
    elseif not p then
        row.status = "NOSR"
    elseif not m then
        row.status = "ABSENT"
    elseif row.reserved > row.minAllowed then
        -- Scanned but undecided: only rules on hold are left open.
        row.status = auras and "PENDING" or "UNKNOWN"
    elseif row.reserved < row.minAllowed then
        row.status, row.extra = "UNDER", row.minAllowed - row.reserved
    else
        row.status = "OK"
    end

    -- Excluded from the check: keep the would-be result for the tooltip/report only.
    if p and s.excluded and s.excluded[key] then
        row.excluded = true
        row.wouldStatus, row.wouldDeduct = row.status, row.deduct
        row.status, row.deduct, row.extra = "SKIPPED", nil, nil
    end
    return row
end

-- Returns rows (sorted, most urgent first) and a per-status summary.
function SRC:Evaluate()
    local summary = { OVER = 0, UNKNOWN = 0, PENDING = 0, ABSENT = 0, SKIPPED = 0, UNDER = 0, NOSR = 0, OK = 0,
        deduct = 0 }
    if not self.data or not self.db.session then return {}, summary end

    local profile = self:GetProfile()
    local roster = self:GetRoster()
    local link, how = self:MatchRoster(self.data.players, roster)

    local rows, linked = {}, {}
    for _, p in ipairs(self.data.players) do
        local m = link[p.key]
        if m then linked[m] = true end
        rows[#rows + 1] = self:EvaluateRow(profile, p, m, how[p.key])
    end
    for _, m in ipairs(roster) do
        if not linked[m] then rows[#rows + 1] = self:EvaluateRow(profile, nil, m) end
    end

    for _, row in ipairs(rows) do
        summary[row.status] = summary[row.status] + 1
        summary.deduct = summary.deduct + (row.deduct or 0)
    end
    table.sort(rows, function(a, b)
        local oa, ob = SRC.STATUS[a.status].order, SRC.STATUS[b.status].order
        if oa ~= ob then return oa < ob end
        return a.key < b.key
    end)
    return rows, summary
end

------------------------------------------------------------
-- Text helpers for chat / reports
------------------------------------------------------------
local STATE_TEXT = {
    far = "out of range", offline = "offline", dead = "dead", unscanned = "not scanned",
}

function SRC.StateText(row)
    if not row.member then return "not in group" end
    return STATE_TEXT[row.state] or "scanned"
end

-- What a failed rule was short of:
--   "3 WB"                 -> "WB 1/3"
--   "Flask"                -> "Flask missing"
--   "6 WB or 3 WB + Flask" -> "Buffed: WB 4/6 or Flask 0/1"
-- actual: describe the result ignoring groups on hold.
function SRC.RuleShortfall(r, actual)
    local key = actual and "met" or "ok"
    local options = r.options
    if #options == 1 and #options[1].terms == 1 then
        local t = options[1].terms[1]
        if t.need == 1 then return t.label .. " missing" end
        return ("%s %d/%d"):format(t.label, t.count, t.need)
    end
    local alternatives = {}
    for _, o in ipairs(options) do
        local missing = {}
        for _, t in ipairs(o.terms) do
            if t[key] == false then missing[#missing + 1] = ("%s %d/%d"):format(t.label, t.count, t.need) end
        end
        if #missing > 0 then alternatives[#alternatives + 1] = table.concat(missing, " + ") end
    end
    return r.rule.name .. ": " .. table.concat(alternatives, " or ")
end

-- Why a player got fewer SRs: "Flask missing, WB 1/3"
function SRC.MissingText(row)
    local parts = {}
    for _, r in ipairs(row.rules) do
        if r.ok == false then parts[#parts + 1] = SRC.RuleShortfall(r) end
    end
    if #parts == 0 then
        return ("max %d SR as %s"):format(row.maxAllowed, row.roleLabel)
    end
    return table.concat(parts, ", ")
end

-- Buff groups on hold that this player's result is waiting for: { "WB" }
function SRC.WaitingFor(row)
    local names, seen = {}, {}
    for _, r in ipairs(row.rules) do
        if r.pending then
            for label in pairs(r.waiting) do
                if not seen[label] then
                    seen[label] = true
                    names[#names + 1] = label
                end
            end
        end
    end
    table.sort(names)
    return names
end

function SRC.AllowedText(row)
    if row.minAllowed == row.maxAllowed then return tostring(row.minAllowed) end
    return row.minAllowed .. "-" .. row.maxAllowed
end

-- Splits "head: a, b, c" style lists into chat-sized lines.
local function chatLines(head, items, limit)
    limit = limit or 240
    local lines, cur = {}, head
    for i, item in ipairs(items) do
        local sep = (cur == head) and " " or ", "
        if #cur + #sep + #item > limit then
            lines[#lines + 1] = cur
            cur = "  " .. item
        else
            cur = cur .. sep .. item
        end
        if i == #items then lines[#lines + 1] = cur end
    end
    return lines
end

local function sendLines(lines, channel)
    for i, line in ipairs(lines) do
        if channel then
            C_Timer.After((i - 1) * 0.3, function() SRC.SendChat(line, channel) end)
        else
            SRC:Print(line)
        end
    end
end

------------------------------------------------------------
-- Announce / whisper / report / corrected export
------------------------------------------------------------
function SRC:Announce()
    local rows, summary = self:Evaluate()
    if not self.data then return self:Print("nothing imported yet.") end
    local channel = SRC.GroupChannel()

    local over, unknown = {}, {}
    for _, row in ipairs(rows) do
        if row.status == "OVER" then
            over[#over + 1] = ("%s -%d (%s)"):format(row.name, row.deduct, SRC.MissingText(row))
        elseif row.status == "UNKNOWN" then
            unknown[#unknown + 1] = ("%s (%s)"):format(row.name, SRC.StateText(row))
        end
    end

    local note = self:CheckNote(self:GetProfile())
    local lines = {}
    if #over == 0 then
        lines[1] = "[SRCheck] No SR deductions" .. note .. "."
    else
        for _, l in ipairs(chatLines(("[SRCheck] SR deductions, %d SR%s:"):format(summary.deduct, note), over)) do
            lines[#lines + 1] = l
        end
    end
    if #unknown > 0 then
        for _, l in ipairs(chatLines("[SRCheck] Not verified yet:", unknown)) do
            lines[#lines + 1] = l
        end
    end
    sendLines(lines, channel)
end

function SRC:WhisperDeductions()
    local rows = self:Evaluate()
    local sent = 0
    for _, row in ipairs(rows) do
        if row.status == "OVER" and row.member and row.member.online then
            local links = {}
            for _, item in ipairs(SRC.ItemsToDrop(row.player, row.deduct)) do
                links[#links + 1] = (SRC.ItemLink(item.id))
            end
            local why = SRC.MissingText(row)
            local _, later = self:GroupCheckLists(self:GetProfile())
            if #later > 0 then why = why .. "; " .. table.concat(later, ", ") .. " checked later" end
            local msg = ("[SRCheck] You reserved %d SR but are allowed %d (%s). Removed: %s"):format(
                row.reserved, row.maxAllowed, why, table.concat(links, " "))
            if #msg > 255 then
                msg = ("[SRCheck] You reserved %d SR but are allowed %d (%s). Your last %d SR are removed."):format(
                    row.reserved, row.maxAllowed, why, row.deduct)
            end
            local name = row.member.name
            C_Timer.After(sent * 0.4, function() SRC.SendChat(msg, "WHISPER", name) end)
            sent = sent + 1
        end
    end
    self:Print(sent > 0 and ("whispered %d players."):format(sent) or "nobody to whisper.")
end

function SRC:RaidTitle()
    local meta = self.data and self.data.meta
    if not meta then return "" end
    local names = {}
    for _, slug in ipairs(meta.instances) do names[#names + 1] = SRC.INSTANCE_NAMES[slug] or slug end
    local title = #names > 0 and table.concat(names, " + ") or "softres.it raid"
    if meta.id then title = title .. " (" .. meta.id .. ")" end
    return title
end

function SRC:ProfileSummary(profile)
    local parts = {}
    for _, rule in ipairs(profile.rules) do
        if rule.enabled ~= false then
            if rule.required then
                parts[#parts + 1] = ("%s required, else 0 SR"):format(SRC.Trim(rule.condition))
            else
                parts[#parts + 1] = ("%s %+d (%s)"):format(rule.name, rule.bonus or 0, SRC.Trim(rule.condition))
            end
        end
    end
    local text = ("base DPS %d / Tank %d / Healer %d; %s"):format(profile.base.DPS or 0, profile.base.TANK or 0,
        profile.base.HEALER or 0, #parts > 0 and table.concat(parts, "; ") or "no rules")
    local assignments = {}
    for _, a in ipairs(profile.assignments or {}) do
        assignments[#assignments + 1] = ("%s = %s"):format(a.name, SRC.ROLE_LABEL[a.role])
    end
    if #assignments > 0 then text = text .. "; " .. table.concat(assignments, ", ") end
    return text
end

function SRC:BuildReport()
    local rows, summary = self:Evaluate()
    local profile = self:GetProfile()
    local s = self.db.session
    local out = {}
    out[#out + 1] = ("SRCheck - %s - profile '%s'"):format(self:RaidTitle(), profile.name)
    out[#out + 1] = "Rules: " .. self:ProfileSummary(profile)
    local _, onHold = self:GroupCheckLists(profile)
    if #onHold > 0 then out[#out + 1] = "On hold (checked later): " .. table.concat(onHold, ", ") end
    out[#out + 1] = "Last buff scan: " .. (s.lastScanAt and date("%Y-%m-%d %H:%M", s.lastScanAt) or "never")
    out[#out + 1] = ("Summary: %d to deduct (%d SR), %d not verified, %d pending, %d not in group, %d not checked, "
        .. "%d can add, %d without SR, %d OK"):format(summary.OVER, summary.deduct, summary.UNKNOWN, summary.PENDING,
        summary.ABSENT, summary.SKIPPED, summary.UNDER, summary.NOSR, summary.OK)

    local current
    for _, row in ipairs(rows) do
        if row.status ~= current then
            current = row.status
            out[#out + 1] = ""
            out[#out + 1] = SRC.STATUS[current].label:upper()
        end
        local line = ("  %s (%s) - %d SR, allowed %s"):format(row.name, row.roleLabel,
            row.reserved, SRC.AllowedText(row))
        if row.status == "OVER" then
            local names = {}
            for _, item in ipairs(SRC.ItemsToDrop(row.player, row.deduct)) do
                names[#names + 1] = SRC.ItemName(item.id)
            end
            line = line .. " - " .. SRC.MissingText(row) .. " - drop: " .. table.concat(names, ", ")
        elseif row.status == "UNKNOWN" then
            line = line .. " - " .. SRC.StateText(row)
        elseif row.status == "PENDING" then
            line = line .. " - waiting for: " .. table.concat(SRC.WaitingFor(row), ", ")
        elseif row.status == "UNDER" then
            line = line .. (" - may add %d"):format(row.extra)
        elseif row.status == "SKIPPED" then
            line = line .. " - excluded from the check"
            if row.wouldStatus == "OVER" then
                line = line .. (" (currently -%d: %s)"):format(row.wouldDeduct, SRC.MissingText(row))
            end
        end
        if row.adj ~= 0 then line = line .. (" [manual %+d]"):format(row.adj) end
        out[#out + 1] = line
    end
    return table.concat(out, "\n")
end

-- drops keyed by softres name, for BuildCorrectedGargul
function SRC:CollectDrops()
    local rows, summary = self:Evaluate()
    local drops = {}
    for _, row in ipairs(rows) do
        if row.status == "OVER" then drops[row.player.key] = row.deduct end
    end
    return drops, summary
end

function SRC:ShowReport()
    if not self.data then return self:Print("nothing imported yet.") end
    self:ShowText("SRCheck report", self:BuildReport(),
        "Ctrl+C to copy (e.g. to Discord).")
end

function SRC:ShowCorrected()
    if not self.data then return self:Print("nothing imported yet.") end
    local drops, summary = self:CollectDrops()
    local text, removed = self:BuildCorrectedGargul(drops)
    local hint
    if removed == 0 then
        hint = "No deductions - this is the original list. Ctrl+C to copy."
    else
        hint = ("%d SR removed from %d players (their last-placed SRs). Ctrl+C, then paste into Gargul (/gl sr)."):format(
            removed, summary.OVER)
    end
    if summary.UNKNOWN > 0 then
        hint = hint .. (" |cffffb000%d players are not verified yet.|r"):format(summary.UNKNOWN)
    end
    self:ShowText("Corrected Gargul string", text, hint)
end

StaticPopupDialogs["SRCHECK_SEND_GARGUL"] = {
    text = "Replace Gargul's soft-reserves with the corrected list?\n%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function() SRC:SendToGargul(true) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

function SRC:SendToGargul(confirmed)
    local gargul = _G.Gargul
    if not (gargul and gargul.SoftRes and gargul.SoftRes.import) then
        return self:Print("Gargul is not loaded - use the corrected string instead.")
    end
    if not self.data then return self:Print("nothing imported yet.") end

    local drops, summary = self:CollectDrops()
    if not confirmed then
        local note = ("%d SR will be removed from %d players."):format(summary.deduct, summary.OVER)
        if summary.UNKNOWN > 0 then
            note = note .. ("\n%d players are not verified yet."):format(summary.UNKNOWN)
        end
        StaticPopup_Show("SRCHECK_SEND_GARGUL", note)
        return
    end

    local text = self:BuildCorrectedGargul(drops)
    local ok, result = pcall(gargul.SoftRes.import, gargul.SoftRes, text, true)
    if ok and result ~= false then
        self.db.session.sentAt = time()
        self:Print("corrected soft-reserves imported into Gargul.")
        self:RefreshUI()
    else
        self:Print("|cffff4040Gargul import failed|r" .. (ok and "" or (": " .. tostring(result)))
            .. " - paste the corrected string manually (/src fix).")
    end
end
