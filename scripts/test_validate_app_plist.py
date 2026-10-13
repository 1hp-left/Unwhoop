import copy
import plistlib
from pathlib import Path
import tempfile
import unittest
import zipfile

from validate_app_plist import load_plist, validate


class MetadataTests(unittest.TestCase):
    def setUp(self):
        self.source = load_plist(Path(__file__).resolve().parents[1]
                                 / "Unwhoop/Resources/Info.plist")
        self.built = copy.deepcopy(self.source)
        self.built.update(CFBundleShortVersionString="1.0.2", CFBundleVersion="3",
                          CFBundleExecutable="Unwhoop",
                          CFBundleIdentifier="com.unwhoop.app")

    def test_valid_metadata(self):
        validate(self.built, self.source, "1.0.2", "3")

    def test_reordered_capabilities_allowed(self):
        self.built["UIRequiredDeviceCapabilities"].reverse()
        validate(self.built, self.source, "1.0.2", "3")

    def test_bluetooth_capability_dropped_rejected(self):
        self.built["UIRequiredDeviceCapabilities"] = ["arm64"]
        with self.assertRaisesRegex(ValueError, "UIRequiredDeviceCapabilities"):
            validate(self.built, self.source, "1.0.2", "3")

    def test_missing_bluetooth_text_rejected(self):
        del self.built["NSBluetoothAlwaysUsageDescription"]
        with self.assertRaisesRegex(ValueError, "NSBluetoothAlwaysUsageDescription"):
            validate(self.built, self.source, "1.0.2", "3")

    def test_background_modes_dropped_rejected(self):
        del self.built["UIBackgroundModes"]
        with self.assertRaisesRegex(ValueError, "UIBackgroundModes"):
            validate(self.built, self.source, "1.0.2", "3")

    def test_old_build_rejected(self):
        self.built["CFBundleVersion"] = "1"
        with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
            validate(self.built, self.source, "1.0.2", "3")

    def test_unresolved_executable_rejected(self):
        self.built["CFBundleExecutable"] = "$(EXECUTABLE_NAME)"
        with self.assertRaisesRegex(ValueError, "CFBundleExecutable"):
            validate(self.built, self.source, "1.0.2", "3")

    def test_binary_plist_in_ipa(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "Unwhoop.ipa"
            with zipfile.ZipFile(artifact, "w") as archive:
                archive.writestr("Payload/Unwhoop.app/Info.plist",
                                 plistlib.dumps(self.built, fmt=plistlib.FMT_BINARY))
                archive.writestr("Payload/Unwhoop.app/Frameworks/Other.framework/Info.plist",
                                 plistlib.dumps({}))
            validate(load_plist(artifact), self.source, "1.0.2", "3")


if __name__ == "__main__":
    unittest.main()
