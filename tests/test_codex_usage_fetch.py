import importlib.util
import json
import os
import shutil
import unittest
from pathlib import Path


def load_module():
    root = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("codex_usage_fetch", root / "codex_usage_fetch.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CodexUsageFetchTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[1]
        self.tmp_path = root / ".test_runtime"
        if self.tmp_path.exists():
            shutil.rmtree(self.tmp_path)
        self.tmp_path.mkdir()
        self.old_cache_path = os.environ.get("CODEX_USAGE_CACHE_PATH")
        os.environ["CODEX_USAGE_CACHE_PATH"] = str(self.tmp_path / "last_usage.json")
        self.mod = load_module()

    def tearDown(self):
        if self.old_cache_path is None:
            os.environ.pop("CODEX_USAGE_CACHE_PATH", None)
        else:
            os.environ["CODEX_USAGE_CACHE_PATH"] = self.old_cache_path
        shutil.rmtree(self.tmp_path, ignore_errors=True)

    def test_build_result_clamps_percentages(self):
        result = self.mod._build_result({
            "plan_type": "plus",
            "rate_limit": {
                "allowed": True,
                "limit_reached": False,
                "primary_window": {"used_percent": 125, "reset_after_seconds": 3600},
                "secondary_window": {"used_percent": -5, "reset_after_seconds": -1},
            },
        })

        self.assertEqual(result["primary"]["used"], 100)
        self.assertEqual(result["primary"]["left"], 0)
        self.assertEqual(result["secondary"]["used"], 0)
        self.assertEqual(result["secondary"]["left"], 100)
        self.assertEqual(result["secondary"]["reset_seconds"], 0)

    def test_atomic_json_write_round_trips(self):
        target = self.tmp_path / "nested" / "cache.json"
        self.mod._atomic_json_write(target, {"ok": True, "text": "正常"})

        self.assertEqual(json.loads(target.read_text(encoding="utf-8")), {"ok": True, "text": "正常"})

    def test_error_kind_for_usage_error(self):
        self.assertEqual(self.mod._error_kind(self.mod.UsageError("bad auth", "auth")), "auth")


if __name__ == "__main__":
    unittest.main()
