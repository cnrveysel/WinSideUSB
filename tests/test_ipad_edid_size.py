"""Four small, file-local tests; no registry, display, driver or device access.

Run with: python -m unittest discover -s tests -p test_ipad_edid_size.py -v
"""

import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "Set-iPadEdidSize.py"
SPEC = importlib.util.spec_from_file_location("ipad_edid_size", SCRIPT)
edid_size = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(edid_size)

# Synthetic identity and a fixed 1080p timing; no user/device fixture is needed.
DTD = bytes.fromhex("023a801871382d40582c4500fd1e1100001e")
NAME_DESCRIPTOR = b"\x00\x00\x00\xfc\x00FIXTURE PANEL"


def checksum(block):
    block = bytearray(block)
    block[127] = (-sum(block[:127])) & 0xFF
    return bytes(block)


def fixture(*extensions):
    base = bytearray(128)
    base[:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
    base[8:18] = bytes.fromhex("12345678010203040120")
    base[18:24] = bytes((1, 4, 0x80, 51, 29, 120))
    base[24:54] = bytes(range(30))
    base[54:72] = DTD
    base[72:90] = NAME_DESCRIPTOR
    base[90:108] = DTD
    base[108:126] = bytes(18)
    base[126] = len(extensions)
    return checksum(base) + b"".join(extensions)


def cta_fixture(dtd_start=32):
    block = bytearray(128)
    block[:4] = bytes((0x02, 0x03, dtd_start, 0x01))
    block[4:8] = bytes.fromhex("4310041f")
    if 4 <= dtd_start <= 109:
        block[dtd_start:dtd_start + 18] = DTD
    return checksum(block)


class EdidSizeTests(unittest.TestCase):
    def assert_only_changed(self, original, patched, allowed):
        self.assertEqual(len(original), len(patched))
        changed = {i for i, (before, after) in enumerate(zip(original, patched))
                   if before != after}
        self.assertLessEqual(changed, set(allowed))
        for offset in range(0, len(patched), 128):
            self.assertEqual(sum(patched[offset:offset + 128]) % 256, 0)

    def test_base_geometry_preserves_identity_timings_and_descriptors(self):
        original = fixture()
        patched = edid_size.patch_edid_size(original, 263, 197)
        self.assertEqual(patched[21:23], bytes((26, 20)))
        for dtd in (54, 90):
            self.assertEqual(patched[dtd + 12:dtd + 15], bytes.fromhex("07c510"))
        allowed = {21, 22, 127, 66, 67, 68, 102, 103, 104}
        self.assert_only_changed(original, patched, allowed)
        self.assertEqual(patched[8:21], original[8:21])
        self.assertEqual(patched[72:90], NAME_DESCRIPTOR)
        self.assertEqual(patched[108:126], bytes(18))
        self.assertEqual(edid_size.patch_edid_size(patched, 263, 197), patched)

    def test_cta_dtds_and_unknown_extension_are_preserved_precisely(self):
        unknown = bytearray(range(128))
        unknown[0] = 0x99
        unknown[32:50] = DTD  # Looks like a DTD, but is in an unknown layout.
        original = fixture(cta_fixture(), checksum(unknown))
        patched = edid_size.patch_edid_size(original, 263, 197)
        self.assertEqual(patched[128 + 44:128 + 47], bytes.fromhex("07c510"))
        self.assertEqual(patched[256:], original[256:])
        allowed = {21, 22, 127, 66, 67, 68, 102, 103, 104, 172, 173, 174, 255}
        self.assert_only_changed(original, patched, allowed)
        # A declared empty CTA timing area must stay empty, checksum included.
        empty_cta = bytearray(128)
        empty_cta[:2] = b"\x02\x03"
        empty_original = fixture(checksum(empty_cta))
        self.assertEqual(
            edid_size.patch_edid_size(empty_original, 263, 197)[128:],
            empty_original[128:],
        )

    def test_invalid_edid_is_rejected_without_repair(self):
        original = fixture()
        bad_header = bytearray(original)
        bad_header[0] = 1
        bad_count = bytearray(original)
        bad_count[126] = 1
        bad_checksum = bytearray(original)
        bad_checksum[8] ^= 1
        bad_extension = bytearray(cta_fixture())
        bad_extension[125] ^= 1
        cases = {
            "header": checksum(bad_header),
            "short": original[:-1],
            "trailing bytes": original + b"\x00",
            "extension count": checksum(bad_count),
            "base checksum": bytes(bad_checksum),
            "extension checksum": fixture(bytes(bad_extension)),
            "CTA offset": fixture(cta_fixture(3)),
        }
        for reason, invalid in cases.items():
            with self.subTest(reason=reason):
                with self.assertRaises(ValueError):
                    edid_size.patch_edid_size(invalid, 263, 197)

    def test_rounding_limits_and_cli_do_not_overwrite_on_validation_error(self):
        original = fixture()
        for width, height, expected_cm in ((265, 195, (27, 20)), (2554, 5, (255, 1))):
            with self.subTest(width=width, height=height):
                patched = edid_size.patch_edid_size(original, width, height)
                self.assertEqual(tuple(patched[21:23]), expected_cm)
                self.assertEqual(
                    patched[66] | ((patched[68] >> 4) << 8), width
                )
                self.assertEqual(
                    patched[67] | ((patched[68] & 15) << 8), height
                )
        for invalid in (0, -1, 4096, 2555, True, 1.5):
            for width, height in ((invalid, 197), (263, invalid)):
                with self.subTest(width=width, height=height):
                    with self.assertRaises(ValueError):
                        edid_size.patch_edid_size(original, width, height)

        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "original.bin"
            output = Path(directory) / "patched.bin"
            source.write_bytes(original)
            argv = [str(source), str(output), "--width-mm", "263", "--height-mm", "197"]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(edid_size.main(argv), 0)
            expected = edid_size.patch_edid_size(original, 263, 197)
            self.assertEqual(output.read_bytes(), expected)
            self.assertEqual(source.read_bytes(), original)
            source.write_bytes(b"invalid EDID")
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(edid_size.main(argv), 2)
            self.assertEqual(output.read_bytes(), expected)
            self.assertEqual(sorted(path.name for path in Path(directory).iterdir()),
                             ["original.bin", "patched.bin"])


if __name__ == "__main__":
    unittest.main()
