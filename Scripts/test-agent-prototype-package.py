"""Verify and run the synthetic probe from a mounted DMG, without personal data."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dmg', type=Path)
    args = parser.parse_args()
    dmg = args.dmg.resolve()
    subprocess.run(['shasum', '-a', '256', '-c', dmg.name + '.sha256'], cwd=dmg.parent, check=True)
    with tempfile.TemporaryDirectory(prefix='study-agent-dmg-') as folder:
        mount = Path(folder) / 'volume'
        subprocess.run(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg)], check=True)
        try:
            app = mount / '学习日程.app'
            metadata = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            if metadata.get('StudyPlannerAgentPrototype') is not True:
                raise RuntimeError('This DMG has no synthetic prototype payload')
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
            executable = app / 'Contents/MacOS/StudyPlanner'
            environment = {'PATH': '/usr/bin:/bin', 'LANG': 'zh_CN.UTF-8', 'TMPDIR': folder}
            version = subprocess.check_output([str(executable), '--version'], text=True, env=environment, timeout=15)
            if metadata['StudyPlannerSourceRevision'] not in version:
                raise RuntimeError('Packaged executable revision mismatch')
            started = time.monotonic()
            result = subprocess.run([str(executable), '--agent-prototype-check'], env=environment,
                                    text=True, capture_output=True, timeout=45, check=True)
            print(result.stdout)
            if 'SYNTHETIC_AGENT_PROBE_PASS externalRequests=0 credentialsUsed=0' not in result.stdout:
                raise RuntimeError('Missing complete probe result')
            print(json.dumps({'revision': metadata['StudyPlannerSourceRevision'],
                              'dmgBytes': dmg.stat().st_size,
                              'probeSeconds': round(time.monotonic() - started, 3)}, indent=2))
        finally:
            subprocess.run(['hdiutil', 'detach', str(mount)], check=True)


if __name__ == '__main__':
    main()
