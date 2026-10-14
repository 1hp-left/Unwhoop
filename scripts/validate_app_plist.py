"""Reject app bundles/IPAs missing the metadata needed to launch and sync."""

import argparse
import plistlib
from pathlib import Path
import zipfile


def load_plist(path):
    if path.suffix.lower() == ".ipa":
        with zipfile.ZipFile(path) as archive:
            names = [name for name in archive.namelist()
                     if name.startswith("Payload/") and name.count("/") == 2
                     and name.endswith(".app/Info.plist")]
            if len(names) != 1:
                raise ValueError("IPA must contain exactly one top-level app Info.plist")
            return plistlib.loads(archive.read(names[0]))
    if path.suffix.lower() == ".app":
        path = path / "Info.plist"
    with path.open("rb") as file:
        return plistlib.load(file)


def validate(plist, source, version, build):
    # Check the built/packaged artifact, not just the plist in the checkout.
    for key in (
        "NSBluetoothAlwaysUsageDescription", "NSHealthUpdateUsageDescription",
        "UIBackgroundModes", "UISupportedInterfaceOrientations",
        "UILaunchScreen", "LSRequiresIPhoneOS",
        "BGTaskSchedulerPermittedIdentifiers",
    ):
        if key not in plist or plist[key] != source[key]:
            raise ValueError(f"Missing or changed {key}: {plist.get(key)!r}")
    # Xcode may reorder capabilities while processing the plist.
    capabilities = plist.get("UIRequiredDeviceCapabilities")
    if not isinstance(capabilities, list) or set(capabilities) != set(source["UIRequiredDeviceCapabilities"]):
        raise ValueError(f"Missing or changed UIRequiredDeviceCapabilities: {capabilities!r}")
    for key in ("NSBluetoothAlwaysUsageDescription", "NSHealthUpdateUsageDescription"):
        if not isinstance(plist[key], str) or not plist[key].strip():
            raise ValueError(f"Empty privacy description: {key}")
    for key, expected in (("CFBundleShortVersionString", version),
                          ("CFBundleVersion", build)):
        if plist.get(key) != expected:
            raise ValueError(f"Expected {key}={expected}, got {plist.get(key)!r}")
    for key in ("CFBundleExecutable", "CFBundleIdentifier"):
        value = plist.get(key)
        if not isinstance(value, str) or not value or "$(" in value:
            raise ValueError(f"Missing or unresolved {key}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    source = load_plist(Path(__file__).resolve().parents[1]
                        / "Unwhoop/Resources/Info.plist")
    validate(load_plist(args.artifact), source, args.version, args.build)
    print(f"Validated {args.artifact}: {args.version} ({args.build}), privacy and BLE metadata intact")


if __name__ == "__main__":
    main()
