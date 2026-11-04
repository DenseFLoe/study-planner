"""Record the source actually packaged, and reject edits made during a build."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess


def git(root, *arguments):
    return subprocess.check_output(["git", "-C", str(root), *arguments])


def source_state(root):
    root = Path(root)
    revision = git(root, "rev-parse", "HEAD").decode().strip()
    short = git(root, "rev-parse", "--short", "HEAD").decode().strip()
    # Include new source files as well as staged/unstaged edits. Ignored build
    # outputs, private data and credentials never enter the hash or the bundle.
    paths = set(git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0")) - {b""}
    digest = hashlib.sha256()
    for raw_path in sorted(paths):
        path = root / raw_path.decode("utf-8", errors="surrogateescape")
        digest.update(raw_path + b"\0")
        if path.is_symlink():
            content = b"link\0" + str(path.readlink()).encode("utf-8", errors="surrogateescape")
        elif path.is_file():
            content = (b"executable\0" if path.stat().st_mode & 0o111 else b"file\0") + path.read_bytes()
        elif not path.exists():
            content = b"deleted\0"
        else:
            raise ValueError(f"Cannot fingerprint source path: {path}")
        digest.update(hashlib.sha256(content).digest())
    modified = bool(git(root, "status", "--porcelain=v1", "--untracked-files=normal"))
    if git(root, "rev-parse", "HEAD").decode().strip() != revision:
        raise ValueError("Source revision changed while reading build metadata; retry the build.")
    fingerprint = digest.hexdigest()
    identifier = short + (f"-modified-{fingerprint[:12]}" if modified else "")
    return {
        "StudyPlannerSourceRevision": revision,
        "StudyPlannerSourceIdentifier": identifier,
        "StudyPlannerSourceModified": modified,
        "StudyPlannerSourceFingerprint": fingerprint,
    }


def capture(root, configuration):
    if configuration not in ("debug", "release"):
        raise ValueError("Build configuration must be debug or release.")
    return {
        **source_state(root),
        "StudyPlannerBuildDate": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "StudyPlannerBuildConfiguration": configuration,
    }


def stamp(root, metadata, plist_path):
    current = source_state(root)
    if any(metadata.get(key) != value for key, value in current.items()):
        raise ValueError("Source changed during the build; no package was signed. Retry after edits finish.")
    plist_path = Path(plist_path)
    info = plistlib.loads(plist_path.read_bytes())
    info.update(metadata)
    plist_path.write_bytes(plistlib.dumps(info, sort_keys=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    snapshot = commands.add_parser("capture")
    snapshot.add_argument("root", type=Path)
    snapshot.add_argument("configuration", choices=("debug", "release"))
    snapshot.add_argument("output", type=Path)
    write = commands.add_parser("stamp")
    write.add_argument("root", type=Path)
    write.add_argument("snapshot", type=Path)
    write.add_argument("plist", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "capture":
            args.output.write_text(json.dumps(capture(args.root, args.configuration)), encoding="utf-8")
        else:
            stamp(args.root, json.loads(args.snapshot.read_text(encoding="utf-8")), args.plist)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Build metadata: {error}\n")


if __name__ == "__main__":
    main()
