"""Regression checks for installer boundaries, log parsing and actual API discovery."""
from contextlib import redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


class ToolingTests(unittest.TestCase):
    def installer(self, destination: Path, *switches: str) -> subprocess.CompletedProcess:
        return subprocess.run([
            shutil.which("pwsh") or "powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(ROOT / "tools/install.ps1"), "-ModsPath", str(destination), *switches,
        ], capture_output=True, text=True, timeout=60)

    def verify_mod(self, folder: Path, name: str) -> None:
        source = ROOT / name
        expected = {p.relative_to(source) for p in source.rglob("*") if p.is_file()}
        actual = {p.relative_to(folder) for p in folder.rglob("*") if p.is_file()}
        self.assertEqual(expected, actual)
        for relative in expected:
            self.assertEqual((source / relative).read_bytes(), (folder / relative).read_bytes())

    @unittest.skipUnless(sys.platform == "win32", "PowerShell installer is Windows-only")
    def test_installer_modes_reinstall_and_exact_copies_in_isolated_temp_folder(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fdt-installer-test-") as temporary:
            root = Path(temporary).resolve()
            self.assertNotEqual(root, ROOT)
            for label, switches, expected in (
                ("default", (), {"FDT"}),
                ("all", ("-IncludeDev",), {"FDT", "FDT_Dev"}),
                ("dev", ("-DevOnly",), {"FDT_Dev"}),
            ):
                destination = root / label
                destination.mkdir()
                for repeat in range(2):
                    result = self.installer(destination, *switches)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual({p.name for p in destination.iterdir()}, expected)
                    for name in expected:
                        self.verify_mod(destination / name, name)

    @unittest.skipUnless(sys.platform == "win32", "PowerShell installer is Windows-only")
    def test_installer_rejects_source_overlap_and_unrelated_existing_target(self) -> None:
        for destination in (ROOT, ROOT / "FDT", ROOT.parent):
            result = self.installer(destination)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("overlaps", result.stderr)
            self.assertTrue((ROOT / "FDT/FDT.modinfo").is_file())
        with tempfile.TemporaryDirectory(prefix="fdt-unrelated-target-") as temporary:
            destination = Path(temporary).resolve()
            target = destination / "FDT"
            target.mkdir()
            marker = target / "keep.txt"
            marker.write_text("unrelated content", encoding="utf-8")
            result = self.installer(destination, "-IncludeDev")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(encoding="utf-8"), "unrelated content")
            self.assertFalse((destination / "FDT_Dev").exists())
            (target / "FDT.modinfo").write_text('<Mod id="unrelated-mod"/>', encoding="utf-8")
            result = self.installer(destination)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("different mod", result.stderr)
            self.assertTrue(marker.is_file())

    def test_log_parser_recognizes_real_extended_tags_and_pending_failures(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fdt-log-test-") as temporary:
            log = Path(temporary) / "Lua.log"
            base = "[CHECK route=1 food] turn=11 actual=5 expected=5 PASS\n[SPIKE S1 A food city=1 delta=5] turn=11 actual=5 expected=5 PASS\n"
            for suffix, expected in (
                ("[SUMMARY] 2 PASS, 0 FAIL, 0 PENDING\n", 0),
                ("[SUMMARY] 2 PASS, 1 FAIL, 0 PENDING\n", 1),
                ("[SPIKE S4 capture] PENDING manual case\n[SUMMARY] 2 PASS, 0 FAIL, 1 PENDING\n", 1),
                ("", 1),
            ):
                log.write_text(base + suffix, encoding="utf-8")
                result = subprocess.run([sys.executable, str(ROOT / "tools/summarize_log.py"), str(log)], capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertIn("2 PASS", result.stdout)
            diagnostic = "[DEV ERROR] turn=11 actual=engine exception expected=scenario complete FAIL"
            log.write_text(base + diagnostic + "\n[SUMMARY] 2 PASS, 1 FAIL, 0 PENDING\n", encoding="utf-8")
            result = subprocess.run([sys.executable, str(ROOT / "tools/summarize_log.py"), str(log)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn(diagnostic, result.stdout)

    def test_api_audit_discovers_indexed_and_chained_calls_and_ignores_strings(self) -> None:
        spec = importlib.util.spec_from_file_location("fdt_check_test", ROOT / "tools/check_all.py")
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        with tempfile.TemporaryDirectory(prefix="fdt-api-audit-") as temporary:
            root = Path(temporary)
            (root / "FDT").mkdir()
            (root / "tools").mkdir()
            (root / "FDT/sample.lua").write_text('Players[0]:UnverifiedFoodThing():MissingFollowup()\n-- Never.Missing()\nlocal s="Never.Missing()"\n', encoding="utf-8")
            (root / "tools/api_allowlist.json").write_text(json.dumps({"entries": []}), encoding="utf-8")
            checker.ROOT = root
            checker.MODS = (root / "FDT",)
            output = io.StringIO()
            with redirect_stdout(output):
                checker.audit_apis()
            self.assertIn(":UnverifiedFoodThing", output.getvalue())
            self.assertIn(":MissingFollowup", output.getvalue())
            self.assertNotIn("Never", output.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
