"""Index animation objects in local Koikatsu Sunshine AssetBundles and zipmods."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
from zipfile import ZipFile

import UnityPy
from kks_unityfs_index import bundle_objects


ANIMATION_PATHS = {
    "anim", "anime", "animation", "animations", "animator", "motion", "motions",
    "controller", "pose", "poses", "actioncontrol", "playeraction",
}


def animation_path(path):
    parts = path.lower().split("/")
    return any(part in ANIMATION_PATHS for part in parts[:-1]) or any(
        word in parts[-1] for word in ("anim", "motion", "dance", "pose")
    )


def clips(objects, bundle, archive=None):
    results = []
    for obj in objects:
        if obj.type.name != "AnimationClip":
            continue
        name = obj.peek_name()
        if not name:
            continue
        location = f"{archive or ''}:{bundle}:{obj.path_id}"
        results.append({
            "id": hashlib.sha256(location.encode()).hexdigest()[:24],
            "name": name,
            "bundle": bundle,
            "object_id": str(obj.path_id),
            "archive": archive,
        })
    return results


def read_clips(source, bundle, archive=None):
    try:
        return clips(bundle_objects(source, bundle), bundle, archive)
    except Exception:
        source.seek(0)
        return clips(UnityPy.load(source.read()).objects, bundle, archive)


def index(game, output, all_bundles, reuse):
    rows, failures = [], []
    if reuse:
        existing = json.loads(reuse.read_text(encoding="utf-8"))
        if not all_bundles or existing["errors"] or existing["all_bundles"]:
            raise ValueError("--reuse expects a successful animation-path-only catalog and --all-bundles")
        rows.extend(existing["clips"])

    def wanted(path):
        return not animation_path(path) if reuse else (all_bundles or animation_path(path))

    base = [p for p in (game / "abdata").rglob("*.unity3d") if wanted(p.relative_to(game).as_posix())]
    mods = list((game / "mods").rglob("*.zipmod"))

    def read_base(path):
        relative = path.relative_to(game).as_posix()
        try:
            with path.open("rb") as source:
                return read_clips(source, relative), []
        except Exception as error:
            return [], [{"source": relative, "error": str(error)}]

    def read_mod(path):
        relative = path.relative_to(game).as_posix()
        rows, failures = [], []
        try:
            with ZipFile(path) as archive:
                for entry in archive.namelist():
                    if not entry.lower().endswith(".unity3d") or not wanted(entry):
                        continue
                    try:
                        with archive.open(entry) as source:
                            rows.extend(read_clips(source, entry, relative))
                    except Exception as error:
                        failures.append({"source": f"{relative} / {entry}", "error": str(error)})
        except Exception as error:
            failures.append({"source": relative, "error": str(error)})
        return rows, failures

    with ThreadPoolExecutor(max_workers=4) as executor:
        for entries, errors in executor.map(read_base, base):
            rows.extend(entries)
            failures.extend(errors)
        for number, (entries, errors) in enumerate(executor.map(read_mod, mods), start=1):
            rows.extend(entries)
            failures.extend(errors)
            if number % 500 == 0:
                print(f"Checked {number}/{len(mods)} archives, {len(rows)} animation objects.", flush=True)
    rows.sort(key=lambda item: (item["name"].casefold(), item["bundle"], item["id"]))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"clips": rows, "errors": failures, "all_bundles": all_bundles},
                                 ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"{len(rows)} AnimationClip objects, {len(failures)} read errors, {len(base)} base bundles, {len(mods)} archives.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--all-bundles", action="store_true")
    parser.add_argument("--reuse", type=Path, help="Reuse a successful animation-path scan when indexing all bundles.")
    args = parser.parse_args()
    index(args.game, args.output, args.all_bundles, args.reuse)
