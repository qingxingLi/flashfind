"""Check the actual packaging validator without importing its CLI side effects."""
import ast
import os
from pathlib import Path
import tempfile
import unittest

script = Path(__file__).resolve().parents[1] / "scripts/build_trial.py"
function = next(n for n in ast.parse(script.read_text()).body
                if isinstance(n, ast.FunctionDef) and n.name == "verify_mynas_runtime")
namespace = {"os": os}
exec(compile(ast.Module(body=[function], type_ignores=[]), str(script), "exec"), namespace)
verify = namespace["verify_mynas_runtime"]


class PackagedRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Fixture.app"
        self.files = []
        for component in ["bin/mynas-core", "native/TrustHTTP"]:
            path = self.app / "Contents/Resources/MyNAS" / component
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o644)
            self.files.append(path)

    def test_rejects_resources_that_exist_but_cannot_execute(self):
        with self.assertRaises(SystemExit):
            verify(self.app)

    def test_also_requires_the_trust_helper_to_execute(self):
        self.files[0].chmod(0o755)
        with self.assertRaises(SystemExit):
            verify(self.app)

    def test_accepts_both_executable_resources(self):
        for path in self.files:
            path.chmod(0o755)
        self.assertEqual(verify(self.app), {"bin/mynas-core": "0o755", "native/TrustHTTP": "0o755"})

    def test_rejects_missing_resources(self):
        for path in self.files:
            path.chmod(0o755)
        self.files[1].unlink()
        with self.assertRaises(SystemExit):
            verify(self.app)


if __name__ == "__main__":
    unittest.main()
