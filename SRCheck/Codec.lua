-- Codec: Base64, JSON and CSV helpers for reading/writing softres.it exports.
-- Pure Lua 5.1 (no WoW API) so it can be unit tested outside the game.
--
-- A softres.it "Gargul export" is base64( zlib( JSON ) ). zlib is handled by
-- LibDeflate; this file covers the other two layers plus the CSV export.

local _, SRC = ...

local Codec = {}
SRC.Codec = Codec

local floor, char, byte, concat = math.floor, string.char, string.byte, table.concat

------------------------------------------------------------
-- Base64 (standard alphabet, '=' padding)
------------------------------------------------------------
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local ENC, DEC = {}, {}
for i = 1, 64 do
    ENC[i - 1] = ALPHABET:sub(i, i)
    DEC[byte(ALPHABET, i)] = i - 1
end
DEC[byte("-")] = 62 -- tolerate the url-safe variant
DEC[byte("_")] = 63

function Codec.Base64Encode(s)
    local out, n = {}, 0
    for i = 1, #s, 3 do
        local a, b, c = byte(s, i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        n = n + 1
        out[n] = ENC[floor(v / 262144)]
            .. ENC[floor(v / 4096) % 64]
            .. (b and ENC[floor(v / 64) % 64] or "=")
            .. (c and ENC[v % 64] or "=")
    end
    return concat(out)
end

-- Ignores whitespace and padding. Returns nil, err on malformed input.
function Codec.Base64Decode(s)
    s = s:gsub("[%s=]", "")
    if s:find("[^%w%+/%-_]") then return nil, "invalid base64 character" end
    if #s % 4 == 1 then return nil, "invalid base64 length" end

    local out, n = {}, 0
    for i = 1, #s, 4 do
        local a, b, c, d = byte(s, i, i + 3)
        c = c and DEC[c]
        d = d and DEC[d]
        local v = DEC[a] * 262144 + DEC[b] * 4096 + (c or 0) * 64 + (d or 0)
        local b1, b2, b3 = floor(v / 65536), floor(v / 256) % 256, v % 256
        n = n + 1
        if d then
            out[n] = char(b1, b2, b3)
        elseif c then
            out[n] = char(b1, b2)
        else
            out[n] = char(b1)
        end
    end
    return concat(out)
end

------------------------------------------------------------
-- JSON
------------------------------------------------------------
-- Decoded arrays/objects carry a metatable so that re-encoding keeps "[]"
-- vs "{}" intact, and JSON null decodes to Codec.null so that it survives a
-- round trip (Gargul's export contains plenty of nulls).
local ARRAY_MT  = { __jsontype = "array" }
local OBJECT_MT = { __jsontype = "object" }

Codec.null = setmetatable({}, { __tostring = function() return "null" end })

function Codec.Array(t)  return setmetatable(t or {}, ARRAY_MT)  end
function Codec.Object(t) return setmetatable(t or {}, OBJECT_MT) end

local function jsonError(pos, msg)
    error(("JSON error at position %d: %s"):format(pos, msg), 0)
end

local function utf8char(cp)
    if cp < 0x80 then
        return char(cp)
    elseif cp < 0x800 then
        return char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return char(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return char(0xF0 + floor(cp / 0x40000), 0x80 + floor(cp / 0x1000) % 0x40,
        0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function skip(str, pos)
    return str:find("[^ \t\r\n]", pos) or (#str + 1)
end

local parseValue

local function parseString(str, pos)
    local buf, n, i = {}, 0, pos + 1
    while true do
        local j = str:find('["\\]', i)
        if not j then jsonError(pos, "unterminated string") end
        if j > i then
            n = n + 1
            buf[n] = str:sub(i, j - 1)
        end
        if str:sub(j, j) == '"' then
            return concat(buf), j + 1
        end
        local e = str:sub(j + 1, j + 1)
        if e == "u" then
            local cp = tonumber(str:sub(j + 2, j + 5), 16)
            if not cp then jsonError(j, "bad unicode escape") end
            i = j + 6
            if cp >= 0xD800 and cp <= 0xDBFF and str:sub(i, i + 1) == "\\u" then
                local lo = tonumber(str:sub(i + 2, i + 5), 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    i = i + 6
                end
            end
            n = n + 1
            buf[n] = utf8char(cp)
        else
            local r = ESCAPES[e]
            if not r then jsonError(j, "bad escape") end
            n = n + 1
            buf[n] = r
            i = j + 2
        end
    end
end

local function parseArray(str, pos)
    local arr, n = Codec.Array(), 0
    pos = skip(str, pos + 1)
    if str:sub(pos, pos) == "]" then return arr, pos + 1 end
    while true do
        local v
        v, pos = parseValue(str, pos)
        n = n + 1
        arr[n] = v
        pos = skip(str, pos)
        local c = str:sub(pos, pos)
        if c == "]" then return arr, pos + 1 end
        if c ~= "," then jsonError(pos, "expected ',' or ']'") end
        pos = skip(str, pos + 1)
    end
end

local function parseObject(str, pos)
    local obj = Codec.Object()
    pos = skip(str, pos + 1)
    if str:sub(pos, pos) == "}" then return obj, pos + 1 end
    while true do
        if str:sub(pos, pos) ~= '"' then jsonError(pos, "expected string key") end
        local k
        k, pos = parseString(str, pos)
        pos = skip(str, pos)
        if str:sub(pos, pos) ~= ":" then jsonError(pos, "expected ':'") end
        local v
        v, pos = parseValue(str, skip(str, pos + 1))
        obj[k] = v
        pos = skip(str, pos)
        local c = str:sub(pos, pos)
        if c == "}" then return obj, pos + 1 end
        if c ~= "," then jsonError(pos, "expected ',' or '}'") end
        pos = skip(str, pos + 1)
    end
end

parseValue = function(str, pos)
    pos = skip(str, pos)
    local c = str:sub(pos, pos)
    if c == "{" then return parseObject(str, pos) end
    if c == "[" then return parseArray(str, pos) end
    if c == '"' then return parseString(str, pos) end
    if str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
    if str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
    if str:sub(pos, pos + 3) == "null" then return Codec.null, pos + 4 end
    local num = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
    if num and tonumber(num) then return tonumber(num), pos + #num end
    jsonError(pos, "unexpected character '" .. c .. "'")
end

-- Returns value or nil, err.
function Codec.JSONDecode(str)
    local ok, value, pos = pcall(parseValue, str, 1)
    if not ok then return nil, value end
    if skip(str, pos) <= #str then return nil, "trailing characters after JSON" end
    return value
end

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return ("\\u%04x"):format(byte(c))
    end) .. '"'
end

local function isSequence(t)
    local n = #t
    if n == 0 then return false end
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return false end
    end
    return true
end

local encodeValue

local function encodeTable(t, out)
    local mt = getmetatable(t)
    local asArray
    if mt == ARRAY_MT then
        asArray = true
    elseif mt == OBJECT_MT then
        asArray = false
    else
        asArray = next(t) == nil or isSequence(t)
    end

    if asArray then
        out[#out + 1] = "["
        for i = 1, #t do
            if i > 1 then out[#out + 1] = "," end
            encodeValue(t[i], out)
        end
        out[#out + 1] = "]"
        return
    end

    -- Sorted keys keep the output deterministic.
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    out[#out + 1] = "{"
    for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = "," end
        out[#out + 1] = encodeString(k)
        out[#out + 1] = ":"
        local v = t[k]
        if v == nil then v = t[tonumber(k)] end
        encodeValue(v, out)
    end
    out[#out + 1] = "}"
end

encodeValue = function(v, out)
    local tv = type(v)
    if v == nil or v == Codec.null then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v % 1 == 0 and v > -1e15 and v < 1e15 then
            out[#out + 1] = ("%d"):format(v)
        else
            out[#out + 1] = ("%.14g"):format(v)
        end
    elseif tv == "string" then
        out[#out + 1] = encodeString(v)
    elseif tv == "table" then
        encodeTable(v, out)
    else
        error("cannot encode " .. tv .. " as JSON")
    end
end

function Codec.JSONEncode(value)
    local out = {}
    encodeValue(value, out)
    return concat(out)
end

------------------------------------------------------------
-- CSV (RFC 4180-ish: quoted fields, "" escapes, CRLF or LF)
------------------------------------------------------------
function Codec.ParseCSV(text)
    local rows, row, field = {}, {}, {}
    local i, len, inQuotes = 1, #text, false

    local function endField()
        row[#row + 1] = concat(field)
        field = {}
    end
    local function endRow()
        endField()
        if #row > 1 or row[1] ~= "" then rows[#rows + 1] = row end
        row = {}
    end

    while i <= len do
        local c = text:sub(i, i)
        if inQuotes then
            if c == '"' then
                if text:sub(i + 1, i + 1) == '"' then
                    field[#field + 1] = '"'
                    i = i + 1
                else
                    inQuotes = false
                end
            else
                field[#field + 1] = c
            end
        elseif c == '"' then
            inQuotes = true
        elseif c == "," then
            endField()
        elseif c == "\n" then
            endRow()
        elseif c ~= "\r" then
            field[#field + 1] = c
        end
        i = i + 1
    end
    if #field > 0 or #row > 0 then endRow() end
    return rows
end
