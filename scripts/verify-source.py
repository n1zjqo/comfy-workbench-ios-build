#!/usr/bin/env python3
"""Read-only structural checks. This is not a replacement for Swift/Xcode tests."""
import json
import plistlib
import re
import struct
from pathlib import Path
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
project_path = ROOT / "ComfyWorkbench.xcodeproj/project.pbxproj"
project = project_path.read_text(encoding="utf-8")
with (ROOT / "ComfyWorkbench/Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert info["MinimumOSVersion"] == "15.0"
assert info["UIRequiredDeviceCapabilities"] == ["arm64"]
assert info["NSLocalNetworkUsageDescription"]
assert info["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"] is True
assert "CODE_SIGN_ENTITLEMENTS" not in project
assert set(re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);", project)) == {"15.0"}
assert set(re.findall(r"TARGETED_DEVICE_FAMILY = ([^;]+);", project)) == {"1"}
assert set(re.findall(r"ASSETCATALOG_COMPILER_APPICON_NAME = ([^;]+);", project)) == {"AppIcon"}

definitions = re.findall(r"(?m)^\s*([A-F0-9]{24})(?: /\*.*?\*/)? = \{\s*isa =", project)
assert len(definitions) == len(set(definitions)), "Duplicate Xcode project object ID"
references = set(re.findall(r"\b[A-F0-9]{24}\b", project))
assert references <= set(definitions), f"Unknown project references: {references - set(definitions)}"

file_refs = dict(re.findall(
    r"([A-F0-9]{24}) /\*[^\n]*?\*/ = \{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = \"([^\"]+)\";", project))
app_sources = {path.relative_to(ROOT).as_posix() for path in (ROOT / "ComfyWorkbench").rglob("*.swift")}
test_sources = {path.relative_to(ROOT).as_posix() for path in (ROOT / "iOSTests").rglob("*.swift")}
actual_sources = app_sources | test_sources
assert set(file_refs.values()) == actual_sources, (
    f"Missing project refs: {actual_sources - set(file_refs.values())}; "
    f"Missing files: {set(file_refs.values()) - actual_sources}")
all_build_refs = dict(re.findall(
    r"([A-F0-9]{24}) /\*[^\n]*?\*/ = \{isa = PBXBuildFile; fileRef = ([A-F0-9]{24});", project))
build_refs = {key: value for key, value in all_build_refs.items() if value in file_refs}
assert set(build_refs.values()) == set(file_refs), "Swift file omitted from a build file"
source_phases = re.findall(r"isa = PBXSourcesBuildPhase;.*?files = \((.*?)\);", project, re.S)
assert len(source_phases) == 2
for phase, expected in zip(source_phases, (app_sources, test_sources)):
    phase_ids = re.findall(r"\b[A-F0-9]{24}\b", phase)
    assert len(phase_ids) == len(set(phase_ids)), "Duplicate source build entry"
    assert {file_refs[build_refs[key]] for key in phase_ids} == expected, "Incorrect Sources phase"

scheme = ElementTree.parse(ROOT / "ComfyWorkbench.xcodeproj/xcshareddata/xcschemes/ComfyWorkbench.xcscheme")
for entry in scheme.iter("BuildableReference"):
    assert entry.attrib["BlueprintIdentifier"] in definitions
    assert entry.attrib["BuildableName"] == {
        "D00000000000000000000001": "ComfyWorkbench.app",
        "D00000000000000000000003": "ComfyWorkbenchNativeTests.xctest",
    }[entry.attrib["BlueprintIdentifier"]]
assert len(list(scheme.iter("TestableReference"))) == 1
workflow = (ROOT / ".github/workflows/ios-build.yml").read_text(encoding="utf-8")
assert "workflow_dispatch:" in workflow and "swift test" in workflow
assert not re.search(r"^  (push|pull_request|schedule):", workflow, re.M)
assert "runs-on: macos-15" in workflow

json_count = 0
for folder in (ROOT / "ComfyWorkbench", ROOT / "Samples"):
    if folder.exists():
        for path in folder.rglob("*.json"):
            json.loads(path.read_text(encoding="utf-8-sig"))
            json_count += 1
icon_folder = ROOT / "ComfyWorkbench/Assets.xcassets/AppIcon.appiconset"
icons = json.loads((icon_folder / "Contents.json").read_text(encoding="utf-8"))["images"]
for entry in icons:
    pixels = int(entry["size"].split("x")[0]) * int(entry["scale"][0])
    data = (icon_folder / entry["filename"]).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "App icon is not PNG"
    assert struct.unpack(">II", data[16:24]) == (pixels, pixels), "Incorrect icon dimensions"
    assert data[25] == 2, "App icon must be opaque RGB"
print(f"Source checks passed: {len(actual_sources)} Swift sources, {json_count} JSON files, plist, scheme, project references and manual CI workflow.")
print("Swift compilation, XCTest, device execution and IPA verification still require the macOS build.")
