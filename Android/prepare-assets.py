#!/usr/bin/env python3
"""Build APK assets from Android-only files and the shared desktop scripts."""

from pathlib import Path
import shutil
import json
import re


def assistant_contract(root):
    """Fail closed if the shared Mac tool declarations change their shape."""
    definitions = []
    instructions = []
    for name in ("AssistantTools", "AssistantActions"):
        source = (root / f"Sources/StudyPlanner/{name}.swift").read_text()
        declaration = source.split("static let definitions:", 1)[1].split("static let instructions", 1)[0]
        matches = re.findall(r'\.init\(name: "([^"\n]+)", description: "([^"\n]+)", fields: \[(.*?)\]\)', declaration)
        if len(matches) != declaration.count(".init(name:"):
            raise ValueError("Unsupported assistant tool declaration")
        for tool, description, fields in matches:
            pairs = re.findall(r'"([^"\n]+)": "([^"\n]+)"', fields)
            if fields.strip() != ":" and len(pairs) != fields.count(": "):
                raise ValueError("Unsupported assistant tool fields")
            definitions.append(dict(name=tool, description=description, fields=dict(pairs)))
        instructions.append(re.search(r'static let instructions = """\n(.*?)\n    """', source, re.S)[1])
    privacy = (root / "Sources/StudyPlanner/AssistantContentPolicy.swift").read_text()
    # Public detection regexes from tracked source, never runtime credentials.
    detection_source = (root / "Sources/StudyPlanner/AssistantData.swift").read_text().split("let patterns = [", 1)[1].split("\n            ]", 1)[0]
    return dict(version=1, tools=definitions, instructions="\n".join(instructions),
                secretPatterns=re.findall(r'#"(.*?)"#', detection_source),
                privacyRules=[dict(pattern=p, reason=r) for p, r in re.findall(r'\(#"(.*?)"#, "(.*?)"\)', privacy)])


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
    contract = assistant_contract(android.parent)
    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(static, output)
    (output / "crawlers").mkdir(exist_ok=True)
    for name, content in bundles.items():
        (output / "crawlers" / f"{name}.js").write_bytes(content)
    (output / "assistant-contract.json").write_text(json.dumps(contract, ensure_ascii=False), encoding="utf-8")
    print(f"Prepared Android assets with {len(bundles)} shared crawler entry points")


if __name__ == "__main__":
    main()
