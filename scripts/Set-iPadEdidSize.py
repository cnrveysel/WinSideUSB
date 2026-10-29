#!/usr/bin/env python3
"""Patch physical dimensions in a binary EDID without changing its modes.

Only base-block centimetres, physical millimetres in nonzero-pixel-clock
base/CTA detailed timing descriptors, and affected block checksums can change.
Unknown extension formats are preserved verbatim, including any size fields
they might contain. Invalid input checksums are rejected, never repaired.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import tempfile
from typing import Sequence


BLOCK_SIZE = 128
EDID_HEADER = b"\x00\xff\xff\xff\xff\xff\xff\x00"
BASE_DTD_OFFSETS = (54, 72, 90, 108)
DTD_SIZE = 18
CTA_EXTENSION = 0x02


def _centimetres(value: int, name: str) -> int:
    if type(value) is not int or not 1 <= value <= 4095:
        raise ValueError(f"{name} must be an integer from 1 to 4095 mm.")
    rounded = (value + 5) // 10  # Nearest centimetre; half centimetres round up.
    if rounded > 255:
        raise ValueError(f"{name} rounds beyond the EDID limit of 255 cm.")
    return rounded


def _validate_edid(data: bytes) -> None:
    if len(data) < BLOCK_SIZE or len(data) % BLOCK_SIZE:
        raise ValueError("EDID length must be a nonzero multiple of 128 bytes.")
    if data[:8] != EDID_HEADER:
        raise ValueError("EDID base-block header is invalid.")
    expected_length = (data[126] + 1) * BLOCK_SIZE
    if len(data) != expected_length:
        raise ValueError(
            f"EDID declares {data[126]} extension blocks but has {len(data)} bytes."
        )
    for block_start in range(0, len(data), BLOCK_SIZE):
        block_number = block_start // BLOCK_SIZE
        block = data[block_start:block_start + BLOCK_SIZE]
        if sum(block) % 256:
            raise ValueError(f"EDID block {block_number} has an invalid checksum.")
        if block_number and block[0] == CTA_EXTENSION:
            dtd_start = block[2]
            if dtd_start != 0 and not 4 <= dtd_start <= 127:
                raise ValueError(
                    f"CTA extension block {block_number} has an invalid DTD offset."
                )


def patch_edid_size(data: bytes, width_mm: int, height_mm: int) -> bytes:
    """Return an EDID copy with only supported physical-size fields changed.

    The base centimetre fields are quantized using nearest-integer, half-up
    rounding. Detailed timing descriptors retain the exact millimetre values.
    All original block checksums must already be valid.
    """
    width_cm = _centimetres(width_mm, "width_mm")
    height_cm = _centimetres(height_mm, "height_mm")
    _validate_edid(data)

    result = bytearray(data)
    result[21:23] = bytes((width_cm, height_cm))
    dtd_size = bytes((width_mm & 0xFF, height_mm & 0xFF,
                      ((width_mm >> 8) << 4) | (height_mm >> 8)))

    for block_start in range(0, len(result), BLOCK_SIZE):
        if block_start == 0:
            offsets = BASE_DTD_OFFSETS
        elif result[block_start] == CTA_EXTENSION:
            dtd_start = result[block_start + 2]
            offsets = range(dtd_start, 127 - DTD_SIZE + 1, DTD_SIZE) if dtd_start else ()
        else:
            continue  # Do not interpret or rewrite unknown extension layouts.

        for offset in offsets:
            absolute = block_start + offset
            if result[absolute] != 0 or result[absolute + 1] != 0:
                result[absolute + 12:absolute + 15] = dtd_size

        block_end = block_start + BLOCK_SIZE
        if result[block_start:block_end] != data[block_start:block_end]:
            result[block_end - 1] = (-sum(result[block_start:block_end - 1])) & 0xFF

    patched = bytes(result)
    _validate_edid(patched)
    return patched


def _write_atomic(path: Path, data: bytes) -> None:
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb", prefix=f".{path.name}.", suffix=".tmp",
            dir=path.parent, delete=False,
        ) as output:
            temporary = Path(output.name)
            output.write(data)
        temporary.replace(path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_edid", type=Path, help="Existing binary EDID file")
    parser.add_argument("output_edid", type=Path, help="Destination binary EDID file")
    parser.add_argument("--width-mm", type=int, required=True)
    parser.add_argument("--height-mm", type=int, required=True)
    args = parser.parse_args(argv)
    try:
        patched = patch_edid_size(
            args.input_edid.read_bytes(), args.width_mm, args.height_mm
        )
        _write_atomic(args.output_edid, patched)
    except (OSError, ValueError) as error:
        print(f"EDID size update failed: {error}", file=sys.stderr)
        return 2
    print(
        f"Wrote {args.output_edid}: {args.width_mm} x {args.height_mm} mm "
        f"(base fields {patched[21]} x {patched[22]} cm)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
