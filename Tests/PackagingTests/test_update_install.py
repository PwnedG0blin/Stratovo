import os
import pathlib
import plistlib
import subprocess
import tempfile
import time
import unittest


class UpdateInstallationTests(unittest.TestCase):
    def wait_for_exit(self, process, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = process.poll()
            if result is not None:
                return result
            time.sleep(0.02)
        self.fail(self.output.read_text() if self.output.exists() else "Process did not exit")

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="stratovo update ")
        self.root = pathlib.Path(self.directory.name)
        self.target = self.root / "Programme/Stratovo.app"
        self.source = self.root / "Update/Stratovo.app"
        self.target.joinpath("Contents").mkdir(parents=True)
        self.source.joinpath("Contents").mkdir(parents=True)
        for app, build in ((self.target, "1048"), (self.source, "1050")):
            app.joinpath("Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": build}))
        self.parent = subprocess.Popen(["/bin/sleep", "60"])
        self.output = self.root / "Installation.log"
        helper = pathlib.Path(__file__).resolve().parents[2] / "Packaging/install-update.sh"
        if not helper.exists():
            helper = pathlib.Path(__file__).with_name("install-update.sh")
        source = helper.read_text()
        tools = {
            "/usr/libexec/PlistBuddy": "#!/usr/bin/env python3\nimport plistlib,sys\nprint(plistlib.load(open(sys.argv[-1], 'rb'))['CFBundleVersion'])\n",
            "/usr/bin/ditto": "#!/bin/bash\ncp -R \"$1\" \"$2\"\n",
            "/usr/bin/codesign": "#!/bin/bash\nexit 0\n",
            "/usr/bin/open": "#!/bin/bash\nprintf '%s\\n' \"$*\" >> \"$OPEN_LOG\"\n[[ ! -f \"$FAIL_OPEN\" ]]\n",
        }
        for index, (path, body) in enumerate(tools.items()):
            stub = self.root / f"tool{index}"
            stub.write_text(body)
            stub.chmod(0o700)
            source = source.replace(path, '"' + str(stub) + '"')
        self.helper = self.root / "helper.sh"
        self.helper.write_text(source)
        self.worker = None

    def tearDown(self):
        for process in (self.worker, self.parent):
            if process and process.poll() is None:
                process.terminate()
                self.wait_for_exit(process, 5)
        self.directory.cleanup()

    def start(self):
        environment = dict(os.environ, OPEN_LOG=str(self.root / "open.log"), FAIL_OPEN=str(self.root / "fail-open"))
        with self.output.open("w") as output:
            self.worker = subprocess.Popen(["/bin/bash", str(self.helper), str(self.parent.pid),
                str(self.target), str(self.source), str(self.source.parent)],
                stdout=output, stderr=subprocess.STDOUT, env=environment)

    def wait_for(self, name):
        path = self.source.parent / name
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists():
                return path
            if self.worker.poll() is not None:
                self.fail(self.output.read_text())
            time.sleep(0.02)
        self.fail(self.output.read_text())

    def build(self):
        return plistlib.loads(self.target.joinpath("Contents/Info.plist").read_bytes())["CFBundleVersion"]

    def commit(self):
        self.source.parent.joinpath("commit").write_text("install\n")
        self.parent.terminate()
        self.wait_for_exit(self.parent, 5)
        return self.wait_for_exit(self.worker, 8)

    def test_ready_means_staged_copy_is_valid_and_current_app_is_intact(self):
        self.start()
        self.assertEqual(self.wait_for("ready").read_text().strip(), "1050")
        self.assertEqual(self.build(), "1048")
        self.assertIsNone(self.parent.poll())
        self.assertEqual(self.commit(), 0)
        self.assertEqual(self.build(), "1050")
        self.assertIn("-n ", self.root.joinpath("open.log").read_text())
        backups = list(self.target.parent.glob(".Stratovo-update.*/Previous-Stratovo.app/Contents/Info.plist"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(plistlib.loads(backups[0].read_bytes())["CFBundleVersion"], "1048")

    def test_failed_relaunch_restores_previous_app(self):
        self.root.joinpath("fail-open").touch()
        self.start()
        self.wait_for("ready")
        self.assertNotEqual(self.commit(), 0)
        self.assertEqual(self.build(), "1048")
        self.assertIn("Stratovo starten", self.source.parent.joinpath("failed").read_text())

    def test_bad_package_fails_before_parent_is_asked_to_exit(self):
        self.source.joinpath("Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleVersion": "bad"}))
        self.start()
        self.assertNotEqual(self.wait_for_exit(self.worker, 5), 0)
        self.assertFalse(self.source.parent.joinpath("ready").exists())
        self.assertEqual(self.build(), "1048")
        self.assertIsNone(self.parent.poll())

    def test_symlink_target_is_rejected_before_handoff(self):
        original = self.target.with_name("Original.app")
        self.target.rename(original)
        self.target.symlink_to(original)
        self.start()
        self.assertNotEqual(self.wait_for_exit(self.worker, 5), 0)
        self.assertFalse(self.source.parent.joinpath("ready").exists())
        self.assertIsNone(self.parent.poll())


    @unittest.skipUnless(__import__("sys").platform == "darwin", "requires macOS launchd")
    def test_launchd_worker_finishes_after_submitter_exits(self):
        import uuid
        label = "org.pwnedg0blin.stratovo.update.test." + str(uuid.uuid4())
        domain = "gui/" + str(os.getuid())
        result = self.root / "launchd-result"
        worker = self.root / "launchd-worker.sh"
        worker.write_text('#!/bin/bash\nsleep 1\nprintf done > "$1"\n')
        job = self.root / "launchd.plist"
        job.write_bytes(plistlib.dumps({
            "Label": label,
            "ProgramArguments": ["/bin/bash", str(worker), str(result)],
            "RunAtLoad": True,
            "KeepAlive": False,
        }))
        try:
            subprocess.run(["/bin/launchctl", "bootstrap", domain, str(job)], check=True,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
            deadline = time.monotonic() + 10
            while not result.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertEqual(result.read_text(), "done")
        finally:
            subprocess.run(["/bin/launchctl", "bootout", domain + "/" + label],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


if __name__ == "__main__":
    unittest.main()
