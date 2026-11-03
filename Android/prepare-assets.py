#!/usr/bin/env python3
"""Build APK assets from Android-only files and the shared desktop scripts."""

from pathlib import Path
import shutil


def main():
    android = Path(__file__).resolve().parent
    resources = android.parent / "Sources/StudyPlanner/Resources"
    static = android / "assets"
    output = android / "build/assets"
    # These entry points are loaded by CourseImportActivity. Bundle each one's
    # dependencies so it also works when injected into a fresh replay WebView.
    entries = {
        "CourseCrawler": (),
        "GenericCrawler": (),
        "XuechengCrawler": ("XuechengAvailability",),
        "XuechengReplay": ("XuechengAvailability",),
        "QuarkCrawler": (),
    }
    shared = set(entries).union(*(set(deps) for deps in entries.values()))
    for name in shared:
        if (static / "crawlers" / f"{name}.js").exists():
            raise SystemExit(f"Duplicate shared crawler: edit {resources / (name + '.js')} only")
    # Read everything first: a missing dependency must fail the build, never
    # silently package a stale copy left over from an earlier successful build.
    bundles = {
        name: b"\n".join((resources / f"{part}.js").read_bytes() for part in (*deps, name))
        for name, deps in entries.items()
    }
    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(static, output)
    (output / "crawlers").mkdir(exist_ok=True)
    for name, content in bundles.items():
        (output / "crawlers" / f"{name}.js").write_bytes(content)
    print(f"Prepared Android assets with {len(bundles)} shared crawler entry points")


if __name__ == "__main__":
    main()
