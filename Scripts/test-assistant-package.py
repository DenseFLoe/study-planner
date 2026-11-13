"""Validate the assistant DMG using only its isolated synthetic entry point."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dmg", type=Path)
    parser.add_argument("--windows", action="store_true", help="Also exercise real AppKit windows in a logged-in desktop session")
    args = parser.parse_args()
    dmg = args.dmg.resolve()
    subprocess.run(["shasum", "-a", "256", "-c", dmg.name + ".sha256"], cwd=dmg.parent, check=True)
    with tempfile.TemporaryDirectory(prefix="study-assistant-dmg-", dir="/private/tmp") as folder:
        mount = Path(folder) / "volume"
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(dmg)], check=True)
        try:
            app = mount / "学习日程.app"
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            assert metadata.get("StudyPlannerAssistant") is True
            assert metadata.get("StudyPlannerAssistantRuntime") == "swift"
            assert not (app / "Contents/Resources/AgentPrototype").exists(), "Production assistant must not carry Node/SDK payload"
            environment = {"PATH": "/usr/bin:/bin", "LANG": "zh_CN.UTF-8", "TMPDIR": "/private/tmp"}
            executable = app / "Contents/MacOS/StudyPlanner"
            version = subprocess.check_output([str(executable), "--version"], text=True, env=environment, timeout=20)
            assert metadata["StudyPlannerSourceRevision"] in version
            result = subprocess.run([str(executable), "--assistant-check"], text=True, capture_output=True,
                                    env=environment, timeout=60, check=True)
            assert "ASSISTANT_PACKAGE_PROBE_PASS protocols=3 queries=18 externalRequests=0 credentialsUsed=0" in result.stdout
            assert "actions=preview-confirm-undo" in result.stdout
            assert "move=preview-confirm-reopen-undo" in result.stdout
            assert "focus=compound-preview" in result.stdout
            assert "charts=3-native-verified" in result.stdout
            assert "usage=per-turn-verified" in result.stdout
            print(result.stdout.strip())
            if args.windows:
                windows = subprocess.run([str(executable), "--assistant-window-check"], text=True, capture_output=True,
                                         env=environment, timeout=90, check=True)
                assert "ASSISTANT_WINDOW_PROBE_PASS cycles=12" in windows.stdout
                print(windows.stdout.strip())
            print(json.dumps({"source": metadata["StudyPlannerSourceIdentifier"], "dmgBytes": dmg.stat().st_size}))
        finally:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True)


if __name__ == "__main__":
    main()
