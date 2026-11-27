import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


class RouteTests(unittest.TestCase):
    def test_native_route_engine(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "route-tests"
            subprocess.run(
                shlex.split(os.environ.get("CC", "cc"))
                + ["-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-O2",
                   str(root / "BLDRoute.c"), str(root / "tests/test_route.c"),
                   "-lm", "-o", str(binary)],
                check=True,
            )
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            self.assertEqual(
                result.returncode,
                0,
                f"Route executable exited with {result.returncode}\n"
                f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
            )
            self.assertIn("Route tests passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
