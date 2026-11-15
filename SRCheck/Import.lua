-- Import: parses softres.it exports into SRCheck's model and builds the
-- corrected Gargul string.
--
-- Gargul export (what softres.it's "Gargul" button gives you):
--   base64( zlib( JSON ) ) with
--   { metadata = { id, url, instances = {"aq20"}, note, ... },
--     softreserves = { { name, class, note, items = { { id, note, order } } } },
--     hardreserves = {}, bonusrolls = {} }
--   It carries no spec/role. The softres.it CSV export does (Class, Spec
--   columns), so a CSV import also teaches SRCheck each character's role.

local _, SRC = ...
local Codec = SRC.Codec

local function str(v)
    return type(v) == "string" and v or nil
end

local function libDeflate()
    return LibStub and LibStub("LibDeflate", true)
end

-- Items are kept in softres order (the order players placed them); the last
-- ones are the first to go when a player has too many.
local function sortItems(items)
    table.sort(items, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.seq < b.seq
    end)
end

local function addPlayer(data, name, class, spec)
    local key = SRC.NameKey(name)
    local p = data.byKey[key]
    if not p then
        p = {
            key = key,
            name = SRC.Trim(name),
            class = SRC.NormalizeClass(class),
            classRaw = str(class) and class:lower() or nil,
            items = {},
        }
        data.byKey[key] = p
        data.players[#data.players + 1] = p
    end
    spec = str(spec) and SRC.Trim(spec) or nil
    if spec and spec ~= "" and p.classRaw then
        p.spec = spec
        p.specRole = SRC.SPEC_ROLES[p.classRaw .. ":" .. spec:lower()] or "DPS"
    end
    return p
end

local function newData(source)
    return { source = source, meta = { instances = {} }, players = {}, byKey = {} }
end

------------------------------------------------------------
-- Gargul string
------------------------------------------------------------
function SRC.DecodeGargul(text)
    local compressed, err = Codec.Base64Decode(text)
    if not compressed then
        return nil, "not a Gargul string (" .. err .. ")"
    end
    local LibDeflate = libDeflate()
    if not LibDeflate then return nil, "LibDeflate is missing" end
    local ok, json = pcall(LibDeflate.DecompressZlib, LibDeflate, compressed)
    if not ok or type(json) ~= "string" then
        return nil, "could not decompress - copy the Gargul export from softres.it again, as-is"
    end
    local root, jerr = Codec.JSONDecode(json)
    if not root then return nil, "invalid data: " .. jerr end
    if type(root) ~= "table" or type(root.softreserves) ~= "table" or type(root.metadata) ~= "table" then
        return nil, "not a softres.it Gargul export (no softreserves/metadata)"
    end
    return root
end

function SRC.EncodeGargul(root)
    return Codec.Base64Encode(libDeflate():CompressZlib(Codec.JSONEncode(root)))
end

function SRC.FromGargul(root)
    local data = newData("gargul")
    data.raw = root

    local meta = root.metadata
    data.meta.id = str(meta.id) or (type(meta.id) == "number" and tostring(meta.id)) or nil
    data.meta.url = str(meta.url)
    data.meta.note = str(meta.note)
    if type(meta.instances) == "table" then
        for _, slug in ipairs(meta.instances) do
            if str(slug) then table.insert(data.meta.instances, slug) end
        end
    end

    for _, entry in ipairs(root.softreserves) do
        local name = type(entry) == "table" and str(entry.name)
        if name and SRC.Trim(name) ~= "" then
            local p = addPlayer(data, name, str(entry.class))
            local note = str(entry.note) and SRC.Trim(entry.note)
            if note and note ~= "" then p.note = note end
            if type(entry.items) == "table" then
                for pos, item in ipairs(entry.items) do
                    local id = tonumber(type(item) == "table" and item.id or item)
                    if id and id > 0 then
                        local order = tonumber(type(item) == "table" and item.order) or (pos - 1)
                        p.items[#p.items + 1] = { id = id, order = order, seq = #p.items + 1 }
                    end
                end
            end
        end
    end

    for _, p in ipairs(data.players) do sortItems(p.items) end
    return data
end

------------------------------------------------------------
-- softres.it CSV export: Item,ItemId,From,Name,...,Class,Spec,Note,Date,Plus
------------------------------------------------------------
function SRC.FromCSV(text)
    local rows = Codec.ParseCSV(text)
    local col = {}
    for i, h in ipairs(rows[1] or {}) do col[SRC.Trim(h)] = i end
    if not col.ItemId or not col.Name then
        return nil, "CSV must have ItemId and Name columns (use softres.it's CSV export)"
    end

    local data = newData("csv")
    for r = 2, #rows do
        local row = rows[r]
        local name = SRC.Trim(row[col.Name])
        if name ~= "" then
            local p = addPlayer(data, name, col.Class and row[col.Class], col.Spec and row[col.Spec])
            local note = col.Note and SRC.Trim(row[col.Note])
            if note and note ~= "" then p.note = note end
            local id = tonumber(row[col.ItemId])
            if id and id > 0 then
                p.items[#p.items + 1] = { id = id, order = #p.items, seq = #p.items + 1 }
            end
        end
    end
    if #data.players == 0 then return nil, "no soft-reserves found in the CSV" end
    return data
end

-- Accepts either format. Returns data or nil, err.
function SRC.ParseImport(text)
    text = SRC.Trim(text)
    if text == "" then return nil, "nothing to import" end
    -- A Gargul string is base64, so it never contains a comma.
    if text:find(",") then
        return SRC.FromCSV(text)
    end
    local root, err = SRC.DecodeGargul(text)
    if not root then return nil, err end
    return SRC.FromGargul(root)
end

------------------------------------------------------------
-- Session handling
------------------------------------------------------------
local function newSession(id)
    return { id = id, adj = {}, links = {}, excluded = {}, seen = {}, last = {}, states = {} }
end

-- quiet: don't print failures (the import dialog shows them itself).
function SRC:Import(text, quiet)
    local data, err = SRC.ParseImport(text)
    if not data then
        if not quiet then self:Print("|cffff4040Import failed:|r " .. err) end
        return false, err
    end

    local db = self.db
    local id = data.meta.id or "csv"
    local s = db.session
    local now = time()
    local kept = s and s.id == id and (now - (s.importedAt or 0)) < SRC.SESSION_MAX_AGE
    if not kept then
        s = newSession(id)
        db.session = s
    end
    s.importString = SRC.Trim(text)
    s.importedAt = now
    s.sentAt = nil

    self.data = data
    self:AfterLoad()
    self:AutoSelectProfile()

    do
        local count = 0
        for _, p in ipairs(data.players) do count = count + #p.items end
        self:Print(("imported %d soft-reserves from %d players (%s)%s."):format(
            count, #data.players, data.source == "csv" and "CSV" or "Gargul string",
            kept and ", kept earlier buff scans for this raid" or ""))
    end
    self:RefreshUI()
    return true
end

-- Work shared by a fresh import and a /reload restore.
function SRC:AfterLoad()
    for _, p in ipairs(self.data.players) do
        if p.specRole then
            self.db.specRoles[p.key] = { role = p.specRole, spec = p.spec }
        end
        for _, item in ipairs(p.items) do SRC.RequestItem(item.id) end
    end
end

function SRC:RestoreSession()
    local s = self.db.session
    if not s or not s.importString then return end
    local data = SRC.ParseImport(s.importString)
    if data then
        self.data = data
        self:AfterLoad()
    end
end

function SRC:ImportFromGargul()
    local meta = GargulDB and GargulDB.SoftRes and GargulDB.SoftRes.MetaData
    local text = meta and meta.importString
    if not text or text == "" then
        self:Print("Gargul has no softres.it import loaded (import it with |cffffff00/gl sr|r first).")
        return
    end
    self:Import(text)
end

------------------------------------------------------------
-- Corrected export
------------------------------------------------------------
local function deepCopy(v)
    if type(v) ~= "table" or v == Codec.null then return v end
    local copy = {}
    for k, val in pairs(v) do copy[k] = deepCopy(val) end
    return setmetatable(copy, getmetatable(v))
end

-- Gargul-format root for data that didn't come from a Gargul string (CSV).
local function synthesizeRoot(data)
    local softreserves = Codec.Array()
    for _, p in ipairs(data.players) do
        local items = Codec.Array()
        for _, item in ipairs(p.items) do
            items[#items + 1] = Codec.Object({ id = item.id, note = "", order = item.order })
        end
        softreserves[#softreserves + 1] = Codec.Object({
            name = p.name, class = p.classRaw or "priest", note = "", items = items,
        })
    end
    return Codec.Object({
        metadata = Codec.Object({
            id = "srcheck-" .. time(), url = "", hidden = false,
            instances = Codec.Array(deepCopy(data.meta.instances)),
            note = "Generated by SRCheck from a softres.it CSV export",
        }),
        softreserves = softreserves,
        hardreserves = Codec.Array(),
        bonusrolls = Codec.Array(),
    })
end

-- The items that would be dropped from a player with n too many SRs.
function SRC.ItemsToDrop(p, n)
    local out = {}
    for i = #p.items - n + 1, #p.items do
        if i >= 1 then out[#out + 1] = p.items[i] end
    end
    return out
end

-- drops: { [softres name key] = number of SRs to remove }.
-- Returns the Gargul string and the number of SRs removed.
function SRC:BuildCorrectedGargul(drops)
    local data = self.data
    local root = data.raw and deepCopy(data.raw) or synthesizeRoot(data)

    local removed = 0
    for key, n in pairs(drops) do
        -- Same ordering as FromGargul so we drop exactly the items shown in the UI.
        local list = {}
        for _, entry in ipairs(root.softreserves) do
            if type(entry) == "table" and str(entry.name) and SRC.NameKey(entry.name) == key
                and type(entry.items) == "table" then
                for pos, item in ipairs(entry.items) do
                    local id = tonumber(type(item) == "table" and item.id or item)
                    if id and id > 0 then
                        list[#list + 1] = {
                            entry = entry, pos = pos,
                            order = tonumber(type(item) == "table" and item.order) or (pos - 1),
                            seq = #list + 1,
                        }
                    end
                end
            end
        end
        sortItems(list)

        local doomed = {}
        for i = math.max(1, #list - n + 1), #list do
            local it = list[i]
            doomed[it.entry] = doomed[it.entry] or {}
            table.insert(doomed[it.entry], it.pos)
            removed = removed + 1
        end
        for entry, positions in pairs(doomed) do
            table.sort(positions, function(a, b) return a > b end)
            for _, pos in ipairs(positions) do table.remove(entry.items, pos) end
        end
    end

    return SRC.EncodeGargul(root), removed
end
