"""Create a reproducible local archive containing only manifest-listed mod files."""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shutil
import sys
import xml.etree.ElementTree as ET
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dev", action="store_true", help="package development tools separately")
    args = parser.parse_args()
    name = "FDT_Dev" if args.dev else "FDT"
    source = ROOT / name
    manifest = source / (name + ".modinfo")
    xml = ET.parse(manifest).getroot()
    description = xml.findtext("./Properties/Description", "")
    import re
    version_match = re.search(r"Version (\d+\.\d+\.\d+(?:\.\d+)?)\.", description)
    if not version_match:
        raise ValueError("Manifest description must declare Version X.Y.Z.")
    version = version_match.group(1)
    names = [manifest.name, *[n.text.strip() for n in xml.findall("./Files/File")]]
    if len(set(names)) != len(names):
        raise ValueError("Duplicate manifest file")
    stage = ROOT / "dist" / f"{name}_{version}"
    if stage.exists():
        # Verified fixed workspace descendant, never an arbitrary user path.
        if not stage.resolve().is_relative_to((ROOT / "dist").resolve()):
            raise ValueError("Unsafe staging path")
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    archive = Path(str(stage) + ".zip")
    checksums: dict[str, str] = {}
    with ZipFile(archive, "w", compression=ZIP_DEFLATED, compresslevel=9) as output:
        for relative in sorted(names):
            path = (source / relative).resolve()
            if not path.is_relative_to(source.resolve()) or not path.is_file():
                raise ValueError(f"Missing/unsafe source file: {relative}")
            payload = path.read_bytes()
            target = stage / name / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
            if target.read_bytes() != payload:
                raise IOError(f"Copy verification failed: {relative}")
            entry = ZipInfo(f"{name}/{relative.replace(chr(92), '/')}", date_time=(2026, 1, 1, 0, 0, 0))
            entry.compress_type = ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            output.writestr(entry, payload)
            checksums[entry.filename] = hashlib.sha256(payload).hexdigest()
    with ZipFile(archive) as output:
        if sorted(output.namelist()) != sorted(checksums):
            raise IOError("Archive file list mismatch")
        for name_in_zip, checksum in checksums.items():
            if hashlib.sha256(output.read(name_in_zip)).hexdigest() != checksum:
                raise IOError(f"Archive byte verification failed: {name_in_zip}")
    print(f"PASS {archive}: {len(names)} files match the repository byte for byte")
    print("Local validation package. In-game spikes and multiplayer validation remain pending.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
