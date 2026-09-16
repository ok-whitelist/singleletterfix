#!/usr/bin/env python3
"""Extract BSP-packed assets that sit under a single-character folder."""

import argparse
import bz2
import hashlib
import io
import os
import struct
import sys
import zipfile

LUMP_PAKFILE = 40
STATE_NAME = ".casefold-flatten.state"
WROTE_NAME = ".casefold-flatten.files"


def pakfile(path):
    """Return the BSP's embedded pakfile as a ZipFile, or None."""
    with open(path, "rb") as f:
        header = f.read(8 + 64 * 16)
        if header[:4] != b"VBSP":
            return None
        offset, length = struct.unpack_from("<ii", header, 8 + LUMP_PAKFILE * 16)
        if length <= 0:
            return None
        f.seek(offset)
        try:
            return zipfile.ZipFile(io.BytesIO(f.read(length)))
        except zipfile.BadZipFile:
            return None


def flatten(name):
    """materials/z/lightpost.vtf -> materials/lightpost.vtf"""
    parts = name.split("/")
    return "/".join([p for p in parts[:-1] if len(p) != 1] + [parts[-1]])


def needs_fix(name):
    return any(len(d) == 1 for d in name.split("/")[:-1])


def fingerprint(path):
    st = os.stat(path)
    return hashlib.sha1(("%d:%d" % (st.st_size, st.st_mtime_ns)).encode()).hexdigest()


def load_state(path):
    if not os.path.isfile(path):
        return {}
    state = {}
    with open(path) as f:
        for line in f:
            key, _, value = line.strip().partition(" ")
            if value:
                state[value] = key
    return state


def undo(out):
    listing = os.path.join(out, WROTE_NAME)
    if not os.path.isfile(listing):
        sys.exit("nothing to undo: no %s in %s" % (WROTE_NAME, out))

    removed = 0
    dirs = set()
    with open(listing) as f:
        for line in f:
            target = os.path.join(out, line.strip())
            if os.path.isfile(target):
                os.remove(target)
                removed += 1
                dirs.add(os.path.dirname(target))

    for d in sorted(dirs, key=len, reverse=True):
        while d.startswith(out) and d != out:
            try:
                os.rmdir(d)
            except OSError:
                break
            d = os.path.dirname(d)

    os.remove(listing)
    state = os.path.join(out, STATE_NAME)
    if os.path.isfile(state):
        os.remove(state)
    print("removed %d files from %s" % (removed, out))


def main():
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__)
    ap.add_argument("--server", metavar="GAMEDIR",
                    help="write copies and plugin manifests into a server's game folder")
    ap.add_argument("--maps", help="override the folder scanned for .bsp files")
    ap.add_argument("--out", help="where copies go (default: <game>/download)")
    ap.add_argument("--only", nargs="*", metavar="MAP", help="limit to these maps")
    ap.add_argument("--all", action="store_true", help="reprocess maps already done")
    ap.add_argument("--undo", action="store_true", help="remove what a previous run wrote")
    ap.add_argument("--bz2-out", metavar="DIR", help="write bzip2 copies here for a server fastdl root")
    ap.add_argument("--manifests", metavar="DIR", help="write a per-map file list for casefoldfix.sp")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if args.server:
        args.maps = args.maps or os.path.join(args.server, "maps")
        args.out = args.out or args.server
        args.manifests = args.manifests or os.path.join(
            args.server, "addons", "sourcemod", "data", "casefoldfix")

    out = args.out
    if not out and not args.bz2_out:
        sys.exit("need --server, or --out and/or --bz2-out")

    if args.undo:
        undo(out)
        return

    maps = args.maps
    if not maps:
        sys.exit("need --maps (or --server)")
    if not os.path.isdir(maps):
        sys.exit("no maps folder at " + maps)

    bsps = sorted(os.path.join(maps, f) for f in os.listdir(maps) if f.endswith(".bsp"))
    if args.only:
        wanted = {m[:-4] if m.endswith(".bsp") else m for m in args.only}
        bsps = [b for b in bsps if os.path.basename(b)[:-4] in wanted]
        missing = wanted - {os.path.basename(b)[:-4] for b in bsps}
        if missing:
            sys.exit("no such map: " + ", ".join(sorted(missing)))

    base = out or args.bz2_out
    state_path = os.path.join(base, STATE_NAME)
    wrote_path = os.path.join(base, WROTE_NAME)
    state = {} if args.all else load_state(state_path)

    written = skipped = maps_hit = maps_skipped = 0
    written_bytes = 0
    clashes = []
    new_state = []
    wrote = []

    for bsp in bsps:
        mapname = os.path.basename(bsp)[:-4]
        mark = fingerprint(bsp)
        if state.get(mapname) == mark:
            maps_skipped += 1
            new_state.append((mark, mapname))
            continue

        z = pakfile(bsp)
        if z is None:
            continue
        sizes = {i.filename: i.file_size for i in z.infolist()}
        names = sorted(n for n in sizes if needs_fix(n))
        new_state.append((mark, mapname))
        if not names:
            continue
        maps_hit += 1

        manifest = []
        for name in names:
            target = flatten(name)
            manifest.append(target)

            targets = []
            if out:
                targets.append((os.path.join(out, target), False))
            if args.bz2_out:
                targets.append((os.path.join(args.bz2_out, target + ".bz2"), True))

            # first writer wins where two maps flatten onto the same path
            todo = []
            for dest, compress in targets:
                if os.path.exists(dest):
                    if not compress and os.path.getsize(dest) != sizes[name]:
                        clashes.append((mapname, name, target))
                else:
                    todo.append((dest, compress))
            if not todo:
                skipped += 1
                continue

            data = z.read(name)
            for dest, compress in todo:
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as f:
                    f.write(bz2.compress(data) if compress else data)
                written += 1
                written_bytes += len(data)
                if not compress:
                    wrote.append(target)

        if args.manifests:
            os.makedirs(args.manifests, exist_ok=True)
            with open(os.path.join(args.manifests, mapname + ".txt"), "w") as f:
                f.write("\n".join(manifest) + "\n")

        if not args.quiet:
            print("%-44s %4d files" % (mapname, len(names)))

    os.makedirs(base, exist_ok=True)
    with open(state_path, "w") as f:
        for mark, mapname in new_state:
            f.write("%s %s\n" % (mark, mapname))
    if wrote:
        with open(wrote_path, "a") as f:
            f.write("\n".join(wrote) + "\n")

    print()
    print("maps needing the workaround: %d" % maps_hit)
    if maps_skipped:
        print("maps unchanged since last run: %d" % maps_skipped)
    print("files written: %d (%.1f MiB), already present: %d"
          % (written, written_bytes / 1048576, skipped))
    if clashes:
        print("\n%d flattened paths collided with different content:" % len(clashes))
        for mapname, name, target in clashes[:20]:
            print("   %s: %s -> %s" % (mapname, name, target))
    if written and out:
        print("\nundo with: %s --out %s --undo" % (sys.argv[0], out))


if __name__ == "__main__":
    main()
