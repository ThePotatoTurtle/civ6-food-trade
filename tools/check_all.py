"""Run source, XML, manifest and evidenced-engine-call checks for Food Trade."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sqlite3
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
MODS = (ROOT / "FDT", ROOT / "FDT_Dev")
FAILURES: list[str] = []


def check(ok: bool, message: str) -> None:
    print(f"{'PASS' if ok else 'FAIL'} {message}")
    if not ok:
        FAILURES.append(message)


def check_lua() -> None:
    try:
        from lupa.lua51 import LuaRuntime
    except ImportError as exc:
        check(False, f"Lua 5.1 syntax checker requires lupa: {exc}")
        return
    lua = LuaRuntime(unpack_returned_tuples=True)
    compile_lua = lua.eval("function(source, name) local f,err=loadstring(source,name); return f~=nil,err end")
    for path in sorted(p for mod in MODS for p in mod.rglob("*.lua")):
        ok, error = compile_lua(path.read_text(encoding="utf-8-sig"), str(path))
        check(ok, f"Lua 5.1 syntax: {path.relative_to(ROOT)}" + (f": {error}" if error else ""))


def check_manifests() -> dict[Path, ET.Element]:
    parsed: dict[Path, ET.Element] = {}
    for mod in MODS:
        manifests = list(mod.glob("*.modinfo"))
        check(len(manifests) == 1, f"one manifest in {mod.name}")
        if len(manifests) != 1:
            continue
        path = manifests[0]
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            check(False, f"XML {path.relative_to(ROOT)}: {exc}")
            continue
        parsed[path] = root
        files = [n.text.strip().replace("\\", "/") for n in root.findall("./Files/File") if n.text]
        check(len(files) == len(set(files)), f"manifest file list has no duplicates: {mod.name}")
        for name in files:
            target = (mod / name).resolve()
            check(target.is_relative_to(mod.resolve()) and target.is_file(), f"manifest file exists: {mod.name}/{name}")
        actual = {p.relative_to(mod).as_posix() for p in mod.rglob("*") if p.is_file() and p.suffix != ".modinfo"}
        check(actual == set(files), f"manifest matches exact mod contents: {mod.name}; extra={sorted(actual-set(files))}; missing={sorted(set(files)-actual)}")
        referenced = [n.text.strip().replace("\\", "/") for n in root.findall("./InGameActions/*/File") if n.text]
        check(set(referenced) == set(files), f"all {mod.name} files assigned to an action")
        check(root.find("./Dependencies/Mod") is not None, f"dependency declared: {mod.name}")
    return parsed


def check_xml(game_db: Path | None) -> None:
    texts: set[str] = set()
    uses: set[str] = set()
    rows_to_validate: list[tuple[Path, ET.Element]] = []
    for path in sorted(p for mod in MODS for p in mod.rglob("*.xml")):
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            check(False, f"XML {path.relative_to(ROOT)}: {exc}")
            continue
        check(True, f"XML parses: {path.relative_to(ROOT)}")
        for row in root.findall(".//LocalizedText/Row"):
            if row.get("Tag"):
                key = row.attrib["Tag"]
                check(key not in texts, f"unique localization key: {key}")
                texts.add(key)
        for node in root.iter():
            for value in [*node.attrib.values(), node.text or ""]:
                uses.update(re.findall(r"\bLOC_[A-Z0-9_]*FDT[A-Z0-9_]*\b", value))
        if root.tag == "GameData":
            rows_to_validate.append((path, root))
    for path in sorted(p for mod in MODS for p in mod.rglob("*.lua")):
        uses.update(re.findall(r"\bLOC_[A-Z0-9_]*FDT[A-Z0-9_]*\b", path.read_text(encoding="utf-8-sig")))
    check(uses <= texts, f"all custom text keys defined; missing={sorted(uses-texts)}")
    if not game_db:
        print("INFO Game database row/schema validation skipped; pass --game-db DebugGameplay.sqlite to enable it.")
        return
    check(game_db.is_file(), f"game database exists: {game_db}")
    if not game_db.is_file():
        return
    # Source is strictly read-only. Validate against a private in-memory copy.
    source = sqlite3.connect(game_db.resolve().as_uri() + "?mode=ro", uri=True)
    db = sqlite3.connect(":memory:")
    source.backup(db)
    source.close()
    # The shipped DB has engine-only Make_Hash() triggers unavailable in Python.
    # Remove only those triggers from this disposable validation copy; retain all
    # table constraints, indexes, other triggers, and foreign-key enforcement.
    hash_triggers = db.execute("SELECT name FROM sqlite_master WHERE type='trigger' AND sql LIKE '%Make_Hash%' ").fetchall()
    for (trigger_name,) in hash_triggers:
        escaped_name = trigger_name.replace('"', '""')
        db.execute(f'DROP TRIGGER "{escaped_name}"')
    print(f"INFO omitted {len(hash_triggers)} engine-only Make_Hash trigger(s) in memory; runtime hashing is not validated.")
    print("INFO Types.Hash values omitted by XML use unique validation-only placeholders; hash generation/collisions require the game engine.")
    db.execute("PRAGMA foreign_keys=ON")
    placeholder_hash = -9223372036854775807
    for path, root in rows_to_validate:
        try:
            for table in root:
                if table.tag == "LocalizedText":
                    continue  # Localization uses a separate database.
                if not re.fullmatch(r"[A-Za-z_]\w*", table.tag):
                    raise ValueError(f"unsafe table name {table.tag}")
                for row in table:
                    if row.tag != "Row":
                        raise ValueError(f"unsupported XML database operation {row.tag}")
                    values = dict(row.attrib)
                    values.update({child.tag: child.text for child in row})
                    if table.tag == "Types" and "Hash" not in values:
                        while db.execute("SELECT 1 FROM Types WHERE Hash=?", (placeholder_hash,)).fetchone():
                            placeholder_hash += 1
                        values["Hash"] = placeholder_hash
                        placeholder_hash += 1
                    names = list(values)
                    if not names or any(not re.fullmatch(r"[A-Za-z_]\w*", n) for n in names):
                        raise ValueError("invalid column names")
                    columns = ",".join('"' + n + '"' for n in names)
                    marks = ",".join("?" for _ in names)
                    # Civ XML booleans map to SQL integer values.
                    vals = [{"true": 1, "false": 0}.get(str(values[n]).lower(), values[n]) for n in names]
                    db.execute(f'INSERT INTO "{table.tag}" ({columns}) VALUES ({marks})', vals)
            check(True, f"game database accepts rows: {path.relative_to(ROOT)}")
        except (sqlite3.Error, ValueError) as exc:
            check(False, f"game database rows: {path.relative_to(ROOT)}: {exc}")
    db.close()


def lua_code(source: str) -> str:
    """Erase comments/strings while preserving newlines for useful audit locations."""
    token = re.compile(r"--\[(=*)\[.*?\]\1\]|--[^\n]*|\[(=*)\[.*?\]\2\]|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", re.S)
    return token.sub(lambda m: "\n" * m.group().count("\n") or " ", source)


def audit_apis() -> None:
    path = ROOT / "tools" / "api_allowlist.json"
    if not path.is_file():
        check(False, "API allowlist exists")
        return
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    entries = data.get("entries", [])
    allowed = {entry["call"]: entry for entry in entries}
    for call, entry in allowed.items():
        check(bool(entry.get("sources")) and all(isinstance(s, str) and ":" in s for s in entry["sources"]), f"API citation: {call}")
    calls: set[str] = set()
    standard = {"math", "string", "table", "coroutine", "io", "os", "debug", "utf8", "FDT_Core", "FDT", "Core", "M"}
    static_pattern = re.compile(r"\b([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*\.\s*([A-Za-z_]\w*)\s*\(")
    method_pattern = re.compile(r":\s*([A-Za-z_]\w*)\s*\(")
    for path in sorted(p for mod in MODS for p in mod.rglob("*.lua")):
        code = lua_code(path.read_text(encoding="utf-8-sig"))
        discovered = [(":" + m.group(1), m.start()) for m in method_pattern.finditer(code)]
        for match in static_pattern.finditer(code):
            receiver, method = match.groups()
            if receiver.split(".")[0] in standard:
                continue
            discovered.append((receiver + "." + method, match.start()))
        # Audit chained calls and indexed receivers too, e.g. Players[id]:GetTreasury().
        for call, position in discovered:
            calls.add(call)
            if call not in allowed:
                line = code.count("\n", 0, position) + 1
                check(False, f"unverified engine call {call}: {path.relative_to(ROOT)}:{line}")
    check(bool(calls), f"API audit discovers calls from source ({len(calls)} unique)")
    if calls and calls <= set(allowed):
        check(True, "all discovered engine calls have source evidence")


def check_multiplayer_rules() -> None:
    forbidden = {
        r"\bpairs\s*\(": "unordered pairs() in authoritative gameplay",
        r"\bmath\s*\.\s*random\s*\(": "unseeded random() in authoritative gameplay",
        r"\bGame\s*\.\s*GetLocalPlayer\s*\(": "local player access in authoritative gameplay",
        r"\bEvents\s*\.[\w.]+\s*\.\s*Add\s*\(": "async Events handler in authoritative gameplay",
    }
    for path in sorted(p for mod in MODS for p in (mod / "Gameplay").rglob("*.lua")):
        source = lua_code(path.read_text(encoding="utf-8-sig"))
        for pattern, message in forbidden.items():
            check(not re.search(pattern, source), f"MP static rule: {path.relative_to(ROOT)}: {message}")


def check_ui_styles(game_root: Path | None) -> None:
    if not game_root:
        print("INFO Native UI style validation skipped; pass --game-root to check installed styles.")
        return
    check(game_root.is_dir(), f"game root exists: {game_root}")
    if not game_root.is_dir():
        return
    styles: dict[str, str] = {}
    ui_roots = [game_root / "Base/Assets/UI"]
    dlc_root = game_root / "DLC"
    if dlc_root.is_dir():
        ui_roots.extend(folder / "UI" for folder in dlc_root.iterdir() if folder.is_dir() and (folder / "UI").is_dir())
    sources = sorted({source for folder in ui_roots if folder.is_dir() for source in folder.rglob("*Styles*.xml")})
    for source in sources:
        try:
            root = ET.parse(source).getroot()
        except ET.ParseError:
            continue
        sheets = [root] if root.tag == "StyleSheet" else list(root.iter("StyleSheet"))
        for sheet in sheets:
            for definition in sheet:
                styles.setdefault(definition.tag, source.relative_to(game_root).as_posix())
    check(bool(styles), f"read registered native UI styles ({len(styles)})")
    for path in sorted(p for mod in MODS for p in (mod / "UI").rglob("*.xml")):
        root = ET.parse(path).getroot()
        for style in sorted({node.attrib["Style"] for node in root.iter() if "Style" in node.attrib}):
            check(style in styles, f"native UI style {style}: {path.relative_to(ROOT)}" + (f" from {styles[style]}" if style in styles else " is undefined"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-db", type=Path)
    parser.add_argument("--game-root", type=Path)
    args = parser.parse_args()
    check_lua()
    check_manifests()
    check_xml(args.game_db)
    audit_apis()
    check_multiplayer_rules()
    check_ui_styles(args.game_root)
    print(f"SUMMARY {len(FAILURES)} failed check(s)")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
