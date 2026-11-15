# SRCheck

A World of Warcraft **Classic Era** addon that checks raiders' soft-reserves
on [softres.it](https://softres.it/) against the guild's SR rules. It reads
the same **Gargul export string** you already paste into Gargul.

The number of SRs a player may have is:

```
allowed = base SRs for their role (DPS / Tank / Healer)
        + bonus of every rule they meet (3 world buffs, flask, ...)
        + manual adjustment (any other reason)
```

SRCheck scans the raid's buffs, compares `allowed` with what each player
reserved, and lists who needs SRs removed. It can then announce or whisper the
deductions and produce a **corrected Gargul string**, or send it straight into
Gargul.

## Design decisions

### Who is tank / healer?

**It isn't in the Gargul string.** The export holds only `name`, `class`,
`note` and `items` for each player. softres.it does store each player's spec,
but only its **CSV export** includes it. SRCheck therefore combines several
sources, in this order:

1. **Raid assignment** in the current profile: a raid job such as Pull Hunter,
   Mage Tank or Warlock Tank. Pick it in the Role menu or with
   `/src role Name pull hunter`. An assignment counts as a role (Tank in the
   presets) and is saved per character **for that profile only**, so a BWL
   mage tank is not a tank in AQ40.
2. **Manual**: Role menu → DPS / Tank / Healer, or `/src role Name tank`. This
   is saved **per character for all raids**, so you set your regular tanks and
   healers once.
3. **softres spec**: when you import the softres.it **CSV export**, the spec
   decides the role (Protection, Guardian, Holy, Discipline, Restoration). It
   uses the same table softres.it uses for its own `@tank` / `@healer` bonuses.
   SRCheck also remembers it for later Gargul-string imports.
4. **In game**: the raid **Main Tank** flag, or an assigned group role.
5. Otherwise **DPS**.

The Role tooltip shows which source was used. The row tooltip also shows the
player's **softres note**, e.g. when the raid asks people to note which buff
option they go for. For other reasons to grant or
remove SRs, use the **Adj** column (`+1` / `-1`, this raid only).

### What is shown: bonuses or deductions?

**Both, in one table.** Deductions come first:

| Status | Meaning |
| --- | --- |
| **DEDUCT -N** | Reserved more than allowed. N SRs must go. |
| **Not verified** | Could not be scanned yet (out of range, offline or dead) and would be over if a rule fails. Never deducted automatically. |
| **Pending** | Scanned, but the result depends on a rule that is **on hold** (see *Checking in stages*). Not deducted yet. |
| **Not in group** | Has SRs on softres.it but isn't in the raid. A name typo is likely. Use `/src link`. |
| **Not checked** | Unticked in the first column (e.g. they unboon later because of their role). Not deducted, and keeps all SRs in the corrected string. The tooltip shows what they would currently get. |
| **Can add +N** | Earned more than they reserved. |
| **No SR** | In the raid but reserved nothing. |
| **OK** | Reserved exactly what they're allowed. |

### How are deductions applied?

Recommended setup on softres.it:

- Set **Reserves per player** to the **DPS maximum** (e.g. 4 for BWL, 3 for
  AQ40), and add raid bonuses `@tank +1` and `@healer +1` (raid settings →
  *Raid Bonuses*). Pull hunters and mage/warlock tanks don't have a softres
  spec, so give them a raid bonus with their **character name** as the target.
- Tell raiders to **reserve in priority order**. If they don't meet the rules,
  their **last-placed SRs are dropped**.

At the raid:

1. Import the softres.it data into Gargul as usual. In SRCheck click **From
   Gargul** (or paste the same string).
2. When everyone is stacked, click **Scan buffs**. A ready check also triggers
   a scan.
3. Click **Announce** and/or **Whisper** so people know.
4. Click **Send to Gargul**, which replaces Gargul's soft-reserves with the
   corrected list, or **Corrected string** to paste it into `/gl sr` yourself.

This keeps raid night entirely in game. The softres.it page still shows the
original reserves. If you want the site to match, edit those players' reserves
there afterwards. You can't do the opposite
(granting **extra** SRs) through the string, because only the player can choose
the item. They add it on softres.it, if the site's limit allows it.

## Rules

Rules live in **profiles** (`/src rules`). A softres raid for BWL or AQ40
selects its preset automatically. Choosing a profile while a raid is loaded
remembers it for that instance.

### Preset profiles

| Profile | Base | Rules | Assignments (count as Tank) |
| --- | --- | --- | --- |
| **BWL** | DPS 3, Tank/Healer 4 | `3 WB + Flask or 6 WB` +1 | Pull Hunter, Mage Tank |
| **AQ40** | DPS 3, Tank/Healer 4 | `6 WB + Flask` +1 (both needed) | Pull Hunter, Warlock Tank |
| **Test** | DPS 3, Tank/Healer 4 | `Flask or 3 WB` +1 | none |

Maximums: all three are 4 for DPS and 5 for tanks, healers and assignments.
Test is used e.g. for MC (select it once while an MC raid is loaded and it is
picked automatically after that). The AQ40 gear check and consumables
prerequisites are not checked by the addon. **Reset profile to
defaults** restores a preset, and keeps who is assigned what.

### Editing

Every field is saved as you type, so Escape or closing the window never loses
an edit. Problems are shown in red in the rules window and at the top right of
the main window: a rule using a group with no buffs, a rule naming an unknown
group, or two groups with the same name. Groups no rule uses are marked
*not used*.

- **Base SRs** per role: what a player gets with no rule met.
- **Raid assignments**: name plus the role it counts as (its base SRs and
  rules), up to 3 per profile.
- **Buff groups**: named lists of spell IDs or exact buff names, separated by
  commas. Use `a/b` for alternatives that count once (a buff's old and new ID,
  or the eight Darkmoon Faire fortunes). A name ending in `*` matches any buff
  starting with it, e.g. `Sayge's Dark Fortune of*`.
- **Rules**: a name, a **condition** over buff groups, a **bonus**, and the
  roles it applies to. Every rule that is met adds its bonus, and rules stack.
  A rule marked **Req** (required) instead drops the player to **0 SR** when
  it isn't met. The manual Adj still applies on top.

Condition syntax: `N group`, joined with `+` / `and` (all of these) and `or`
(any of these):

| Condition | Meaning |
| --- | --- |
| `3 WB` | at least 3 world buffs |
| `Flask` | a flask |
| `6 WB or 3 WB + Flask` | 6 world buffs, or 3 world buffs and a flask |

**New** profiles start from basic rules: *DPS 1, Tank 2, Healer 2*, plus
`3 WB` +1 and `Flask` +1.

`WB` group in all profiles: Rallying Cry of the Dragonslayer, Spirit of Zandalar,
Warchief's Blessing, Songflower Serenade, Fengus' Ferocity, Mol'dar's Moxie,
Slip'kik's Savvy, Sayge's Dark Fortune (any one, counted once). `Flask` group:
**any flask**, counted once: Titans, Distilled Wisdom, Supreme Power, Chromatic
Resistance, Petrification, or any buff named `Flask of*`. Every buff is listed
by ID **and** by name. Era uses the newer IDs 355363 (Ony/Nef),
355365 (ZG) and 355366 (Rend); the old ones are kept as alternatives.

### Checking in stages

People flask before they unboon. The **Check now** row in the main window has
one checkbox per **buff group** (`WB`, `Flask`, ...). Untick `WB` to check only
the flask now:

- A group **on hold** can't cause deductions. Rules that need it are greyed out
  and show their current count.
- Rules are evaluated with "unknown" for the held group. In AQ40, `6 WB + Flask`
  still **fails on a missing flask**, so the player is deducted right away.
  Players who have the flask show as **Pending** until WB is checked.
- An OR rule like BWL's `3 WB + Flask or 6 WB` can't be decided by the flask
  alone, since 6 WB is enough without one. Instead the status shows what each
  player still needs: `Pending: 3 WB` with a flask, `Pending: 6 WB` without.
- Announce, whispers and the report say what was checked, e.g.
  `(checked: Flask; later: WB)`.
- After the unboon, tick `WB` again and scan. The corrected string is always
  built from the original softres data, so you can send it to Gargul again
  without anything being removed twice.

This setting is per raid; `/src skip <group>` and `/src check <group|all>` do the same.

### Scanning notes

- Everyone is **included** by default. Untick the checkbox at the start of a
  row for players who will unboon later, e.g. because of their role. Tick them
  again and scan once they have their buffs. The header checkbox includes or
  excludes everyone. This is per raid only.
- The game only shows buffs of players within roughly **100 yards**.
  Everyone else is *Not verified*, never deducted. Scan at the entrance or on
  a ready check.
- Players with a **Chronoboon** loaded are marked `[boon]`. Their stored
  world buffs aren't active yet, so they don't count until they unboon.
- Scans are **sticky** by default: a buff seen in any scan of this raid keeps
  counting, since world buffs are lost on death. You can turn this off in the
  rules window.
- Data survives `/reload`. Re-importing the same softres raid within 12 hours
  keeps the scans and adjustments.

## Name matching

softres.it names are typed by players. SRCheck matches them to raiders
case-insensitively, then ignoring accents (`Aglaée` = `Aglaee`), then allowing
a small typo within the same class (shown as `~`). Use
`/src link <softres name> <character>` for anything else.

## Install

```bash
./install.sh
```

The script copies the `SRCheck/` folder into
`World of Warcraft/_classic_era_/Interface/AddOns/SRCheck/`.

## Commands

| Command | Action |
| --- | --- |
| `/src` | Toggle the window |
| `/src import` | Open the import box (Gargul string or softres CSV) |
| `/src gargul` | Load what is currently imported in Gargul |
| `/src scan` | Scan raid buffs now |
| `/src announce` | Post deductions + unverified players to raid chat |
| `/src whisper` | Whisper over-reserved players what is removed |
| `/src report` | Full text report (copy to Discord) |
| `/src fix` | Corrected Gargul string |
| `/src role <name> <tank\|healer\|dps\|auto\|assignment>` | Set a role (all raids) or a raid assignment (current profile), or go back to auto |
| `/src adj <name> <n>` | Manual SR adjustment for this raid |
| `/src skip <group>` / `/src check <group\|all>` | Put a buff group on hold (e.g. WB before the unboon) / check it again |
| `/src exclude <name>` / `/src include <name\|all>` | Leave a player out of the check (e.g. unboons later) / check them again |
| `/src link <softres name> [character]` | Link (or unlink) a misspelled softres name |
| `/src rules` | Edit rule profiles |
| `/src reset` | Forget buff scans for this raid |

## Development

The logic and a UI smoke test run outside the game (Lua 5.1 via `lupa`, with
WoW API stubs). If Gargul's SavedVariables contain a real softres.it import, it
is round-tripped too.

```bash
python3 -m venv .venv && .venv/bin/pip install lupa
.venv/bin/python tests/run_tests.py
```

Layout: `SRCheck/` is the addon (Codec = base64/JSON/CSV, Import = softres
parsing and corrected export, Verify = scan/evaluate/reports, UI, Options).
`Libs/` bundles LibStub and LibDeflate (zlib license).
