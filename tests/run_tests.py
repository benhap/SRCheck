#!/usr/bin/env python3
"""Offline tests for SRCheck's logic (import, corrected export, evaluation).

Runs the addon's Lua files under Lua 5.1 via lupa with WoW API stubs.

    python3 -m venv .venv && .venv/bin/pip install lupa
    .venv/bin/python tests/run_tests.py

If a real softres.it import is present in Gargul's SavedVariables it is also
round-tripped (pass its path as the first argument to override).
"""
import base64
import glob
import json
import os
import re
import sys
import zlib

from lupa import lua51

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON = os.path.join(ROOT, "SRCheck")
LOGIC_FILES = [
    "Libs/LibStub/LibStub.lua",
    "Libs/LibDeflate/LibDeflate.lua",
    "Codec.lua",
    "Data.lua",
    "Core.lua",
    "Import.lua",
    "Verify.lua",
]

failures = 0


def check(cond, msg):
    global failures
    if cond:
        print("  ok   " + msg)
    else:
        failures += 1
        print("  FAIL " + msg)


def gargul_encode(obj):
    return base64.b64encode(zlib.compress(json.dumps(obj).encode())).decode()


def gargul_decode(s):
    return json.loads(zlib.decompress(base64.b64decode(s)))


def toc_files():
    files = []
    for line in open(os.path.join(ADDON, "SRCheck.toc"), encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#"):
            files.append(line.replace("\\", "/"))
    return files


def new_runtime(ui=False, generic=True, seed=None):
    """ui=False: logic files only, UI calls stubbed. ui=True: every TOC file with frame stubs.
    generic=True: activate a basic profile (base 1/2/2, 3 WB +1, Flask +1) as profiles[1]."""
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(open(os.path.join(ROOT, "tests", "wowstub.lua"), encoding="utf-8").read())
    if ui:
        lua.execute(open(os.path.join(ROOT, "tests", "uistub.lua"), encoding="utf-8").read())
    ns = lua.table()
    load = lua.eval("function(code, name, ns) return assert(loadstring(code, '@' .. name))('SRCheck', ns) end")
    for f in (toc_files() if ui else LOGIC_FILES):
        load(open(os.path.join(ADDON, f), encoding="utf-8").read(), f, ns)
    lua.execute(seed or "SRCheckDB = nil")
    if not ui:
        lua.eval("function(ns) ns.RefreshUI = function() end; ns.ShowText = function(self, t, text, hint) ns._shown = { t, text, hint } end end")(ns)
    ns.InitDB(ns)
    if generic:
        lua.eval("""function(ns)
            table.insert(SRCheckDB.profiles, 1, ns:BaseProfile("Generic"))
            SRCheckDB.activeProfile = "Generic"
        end""")(ns)
    return lua, ns


def set_raid(lua, members):
    lua.execute("TEST.raid = {}")
    add = lua.eval("function(t) table.insert(TEST.raid, t) end")
    def conv(v):
        if isinstance(v, list):
            t = lua.table()
            for i, x in enumerate(v, 1):
                if x is not None:
                    t[i] = conv(x)
            return t
        return v
    for m in members:
        t = lua.table()
        for k, v in m.items():
            t[k] = conv(v)
        add(t)


WB = [22888, 24425, 16609, 15366, 22817, 22818, 22820, 23768]
TITANS = 17626

FIXTURE = {
    "metadata": {"id": "TEST1234", "url": "https://softres.it/raid/TEST1234", "instances": ["mc"],
                 "hidden": False, "raidStartsAt": None, "note": "line1\nline2 \"quoted\" é",
                 "bonusrolls_consumed_on_use": False},
    "softreserves": [
        {"name": "Tanky", "class": "warrior", "note": None,
         "items": [{"id": 19348, "note": "", "order": 0}, {"id": 19349, "note": "", "order": 1},
                   {"id": 19350, "note": "", "order": 2}, {"id": 19351, "note": "", "order": 3}]},
        {"name": "Healz", "class": "priest", "note": None,
         "items": [{"id": 1, "note": "", "order": 0}, {"id": 2, "note": "", "order": 1},
                   {"id": 3, "note": "", "order": 2}, {"id": 4, "note": "", "order": 3}]},
        {"name": "Aglaée", "class": "hunter", "note": None,  # in game: Aglaee (accents)
         "items": [{"id": 10, "note": "", "order": 0}, {"id": 10, "note": "", "order": 1},
                   {"id": 10, "note": "", "order": 2}]},
        {"name": "Stabby", "class": "rogue", "note": None,  # placed out of order: order 2 is last
         "items": [{"id": 30, "note": "", "order": 2}, {"id": 31, "note": "", "order": 0},
                   {"id": 32, "note": "", "order": 1}]},
        {"name": "Faraway", "class": "mage", "note": None,
         "items": [{"id": 40, "note": "", "order": 0}, {"id": 41, "note": "", "order": 1},
                   {"id": 42, "note": "", "order": 2}]},
        {"name": "Greedy", "class": "warlock", "note": None,
         "items": [{"id": 50 + i, "note": "", "order": i} for i in range(5)]},
        {"name": "Absentee", "class": "druid", "note": None, "items": [{"id": 60, "note": "", "order": 0}]},
        {"name": "Nobody", "class": "paladin", "note": None, "items": []},
    ],
    "hardreserves": [],
    "bonusrolls": [],
}


def test_codec(lua, ns):
    print("codec")
    codec = ns.Codec
    for s in ["", "a", "ab", "abc", "abcd", "hello world", "éè"]:
        enc = codec.Base64Encode(s)
        check(enc == base64.b64encode(s.encode()).decode(), "base64 encode %r" % s)
        check(codec.Base64Decode(enc) == s, "base64 decode %r" % s)
    js = '{"a":[1,2.5,-3e2],"b":null,"c":"x\\u00e9\\ud83d\\ude00\\n","d":{},"e":[],"f":true}'
    val = codec.JSONDecode(js)
    check(val.c == "xé\U0001F600\n", "json unicode + surrogate escapes")
    out = codec.JSONEncode(val)
    check(json.loads(out) == json.loads(js), "json round trip keeps null/[]/{} " + out)
    bad = codec.JSONDecode("{\"a\":}")
    check(bad[0] is None, "json error reported")
    rows = codec.ParseCSV('A,B,C\r\n"x, y",2,"he said ""hi"""\r\n\r\nz,,\n')
    check(rows[2][1] == "x, y" and rows[2][3] == 'he said "hi"' and rows[3][2] == "", "csv quoting")


def test_names(lua, ns):
    print("names")
    check(ns.NameKey("Aglaée-Firemaw") == "aglaée", "NameKey strips realm, lowercases")
    check(ns.NameKey("ÉLÉONORE") == "éléonore", "NameKey lowercases Latin-1 capitals")
    check(ns.FoldName("gustäv") == "gustav", "FoldName folds accents")
    check(ns.Levenshtein("jorrmungand", "jormungand", 2) == 1, "Levenshtein")
    check(ns.Levenshtein("abc", "xyzabc", 2) == 3, "Levenshtein gives up past limit")


def test_conditions(lua, ns):
    print("conditions")
    opts, err = ns.ParseCondition("6 WB or 3x WB + Flask")
    check(err is None and len(opts) == 2, "two alternatives")
    check(opts[1][1].n == 6 and opts[1][1].group == "wb", "6 WB")
    check(opts[2][1].n == 3 and opts[2][2].n == 1 and opts[2][2].group == "flask", "3x WB + Flask")
    opts, err = ns.ParseCondition("2 World Buffs AND Flask | 1 Elixir")
    check(len(opts) == 2 and opts[1][1].group == "world buffs" and opts[2][1].group == "elixir",
          "multi-word groups, AND, |")
    _, err = ns.ParseCondition("  ")
    check(err is not None, "empty condition is an error")


def test_import_and_evaluate(lua, ns):
    print("import + evaluate")
    s = gargul_encode(FIXTURE)
    ok = ns.Import(ns, s)
    check(ok is True, "import ok")
    data = ns.data
    check(len(data.players) == 8 and data.meta.id == "TEST1234" and data.meta.instances[1] == "mc", "players/meta")
    stabby = data.byKey["stabby"]
    check([stabby["items"][i].id for i in (1, 2, 3)] == [31, 32, 30], "items sorted by softres order")

    ns.SetRole(ns, "tanky", "TANK")
    ns.SetRole(ns, "healz", "HEALER")
    set_raid(lua, [
        {"name": "Tanky", "class": "WARRIOR", "buffs": WB[:3] + [TITANS]},           # 2+2 = 4, has 4 -> OK
        {"name": "Healz", "class": "PRIEST", "buffs": WB[:3]},                        # 2+1 = 3, has 4 -> -1
        {"name": "Aglaee", "class": "HUNTER", "buffs": WB[:2] + [TITANS]},            # 1+1 = 2, has 3 -> -1
        {"name": "Stabby", "class": "ROGUE", "buffs": []},                            # 1, has 3 -> -2
        {"name": "Faraway", "class": "MAGE", "visible": False},                       # 1..3, has 3 -> unknown
        {"name": "Greedy", "class": "WARLOCK", "visible": False},                     # max 3, has 5 -> -2 anyway
        {"name": "Nobody", "class": "PALADIN", "buffs": [TITANS]},                    # 0 SR
        {"name": "Lateguy", "class": "SHAMAN", "buffs": WB[:3] + [TITANS]},           # no SR entry
    ])
    ns.Scan(ns, True)
    rows, summary = ns.Evaluate(ns)
    by = {rows[i].key: rows[i] for i in range(1, len(rows) + 1)}

    check(by["tanky"].status == "OK" and by["tanky"].maxAllowed == 4, "tank with 3 WB + flask: 4 allowed, OK")
    check(by["healz"].status == "OVER" and by["healz"].deduct == 1, "healer without flask: deduct 1")
    check(ns.MissingText(by["healz"]) == "Flask missing", "missing text: " + ns.MissingText(by["healz"]))
    check(by["aglaee"].status == "OVER" and by["aglaee"].deduct == 1 and by["aglaee"].linkKind == "accents",
          "accent-folded name match, 2 WB: deduct 1")
    check(ns.MissingText(by["aglaee"]) == "WB 2/3", "missing text: " + ns.MissingText(by["aglaee"]))
    check(by["stabby"].status == "OVER" and by["stabby"].deduct == 2, "no buffs: deduct 2")
    check(by["faraway"].status == "UNKNOWN" and ns.AllowedText(by["faraway"]) == "1-3", "out of range: not verified")
    check(by["greedy"].status == "OVER" and by["greedy"].deduct == 2, "over the max even if unscanned")
    check(by["absentee"].status == "ABSENT", "softres player not in raid")
    check(by["nobody"].status == "UNDER", "registered but reserved nothing: can add")
    check(by["lateguy"].status == "NOSR", "raider without softres entry")
    check(rows[1].status == "OVER", "deductions sorted first")
    check(summary.OVER == 4 and summary.deduct == 6, "summary counts")

    # Sticky: Healz drinks a flask later, Aglaee is now out of range -> earlier scan still counts.
    lua.eval("function() TEST.raid[2].buffs = {22888, 24425, 16609, 17626}; TEST.raid[3].visible = false end")()
    ns.Scan(ns, True)
    rows, summary = ns.Evaluate(ns)
    by = {rows[i].key: rows[i] for i in range(1, len(rows) + 1)}
    check(by["healz"].status == "OK", "later scan picks up the flask")
    check(by["aglaee"].status == "OVER", "sticky: earlier scan kept when out of range")

    # Manual adjustment
    ns.SetAdjustment(ns, "stabby", 2)
    rows, _ = ns.Evaluate(ns)
    by = {rows[i].key: rows[i] for i in range(1, len(rows) + 1)}
    check(by["stabby"].status == "OK", "manual +2 adjustment")
    ns.SetAdjustment(ns, "stabby", 0)

    # Excluded from the check (unboons later): never deducted, SRs kept in the corrected string.
    ns.SetExcluded(ns, "stabby", True)
    by, summary = evaluate(ns)
    check(by["stabby"].status == "SKIPPED" and by["stabby"].deduct is None and by["stabby"].wouldDeduct == 2,
          "excluded player: not checked, would be -2")
    drops, _ = ns.CollectDrops(ns)
    check(drops["stabby"] is None and summary.SKIPPED == 1 and summary.deduct == 3, "excluded player not in drops/summary")
    text, _ = ns.BuildCorrectedGargul(ns, drops)
    check(len([e for e in gargul_decode(text)["softreserves"] if e["name"] == "Stabby"][0]["items"]) == 3,
          "excluded player keeps all SRs in the corrected string")
    check("excluded from the check (currently -2" in ns.BuildReport(ns), "report lists excluded player")
    lua.eval("SlashCmdList.SRCHECK")("include all")
    by, _ = evaluate(ns)
    check(by["stabby"].status == "OVER", "/src include all puts them back in the check")
    lua.eval("SlashCmdList.SRCHECK")("exclude Stabby")
    check(evaluate(ns)[0]["stabby"].status == "SKIPPED", "/src exclude <name>")
    lua.eval("SlashCmdList.SRCHECK")("include Stabby")

    # OR-rule from the guild: "6 WB or 3 WB + Flask" -> +1
    prof = ns.GetProfile(ns)
    add_rule = lua.eval("""function(p) table.insert(p.rules, { name = "Buffed", condition = "6 WB or 3 WB + Flask",
        bonus = 1, enabled = true, roles = { DPS = true, TANK = true, HEALER = true } }) end""")
    add_rule(prof)
    rows, _ = ns.Evaluate(ns)
    by = {rows[i].key: rows[i] for i in range(1, len(rows) + 1)}
    check(by["tanky"].maxAllowed == 5, "3 WB + flask satisfies the OR rule")
    check(ns.MissingText(by["stabby"]) == "WB 0/3, Flask missing, Buffed: WB 0/6 or WB 0/3 + Flask 0/1",
          "OR rule shortfall text: " + ns.MissingText(by["stabby"]))
    lua.eval("function(p) table.remove(p.rules) end")(prof)

    # Corrected export
    drops, summary = ns.CollectDrops(ns)
    text, removed = ns.BuildCorrectedGargul(ns, drops)
    out = gargul_decode(text)
    check(removed == summary.deduct, "removed count matches deductions (%d)" % removed)
    names = {e["name"]: e for e in out["softreserves"]}
    check([i["id"] for i in names["Stabby"]["items"]] == [31], "Stabby keeps only the first-ordered SR")
    check([i["id"] for i in names["Greedy"]["items"]] == [50, 51, 52], "Greedy trimmed to 3")
    check(len(names["Aglaée"]["items"]) == 2, "Aglaee trimmed to 2")
    check(len(names["Tanky"]["items"]) == 4 and len(names["Faraway"]["items"]) == 3, "others untouched")
    check(out["metadata"] == FIXTURE["metadata"], "metadata preserved (nulls, unicode, newlines)")
    check(out["hardreserves"] == [] and out["bonusrolls"] == [], "empty arrays stay arrays")
    check(names["Tanky"]["note"] is None, "null player note preserved")
    check(len(ns.data.byKey["stabby"]["items"]) == 3, "original data not modified")

    # Report / announce smoke tests
    report = ns.BuildReport(ns)
    check("DEDUCT" in report and "Stabby" in report, "report text")
    lua.execute("TEST.sent = {}")
    ns.Announce(ns)
    sent = lua.eval("TEST.sent")
    check(len(sent) >= 1 and "SR deductions" in sent[1].msg and sent[1].channel == "RAID",
          "announce: " + (sent[1].msg if len(sent) else ""))


def test_csv(lua, ns):
    print("csv")
    csv = ("Item,ItemId,From,Name,DiscordId,DiscordUsername,Class,Spec,Note,Date,Plus\n"
           '"Some Item",100,"Boss",Shieldy,1,u,Warrior,Protection,,"2026-10-27 16:30:53",0\n'
           '"Other, Item",101,"Boss",Shieldy,1,u,Warrior,Protection,,"2026-10-27 16:30:53",0\n'
           '"Thing",102,"Boss",Leafy,2,v,Druid,Restoration,,"2026-10-27 16:30:53",0\n'
           '"Thing",103,"Boss",Kitty,3,w,Druid,Feral,,"2026-10-27 16:30:53",0\n')
    ok = ns.Import(ns, csv)
    check(ok is True and ns.data.source == "csv", "csv import")
    check(len(ns.data.byKey["shieldy"]["items"]) == 2, "csv items grouped per player")
    role, src = ns.ResolveRole(ns, "shieldy", ns.data.byKey["shieldy"], None)
    check(role == "TANK" and "Protection" in src, "Protection Warrior -> Tank")
    check(ns.data.byKey["leafy"].specRole == "HEALER" and ns.data.byKey["kitty"].specRole == "DPS", "spec roles")
    check(lua.eval("SRCheckDB.specRoles.shieldy.role") == "TANK", "spec role remembered for later Gargul imports")
    text, removed = ns.BuildCorrectedGargul(ns, lua.table_from({"shieldy": 1}))
    out = gargul_decode(text)
    check(removed == 1 and out["metadata"]["id"].startswith("srcheck-"), "csv -> synthesized gargul string")
    check([i["id"] for i in out["softreserves"][0]["items"]] == [100], "csv drop keeps first SR")


def test_ui(lua, ns):
    print("ui smoke test")
    ns.Import(ns, gargul_encode(FIXTURE))
    set_raid(lua, [
        {"name": "Tanky", "class": "WARRIOR", "buffs": WB[:3] + [TITANS], "raidRole": "MAINTANK"},
        {"name": "Aglaee", "class": "HUNTER", "buffs": WB[:2]},
        {"name": "Faraway", "class": "MAGE", "visible": False},
        {"name": "Lateguy", "class": "SHAMAN", "buffs": []},
    ])
    ns.Scan(ns, True)
    ns.ToggleUI(ns)
    main = ns.main
    check(main.IsShown(main), "main window opens")
    rows = main.rows
    visible = [rows[i] for i in range(1, len(rows) + 1) if rows[i].shown]
    check(len(visible) == 9, "one row per softres player + raider without SR (%d)" % len(visible))
    first = visible[0]
    check("DEDUCT" in first.status.text_, "first row is a deduction: " + first.status.text_)
    check("WB 2/3" in first.rules.text_, "compliance cell: " + first.rules.text_)
    check("Tank" in [r.role.text.text_ for r in visible if r.data.key == "tanky"][0], "MT flag -> Tank role")

    first.Fire(first, "OnEnter")
    tip = "\n".join(lua.eval("TEST.tooltip").values())
    check("Allowed" in tip and "dropped" in tip and "WB: 2" in tip, "row tooltip:\n    " + tip.replace("\n", "\n    "))

    # Role menu: pick Tank (all raids), then back to Auto.
    def pick(row, text):
        row.role.Fire(row.role, "OnClick", "LeftButton")
        buttons = [b for b in ns.menu.buttons.values() if b.shown]
        labels = [b.text.text_ for b in buttons]
        hit = [b for b in buttons if text in b.text.text_]
        check(len(hit) == 1, "menu has '%s': %s" % (text, labels))
        hit[0].Fire(hit[0], "OnClick")
        return [r for r in main.rows.values() if r.shown and r.data.key == row.data.key][0]
    first = pick(first, "Tank")
    check(lua.eval("SRCheckDB.roles.aglaee") == "TANK" and "Tank*" in first.role.text.text_, "menu sets manual Tank")
    first = pick(first, "Auto:")
    check(lua.eval("SRCheckDB.roles.aglaee") is None, "menu back to auto")
    lua.eval("""function(ns) table.insert(ns:GetProfile().assignments, { name = "Pull Hunter", role = "TANK" }) end""")(ns)
    first = pick(first, "Pull Hunter")
    check(lua.eval("SRCheckDB.profiles[1].assigned.aglaee") == "Pull Hunter" and "Pull Hunter" in first.role.text.text_
          and first.data.maxAllowed == 2, "menu assigns Pull Hunter (Tank base 2, WB and flask unmet)")
    first = pick(first, "Auto:")
    check(lua.eval("SRCheckDB.profiles[1].assigned.aglaee") is None, "auto clears the assignment")
    ag = [r for r in main.rows.values() if r.shown and r.data.key == "aglaee"][0]
    ag.adj.Fire(ag.adj, "OnClick", "LeftButton")
    check(lua.eval("SRCheckDB.session.adj.aglaee") == 1, "adj click +1")

    # Include checkbox: untick a row, then the header ticks everyone back in.
    ag.check.checked = False
    ag.check.Fire(ag.check, "OnClick")
    check(lua.eval("SRCheckDB.session.excluded.aglaee") is True, "row checkbox excludes the player")
    ag = [r for r in main.rows.values() if r.shown and r.data.key == "aglaee"][0]
    check("Not checked" in ag.status.text_ and ag.check.checked is False and main.includeAll.checked is False,
          "excluded row shows 'Not checked': " + ag.status.text_)
    ag.Fire(ag, "OnEnter")
    check("Excluded from the check" in "\n".join(lua.eval("TEST.tooltip").values()), "excluded row tooltip")
    main.includeAll.checked = True
    main.includeAll.Fire(main.includeAll, "OnClick")
    check(lua.eval("next(SRCheckDB.session.excluded)") is None and main.includeAll.checked is True,
          "header checkbox includes everyone")
    # "Check now" row: one checkbox per buff group; unticking puts it on hold.
    checks = [c for c in main.ruleChecks.values() if c.shown]
    check([c.label.text_ for c in checks] == ["WB", "Flask"], "one 'check now' box per buff group")
    checks[0].checked = False
    checks[0].Fire(checks[0], "OnClick")
    check(lua.eval("SRCheckDB.session.heldGroups.wb") is True, "unticking puts the group on hold")
    ag = [r for r in main.rows.values() if r.shown and r.data.key == "aglaee"][0]
    check("|cff8f8f8fWB 2/3|r" in ag.rules.text_ and ag.data.status == "PENDING",
          "rule waiting for a held group greyed, player pending: " + ag.rules.text_)
    ag.Fire(ag, "OnEnter")
    check("waiting for WB" in "\n".join(lua.eval("TEST.tooltip").values()), "tooltip says what it waits for")
    checks[0].checked = True
    checks[0].Fire(checks[0], "OnClick")
    check(lua.eval("SRCheckDB.session.heldGroups.wb") is None, "ticking checks it again")

    nosr = [r for r in main.rows.values() if r.shown and r.data.key == "lateguy"][0]
    check(nosr.check.shown is False, "no checkbox for raiders without SR")

    lua.eval("function(ns) ns.main.problems.checked = true; ns.main.problems:Fire('OnClick') end")(ns)
    shown = [r for r in main.rows.values() if r.shown]
    check(all(r.data.status in ("OVER", "UNKNOWN", "ABSENT") for r in shown), "problems-only filter")

    # Options: edit a rule condition through its edit box.
    ns.ToggleOptions(ns)
    opt = ns.options
    check(opt.profName.text_ == "Generic", "options shows profile")
    cond = opt.rules[1].condition
    check(cond.text_ == "3 WB", "rule 1 condition shown")
    lua.eval("""function(eb) eb:SetFocus(); eb:SetText("6 WB or 3 WB + Flask"); eb:ClearFocus() end""")(cond)
    check(lua.eval("SRCheckDB.profiles[1].rules[1].condition") == "6 WB or 3 WB + Flask", "condition committed")
    lua.eval("""function(eb) eb:SetFocus(); eb:SetText("6 Wb or 3 Bogus"); eb:ClearFocus() end""")(cond)
    check("invalid" in opt.rules[1].err.text_, "unknown group flagged")
    lua.eval("""function(eb) eb:SetFocus(); eb:SetText("3 WB"); eb:ClearFocus() end""")(cond)
    opt.addRule.Fire(opt.addRule, "OnClick")
    check(lua.eval("#SRCheckDB.profiles[1].rules") == 3, "+ Rule adds a rule")
    opt.rules[3]["del"].Fire(opt.rules[3]["del"], "OnClick")
    check(lua.eval("#SRCheckDB.profiles[1].rules") == 2, "X deletes it")
    spells = opt.groups[1].spells
    spells.Fire(spells, "OnEnter")
    check("Spell 22888" in "\n".join(lua.eval("TEST.tooltip").values()), "spell list tooltip resolves ids")

    # Dialogs
    ns.ShowImport(ns)
    check(ns.importFrame.IsShown(ns.importFrame), "import dialog")
    ns.ShowReport(ns)
    check("SRCheck" in ns.textFrame.edit.text_, "report dialog")
    ns.ShowCorrected(ns)
    corrected = ns.textFrame.edit.text_
    check(len(gargul_decode(corrected)["softreserves"]) == 8, "corrected string dialog")

    # Send to Gargul (fake Gargul API)
    lua.execute("Gargul = { SoftRes = { import = function(self, s, open) TEST.gargul = s; return true end } }")
    ns.SendToGargul(ns)
    check(lua.eval("TEST.popup.name") == "SRCHECK_SEND_GARGUL", "send asks for confirmation")
    lua.eval("StaticPopupDialogs.SRCHECK_SEND_GARGUL.OnAccept")()
    check(lua.eval("TEST.gargul") == corrected, "confirmed send imports the corrected string into Gargul")


def sr(name, cls, n, first_id=100):
    return {"name": name, "class": cls, "note": None,
            "items": [{"id": first_id + i, "note": "", "order": i} for i in range(n)]}


def evaluate(ns):
    rows, summary = ns.Evaluate(ns)
    return {rows[i].key: rows[i] for i in range(1, len(rows) + 1)}, summary


def raid_fixture(instance, players):
    return {"metadata": {"id": "R-" + instance, "instances": [instance]},
            "softreserves": players, "hardreserves": [], "bonusrolls": []}


def test_presets():
    print("preset profiles")
    # Migration: an install that already has its own profile gets the presets added once.
    lua, ns = new_runtime(generic=False, seed="""SRCheckDB = { profiles = { { name = "Default",
        base = { DPS = 1, TANK = 1, HEALER = 1 }, groups = {}, rules = {} } }, activeProfile = "Default" }""")
    names = lambda: [lua.eval("SRCheckDB.profiles")[i].name for i in range(1, lua.eval("#SRCheckDB.profiles") + 1)]
    check(names() == ["Default", "BWL", "AQ40", "Test"], "presets added after existing profile: %s" % names())
    ns.InitDB(ns)
    check(len(names()) == 4, "presets not duplicated on next login")
    check(lua.eval("SRCheckDB.activeProfile") == "Default", "active profile untouched")
    check(lua.eval("SRCheckDB.instanceProfile.bwl") == "BWL" and lua.eval("SRCheckDB.instanceProfile.aq40") == "AQ40",
          "bwl/aq40 auto-select their presets")

    # Old AQ40 presets ("required, else 0 SR": one rule or split in two) become base + 1.
    for old in ('{ { name = "6 WB + Flask", condition = "6 WB + Flask", required = true, bonus = 0 } }',
                '{ { name = "6 WB", condition = "6 WB", required = true, bonus = 0 },'
                ' { name = "Flask", condition = "Flask", required = true, bonus = 0 } }'):
        lua, ns = new_runtime(generic=False, seed="""SRCheckDB = { presetsVersion = 4, profiles = {
            { name = "AQ40", base = { DPS = 3, TANK = 4, HEALER = 4 }, groups = {}, rules = %s },
            { name = "Mine", base = {}, groups = {}, rules = %s } } }""" % (old, old))
        aq = lua.eval("SRCheckDB.profiles[1].rules")
        check(len(aq) == 1 and aq[1].condition == "6 WB + Flask" and aq[1].bonus == 1 and not aq[1].required,
              "old AQ40 preset -> +1 for 6 WB + Flask")
        check(lua.eval("SRCheckDB.profiles[2].rules[1].required") is True, "other profiles untouched")

    lua, ns = new_runtime(generic=False)
    check(names() == ["BWL", "AQ40", "Test"], "fresh install: presets only")
    ALL5 = WB[:5] + [TITANS]
    ALL6 = WB[:6] + [TITANS]

    # ---- BWL: 2 SR DPS / 3 SR tank, heal, pull hunter, mage tank; +1 for 5 WB, +1 for flask
    ns.Import(ns, gargul_encode(raid_fixture("bwl", [
        sr("Rogue", "rogue", 4), sr("Mage", "mage", 4), sr("Tanky", "warrior", 5), sr("Huntard", "hunter", 3),
        sr("Frosty", "mage", 5), sr("Locky", "warlock", 3)])))
    check(ns.GetProfile(ns).name == "BWL", "bwl raid auto-selects BWL")
    ns.SetRole(ns, "tanky", "TANK")
    lua.eval("SlashCmdList.SRCHECK")("role Huntard pull hunter")
    lua.eval("SlashCmdList.SRCHECK")("role Frosty Mage Tank")
    check(lua.eval("SRCheckDB.profiles[1].assigned.huntard") == "Pull Hunter", "/src role ... pull hunter")
    set_raid(lua, [
        {"name": "Rogue", "class": "ROGUE", "buffs": ALL5},
        {"name": "Mage", "class": "MAGE", "buffs": WB[:4] + [TITANS]},
        {"name": "Tanky", "class": "WARRIOR", "buffs": ALL5},
        {"name": "Huntard", "class": "HUNTER", "buffs": []},
        {"name": "Frosty", "class": "MAGE", "buffs": ALL5},
        {"name": "Locky", "class": "WARLOCK", "buffs": WB[:2]},
    ])
    ns.Scan(ns, True)
    by, _ = evaluate(ns)
    check(by["rogue"].status == "OK" and by["rogue"].maxAllowed == 4, "BWL DPS 5 WB + flask: 4")
    check(by["mage"].deduct == 1 and ns.MissingText(by["mage"]) == "WB 4/5", "BWL DPS 4 WB + flask: 3, " + ns.MissingText(by["mage"]))
    check(by["tanky"].status == "OK" and by["tanky"].maxAllowed == 5, "BWL tank 5 WB + flask: 5")
    check(by["huntard"].status == "OK" and by["huntard"].maxAllowed == 3 and by["huntard"].roleLabel == "Pull Hunter",
          "BWL pull hunter without buffs: 3")
    check(by["frosty"].status == "OK" and by["frosty"].maxAllowed == 5, "BWL mage tank 5 WB + flask: 5")
    check(by["locky"].deduct == 1 and ns.MissingText(by["locky"]) == "WB 2/5, Flask missing", "BWL DPS unbuffed: 2")

    # ---- AQ40: 3 SR DPS / 4 SR tank, heal, pull hunter, warlock tank; +1 for 6 WB + flask
    ns.Import(ns, gargul_encode(raid_fixture("aq40", [
        sr("Rogue", "rogue", 4), sr("Mage", "mage", 4), sr("Huntard", "hunter", 5), sr("Tanky", "warrior", 5),
        sr("Locky", "warlock", 5), sr("Faraway", "mage", 4), sr("Greedy", "rogue", 5), sr("Basic", "priest", 3)])))
    check(ns.GetProfile(ns).name == "AQ40", "aq40 raid auto-selects AQ40")
    lua.eval("SlashCmdList.SRCHECK")("role Locky warlock tank")
    lua.eval("SlashCmdList.SRCHECK")("role Huntard pull hunter")
    set_raid(lua, [
        {"name": "Rogue", "class": "ROGUE", "buffs": ALL6},
        {"name": "Mage", "class": "MAGE", "buffs": ALL5},
        {"name": "Huntard", "class": "HUNTER", "buffs": WB[:6]},
        {"name": "Tanky", "class": "WARRIOR", "buffs": ALL6},
        {"name": "Locky", "class": "WARLOCK", "buffs": ALL6},
        {"name": "Faraway", "class": "MAGE", "visible": False},
        {"name": "Greedy", "class": "ROGUE", "buffs": ALL6},
        {"name": "Basic", "class": "PRIEST", "buffs": []},
    ])
    ns.Scan(ns, True)
    by, _ = evaluate(ns)
    check(by["rogue"].status == "OK" and by["rogue"].maxAllowed == 4, "AQ40 DPS 6 WB + flask: 4")
    check(by["mage"].maxAllowed == 3 and by["mage"].deduct == 1, "AQ40 DPS 5 WB + flask: 3")
    check(ns.MissingText(by["mage"]) == "6 WB + Flask: WB 5/6", "AQ40 reason: " + ns.MissingText(by["mage"]))
    check(by["huntard"].maxAllowed == 4 and by["huntard"].deduct == 1
          and ns.MissingText(by["huntard"]) == "6 WB + Flask: Flask 0/1",
          "AQ40 pull hunter with 6 WB, no flask: 4 (" + ns.MissingText(by["huntard"]) + ")")
    check(by["tanky"].status == "OK" and by["tanky"].maxAllowed == 5, "AQ40 tank (manual, all raids) fully buffed: 5")
    check(by["locky"].status == "OK" and by["locky"].roleLabel == "Warlock Tank" and by["locky"].maxAllowed == 5,
          "AQ40 warlock tank fully buffed: 5")
    check(by["faraway"].status == "UNKNOWN" and ns.AllowedText(by["faraway"]) == "3-4", "AQ40 out of range: 3-4")
    check(by["greedy"].deduct == 1, "AQ40 DPS with 5 SR: deduct 1")
    check(by["basic"].status == "OK" and by["basic"].maxAllowed == 3, "AQ40 DPS without buffs keeps 3")
    check(lua.eval("SRCheckDB.profiles[1].assigned.huntard") == "Pull Hunter"
          and lua.eval("SRCheckDB.profiles[2].assigned.huntard") == "Pull Hunter"
          and lua.eval("SRCheckDB.profiles[1].assigned.locky") is None, "assignments are per profile")
    check("6 WB + Flask +1 (6 WB + Flask)" in ns.ProfileSummary(ns, ns.GetProfile(ns)), "profile summary")

    # AQ40 in two stages: flask now, world buffs after the unboon (WB group on hold).
    lua.eval("SlashCmdList.SRCHECK")("skip WB")
    set_raid(lua, [
        {"name": "Rogue", "class": "ROGUE", "buffs": [TITANS]},          # flask, WB not yet
        {"name": "Mage", "class": "MAGE", "buffs": WB[:2]},              # no flask
        {"name": "Huntard", "class": "HUNTER", "buffs": [TITANS]},
        {"name": "Tanky", "class": "WARRIOR", "buffs": [TITANS]},
        {"name": "Locky", "class": "WARLOCK", "buffs": [TITANS]},
        {"name": "Faraway", "class": "MAGE", "visible": False},
        {"name": "Greedy", "class": "ROGUE", "buffs": [TITANS]},        # 5 SR: over even with WB
        {"name": "Basic", "class": "PRIEST", "buffs": []},
    ])
    ns.ResetScans(ns)
    ns.Scan(ns, True)
    by, summary = evaluate(ns)
    check(by["rogue"].status == "PENDING" and ns.AllowedText(by["rogue"]) == "3-4",
          "WB on hold: flasked DPS with 4 SR is pending (3-4)")
    check(by["mage"].status == "OVER" and by["mage"].deduct == 1
          and ns.MissingText(by["mage"]) == "6 WB + Flask: Flask 0/1",
          "WB on hold: missing flask still fails '6 WB + Flask' (" + ns.MissingText(by["mage"]) + ")")
    check(by["greedy"].deduct == 1, "WB on hold: over the max is still deducted")
    check(by["faraway"].status == "UNKNOWN", "out of range stays 'not verified'")
    check(by["basic"].status == "OK", "3 SR is fine whatever the buffs")
    lua.execute("TEST.sent = {}")
    ns.Announce(ns)
    sent = [m.msg for m in lua.eval("TEST.sent").values()]
    check("(checked: Flask; later: WB)" in sent[0] and not any("Rogue" in m for m in sent),
          "announce names the groups checked and skips pending players: %s" % sent)
    lua.execute("TEST.sent = {}")
    ns.WhisperDeductions(ns)
    whispers = {m.target: m.msg for m in lua.eval("TEST.sent").values()}
    check(set(whispers) == {"Mage", "Greedy"} and "WB checked later" in whispers["Mage"],
          "whispers only deductions, mentioning the later check")
    drops, _ = ns.CollectDrops(ns)
    check(drops["mage"] == 1 and drops["rogue"] is None, "corrected string only removes flask failures now")
    report = ns.BuildReport(ns)
    check("On hold (checked later): WB" in report and "waiting for: WB" in report, "report shows groups on hold")
    # After the unboon: check WB again and rescan.
    lua.eval("function() TEST.raid[1].buffs = {22888, 24425, 16609, 15366, 22817, 22818, 17626} end")()
    lua.eval("SlashCmdList.SRCHECK")("check all")
    ns.Scan(ns, True)
    by, _ = evaluate(ns)
    check(by["rogue"].status == "OK" and by["huntard"].status == "OVER" and by["huntard"].deduct == 1,
          "WB checked after the unboon: final result")

    # OR rule with a group on hold: "6 WB or 3 WB + Flask"
    prof = ns.GetProfile(ns)
    held = lua.eval("{ wb = true }")
    rule = lua.eval('{ name = "Buffed", condition = "6 WB or 3 WB + Flask" }')
    ev = lambda r, wb, fl: ns.EvaluateRule(prof, r, lua.table_from({"wb": wb, "flask": fl}), held).ok
    check(ev(rule, 0, 0) is None and ev(rule, 0, 1) is None and ev(rule, 6, 0) is None,
          "OR rule stays open while WB is on hold (6 WB alone could still do it)")
    both = lua.eval('{ name = "Both", condition = "3 WB + Flask" }')
    check(ev(both, 6, 0) is False and ev(both, 0, 1) is None, "AND rule fails on a missing flask with WB on hold")
    check(ns.EvaluateRule(prof, rule, lua.table_from({"wb": 2, "flask": 1}), lua.table()).ok is False,
          "nothing on hold: 2 WB + flask fails the OR rule")

    # Required rules (not used by the presets any more, still supported)
    lua.eval("""function(p) table.insert(p.rules, { name = "Req", condition = "Flask", required = true,
        enabled = true, roles = { DPS = true, TANK = true, HEALER = true } }) end""")(prof)
    lua.eval("function() TEST.raid[2].buffs = {} end")()
    ns.ResetScans(ns)
    ns.Scan(ns, True)
    by, _ = evaluate(ns)
    check(by["mage"].maxAllowed == 0 and by["faraway"].minAllowed == 0, "missed required rule: 0 SR; unscanned: 0-..")
    ns.SetAdjustment(ns, "mage", 1)
    check(evaluate(ns)[0]["mage"].maxAllowed == 1, "manual +1 still applies after a missed required rule")
    ns.SetAdjustment(ns, "mage", 0)
    lua.eval("function(p) table.remove(p.rules) end")(prof)

    # ---- Test: 1 SR + Mark of the Wild + Thorns + any world buff
    ns.SetAdjustment(ns, "mage", 0)
    ns.SetActiveProfile(ns, "Test")
    set_raid(lua, [
        {"name": "Rogue", "class": "ROGUE", "buffs": [9885, [9910, "Thorns"], 15366]},     # ids
        {"name": "Mage", "class": "MAGE", "buffs": [[None, "Gift of the Wild"], [None, "Thorns"]]},  # names only
        {"name": "Huntard", "class": "HUNTER", "buffs": [21850]},                         # Gift of the Wild id
        {"name": "Tanky", "class": "WARRIOR", "buffs": []},
    ])
    ns.ResetScans(ns)
    ns.Scan(ns, True)
    by, _ = evaluate(ns)
    check(by["rogue"].maxAllowed == 4, "Test: MotW + Thorns + Songflower = 4")
    check(by["mage"].maxAllowed == 3, "Test: matched by buff name (Gift of the Wild, Thorns) = 3")
    check(by["huntard"].maxAllowed == 2, "Test: Gift of the Wild id counts as MotW = 2")
    check(by["tanky"].maxAllowed == 1, "Test: nothing = 1")


def test_buff_ids():
    print("world buff ids (Era)")
    lua, ns = new_runtime(generic=False)
    count = lua.eval("""function(ns, text, ids, names)
        local auras = { ids = {}, names = {} }
        for _, id in ipairs(ids) do auras.ids[id] = true end
        for _, n in ipairs(names) do auras.names[ns.LowerUTF8(n)] = true end
        return (ns.CountMatches(ns.ParseSpellList(text), auras))
    end""")
    wb, flask = ns.WORLD_BUFF_SPELLS, ns.FLASK_SPELLS
    # Exactly what an Era scan recorded: Rend, Ony, ZG (new IDs), Songflower, Moxie, Savvy.
    real = lua.table(355366, 355363, 355365, 15366, 22820, 22818)
    check(count(ns, wb, real, lua.table()) == 6, "Era IDs 355363/355365/355366 count: 6 WB")
    check(count(ns, wb, lua.table(22888, 24425, 16609), lua.table()) == 3, "old IDs still count")
    check(count(ns, wb, lua.table(999001, 999002), lua.table("Rallying Cry of the Dragonslayer", "Warchief's Blessing")) == 2,
          "matched by buff name when the ID is unknown")
    check(count(ns, wb, lua.table(999003), lua.table("Sayge's Dark Fortune of Damage")) == 1,
          "DMF matched by 'Sayge's Dark Fortune of*'")
    check(count(ns, wb, lua.table(23768, 23735), lua.table("Sayge's Dark Fortune of Damage")) == 1, "DMF counts once")
    check(count(ns, flask, lua.table(999004), lua.table("Supreme Power")) == 1, "flask matched by buff name")
    check(count(ns, flask, lua.table(17624), lua.table()) == 1, "Flask of Petrification counts")
    check(count(ns, flask, lua.table(999005), lua.table("Flask of Something New")) == 1, "any 'Flask of*' counts")
    check(count(ns, flask, lua.table(17626), lua.table("Flask of the Titans")) == 1, "a flask counts once")
    for fid in (17626, 17627, 17628, 17629):
        check(count(ns, flask, lua.table(fid), lua.table()) == 1, "flask %d counts" % fid)
    check(count(ns, wb, lua.table(355363, 22888), lua.table("Rallying Cry of the Dragonslayer")) == 1,
          "old + new ID + name of one buff count once")

    # Migration from v3 (1.1.1 flask list) -> v4.
    lua, ns = new_runtime(generic=False, seed="""SRCheckDB = { presetsVersion = 3, profiles = {
        { name = "BWL", base = {}, rules = {}, groups = { { name = "Flask",
          spells = "17626/Flask of the Titans, 17627/Distilled Wisdom, 17628/Supreme Power, 17629/Chromatic Resistance" } } } } }""")
    check(lua.eval("SRCheckDB.profiles[1].groups[1].spells") == ns.FLASK_SPELLS, "1.1.1 flask list -> any flask")

    # Migration v2 -> v4 on saved profiles.
    lua, ns = new_runtime(generic=False, seed="""SRCheckDB = { presetsVersion = 2, profiles = {
        { name = "BWL", base = {}, rules = {}, groups = {
            { name = "WB", spells = "22888, 24425, 16609, 15366, 22817, 22818, 22820, 23768/23736/23766/23738/23737/23735/23767/23769" },
            { name = "Flask", spells = "17626, 17627, 17628, 17629" } } },
        { name = "Mine", base = {}, rules = {}, groups = { { name = "WB", spells = "22888,16609 , 15366" } } } } }""")
    g = lua.eval("SRCheckDB.profiles[1].groups")
    check(g[1].spells == ns.WORLD_BUFF_SPELLS and g[2].spells == ns.FLASK_SPELLS, "untouched WB/Flask lists replaced")
    check(lua.eval("SRCheckDB.profiles[2].groups[1].spells") == "22888/355363, 16609/355366, 15366",
          "edited list gets the new IDs: " + lua.eval("SRCheckDB.profiles[2].groups[1].spells"))


def test_saved_variables(path):
    """Runs the migration on the real SRCheck SavedVariables and re-counts its scans."""
    print("real SRCheck saved data: " + path)
    seed = open(path, encoding="utf-8").read()
    lua, ns = new_runtime(generic=False, seed=seed)
    check(lua.eval("SRCheckDB.presetsVersion") == ns.PRESETS_VERSION, "migrated to current presets")
    seen = lua.eval("SRCheckDB.session and SRCheckDB.session.seen") or {}
    for key in list(seen.keys()):
        for name in ("BWL", "AQ40"):
            prof = ns.GetProfile(ns, name)
            groups = {g.name: g for g in prof.groups.values()}
            n = ns.CountMatches(ns.ParseSpellList(groups["WB"].spells), seen[key])[0]
            fl = ns.CountMatches(ns.ParseSpellList(groups["Flask"].spells), seen[key])[0]
            check(groups["Flask"].spells == ns.FLASK_SPELLS, "%s %s flask list is the any-flask list" % (key, name))
            print("    %-12s %-5s WB %d  Flask %d" % (key, name, n, fl))


def test_real_sample(lua, ns, path):
    print("real softres.it sample: " + path)
    sv = open(path, encoding="utf-8").read()
    m = re.search(r'\["importString"\] = "([^"]+)"', sv)
    if not m:
        print("  (no importString found)")
        return
    s = m.group(1)
    expected = gargul_decode(s)
    ok = ns.Import(ns, s)
    check(ok is True, "import real string")
    total = sum(len(e["items"]) for e in expected["softreserves"])
    got = sum(len(ns.data.players[i]["items"]) for i in range(1, len(ns.data.players) + 1))
    check(got == total and len(ns.data.players) == len(expected["softreserves"]),
          "%d players / %d SRs" % (len(ns.data.players), got))
    text, removed = ns.BuildCorrectedGargul(ns, lua.table())
    check(removed == 0 and gargul_decode(text) == expected, "unchanged round trip is identical JSON")


def main():
    lua, ns = new_runtime()
    test_codec(lua, ns)
    test_names(lua, ns)
    test_conditions(lua, ns)
    test_import_and_evaluate(lua, ns)
    lua, ns = new_runtime()
    test_csv(lua, ns)
    lua, ns = new_runtime(ui=True)
    test_ui(lua, ns)
    test_presets()
    test_buff_ids()
    for path in glob.glob(os.path.expanduser(
            "~/wow/World of Warcraft/_classic_era_/WTF/Account/*/SavedVariables/SRCheck.lua")):
        test_saved_variables(path)

    paths = sys.argv[1:] or glob.glob(os.path.expanduser(
        "~/wow/World of Warcraft/_classic_era_/WTF/Account/*/SavedVariables/Gargul.lua"))
    for path in paths:
        lua, ns = new_runtime()
        test_real_sample(lua, ns, path)

    print("\n%s" % ("ALL PASSED" if failures == 0 else "%d FAILED" % failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
