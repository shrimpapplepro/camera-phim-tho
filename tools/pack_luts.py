#!/usr/bin/env python3
"""Pack .cube 3D LUTs into TrueShot's filter library.

Usage:
    python3 tools/pack_luts.py <folder-of-cubes> [--out TrueShot/Resources/LUTs]

Each .cube becomes a lossless 16-bit PNG strip (width n·n, height n; pixel (b·n + r, g)
holds the output for input (r, g, b)) plus an entry in catalog.json. The first folder level
under <folder-of-cubes> becomes the "brand" tab in the app, the second level the "group":

    my-cubes/
      Film/Portra.cube            → tab "Film"
      Film/Warm/Golden.cube       → tab "Film", group "Warm"
      Mono.cube                   → tab "My LUTs"

LUTs are applied in gamma-encoded sRGB, which is what most photo .cube files expect.
Requires numpy (`pip install numpy`); the PNG writer is built in.
"""
import argparse
import json
import re
import struct
import sys
import zlib
from pathlib import Path

import numpy as np


def parse_cube(path: Path) -> np.ndarray:
    """Returns T[b, g, r, c] in 0…1 (the .cube data order: red changes fastest)."""
    size, domain_min, domain_max, rows = None, np.zeros(3), np.ones(3), []
    for raw in path.read_text(errors="replace").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        key = line.split()[0].upper()
        if key == "LUT_3D_SIZE":
            size = int(line.split()[1])
        elif key == "LUT_1D_SIZE":
            raise ValueError("1D LUTs aren't supported")
        elif key == "DOMAIN_MIN":
            domain_min = np.array([float(v) for v in line.split()[1:4]])
        elif key == "DOMAIN_MAX":
            domain_max = np.array([float(v) for v in line.split()[1:4]])
        elif key in ("TITLE", "LUT_3D_INPUT_RANGE"):
            continue
        elif re.match(r"^[-+.\deE]", line):
            rows.append([float(v) for v in line.split()[:3]])
    if size is None:
        raise ValueError("no LUT_3D_SIZE")
    if not 2 <= size <= 128:
        raise ValueError(f"unsupported size {size}")
    data = np.array(rows, dtype=np.float64)
    if data.shape != (size ** 3, 3):
        raise ValueError(f"expected {size ** 3} rows, found {len(rows)}")
    if not (np.allclose(domain_min, 0) and np.allclose(domain_max, 1)):
        raise ValueError("only 0…1 input domains are supported")
    return np.clip(data, 0, 1).reshape(size, size, size, 3)


def write_png16(path: Path, rgb: np.ndarray) -> None:
    """Writes an RGB 16-bit PNG (no colour profile, so values are used exactly)."""
    h, w, _ = rgb.shape
    arr = (np.clip(rgb, 0, 1) * 65535 + 0.5).astype(">u2")
    raw = b"".join(b"\x00" + arr[y].tobytes() for y in range(h))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    path.write_bytes(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 16, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw, 9))
                     + chunk(b"IEND", b""))


def pretty(stem: str) -> str:
    words = re.sub(r"[_\-]+", " ", stem).split()
    return " ".join(w if w.isupper() else w.capitalize() for w in words) or stem


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path, help="folder containing .cube files (searched recursively)")
    parser.add_argument("--out", type=Path, default=Path(__file__).resolve().parent.parent / "TrueShot/Resources/LUTs")
    args = parser.parse_args()

    cubes = sorted(p for p in args.source.rglob("*") if p.suffix.lower() == ".cube")
    if not cubes:
        print(f"No .cube files under {args.source}", file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)
    for old in args.out.glob("*.png"):
        old.unlink()

    catalog, used = [], set()
    for cube in cubes:
        rel = cube.relative_to(args.source)
        try:
            t = parse_cube(cube)
        except ValueError as error:
            print(f"skip {rel}: {error}", file=sys.stderr)
            continue
        n = t.shape[0]
        strip = t.transpose(1, 0, 2, 3).reshape(n, n * n, 3)          # rows = g, cols = b·n + r
        base = re.sub(r"[^a-z0-9]+", "-", str(rel.with_suffix("")).lower()).strip("-") or "lut"
        uid, k = base, 2
        while uid in used:
            uid, k = f"{base}-{k}", k + 1
        used.add(uid)
        write_png16(args.out / f"{uid}.png", strip)
        parts = rel.parts
        catalog.append({
            "id": uid,
            "name": pretty(cube.stem),
            "brand": parts[0] if len(parts) > 1 else "My LUTs",
            "group": parts[1] if len(parts) > 2 else "",
            "size": n,
            "bits": 16,
            "file": f"{uid}.png",
        })

    catalog.sort(key=lambda c: (c["brand"], c["group"], c["name"]))
    (args.out / "catalog.json").write_text(json.dumps(catalog, indent=1, ensure_ascii=False))
    print(f"Packed {len(catalog)} LUT(s) into {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
