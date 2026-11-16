import contextlib
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "fetch_mesh2motion", Path(__file__).resolve().parents[1] / "fetch_mesh2motion.py"
)
fetcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetcher)


class ClipSelectionTest(unittest.TestCase):
    def run_list(self, clips):
        manifest = {"rigs": {"human": {"animations": [
            {"file": "human/idle-a.glb"}, {"file": "human/walk.glb"}
        ]}}}
        output, errors = io.StringIO(), io.StringIO()
        with patch.object(fetcher, "fetch", return_value=json.dumps(manifest).encode()), \
                patch("sys.argv", ["fetch_mesh2motion", "--rig", "human", "--clips", clips, "--list"]), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            result = fetcher.main()
        return result, output.getvalue(), errors.getvalue()

    def test_requested_clips_are_found_or_the_missing_pattern_is_reported(self):
        status, output, _ = self.run_list("idle-a,walk")
        self.assertEqual(status, 0)
        self.assertEqual([line.split("\t")[0] for line in output.splitlines()], ["idle-a", "walk"])
        status, output, error = self.run_list("idle,walk")
        self.assertEqual(status, 2)
        self.assertEqual(output, "")
        self.assertIn("idle", error)
        status, output, _ = self.run_list("idle*,walk")
        self.assertEqual(status, 0)
        self.assertEqual(len(output.splitlines()), 2)


if __name__ == "__main__":
    unittest.main()
