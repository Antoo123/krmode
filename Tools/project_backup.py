"""Create and verify offline snapshots of Git and locally generated KKS data."""

import argparse
from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys


PROJECT = Path(__file__).resolve().parent.parent
PROFILE = Path(os.environ.get("APPDATA", Path.home() / "AppData/Roaming")) / "Godot/app_userdata/KKS Japanese Style Room"
BUFFER = 1024 * 1024
CACHE_DIRS = {".godot", "__pycache__", ".pytest_cache", ".venv"}
PROFILE_CACHE = {"logs", "shader_cache", "objectdb_snapshots"}


def git(project, *args):
    return subprocess.check_output(["git", "-C", str(project), *args])


def reparse(path):
    return bool(getattr(path.lstat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT) or path.is_symlink()


def manifest_path(root, name):
    relative = PurePosixPath(name)
    if (relative.is_absolute() or not relative.parts or relative.as_posix() != name
            or "\\" in name or ":" in name or ".." in relative.parts
            or any(part.casefold() == ".git" for part in relative.parts)
            or any(part.rstrip(" .") != part for part in relative.parts)):
        raise ValueError(f"Invalid snapshot path: {name}")
    target = root.joinpath(*relative.parts)
    if target.resolve() != target:
        raise ValueError(f"Snapshot path uses a link or junction: {target}")
    return target


def profile_files(profile):
    for directory, subdirs, names in os.walk(profile):
        folder = Path(directory)
        subdirs[:] = sorted(name for name in subdirs
                            if name not in PROFILE_CACHE and name != ".jobs")
        for name in subdirs:
            if reparse(folder / name):
                raise ValueError(f"Profile contains a link or junction: {folder / name}")
        for name in sorted(names):
            if name == "import.lock" or name == ".capture.lock" or name.endswith((".tmp", ".partial")):
                continue
            yield (folder / name).relative_to(profile).as_posix()


def inventory(project, profile):
    ignored = git(project, "ls-files", "--others", "--ignored", "--exclude-standard", "-z")
    paths = (("project", name) for name in os.fsdecode(ignored).split("\0") if name)
    result = []
    for area, name in [*paths, *(("profile", name) for name in profile_files(profile))]:
        parts = PurePosixPath(name).parts
        if area == "project" and (CACHE_DIRS.intersection(parts)
                                  or parts[:2] in {("UnityProject", "Library"), ("UnityProject", "Temp"),
                                                   ("UnityProject", "Logs")}):
            continue
        if area == "project" and name.endswith((".tmp", ".partial", ".pyc", ".pyo")):
            continue
        source = manifest_path(project if area == "project" else profile, name)
        if not source.is_file() or reparse(source):
            raise ValueError(f"Expected a regular file: {source}")
        result.append({"area": area, "path": name, "size": source.stat().st_size})
    return result


def mib(size):
    return f"{size / 2**20:,.2f} MiB"


def print_plan(entries):
    groups = defaultdict(lambda: [0, 0])
    for entry in entries:
        path = PurePosixPath(entry["path"])
        folder = "/".join(path.parts[:2 if path.parts[0] != "Build" else 3]) if len(path.parts) > 1 else "(root)"
        group = groups[entry["area"], folder]
        group[0] += 1
        group[1] += entry["size"]
    for (area, folder), (count, size) in sorted(groups.items(), key=lambda item: -item[1][1]):
        print(f"{area:7} {folder:36} {count:6} files  {mib(size)}")
    print(f"Total payload: {len(entries)} files, {mib(sum(row['size'] for row in entries))}, plus Git bundle.")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def copy_checked(source, target, size, expected=None):
    target.parent.mkdir(parents=True, exist_ok=True)
    checksum = hashlib.sha256()
    with source.open("rb") as reader, target.open("xb") as writer:
        before = os.fstat(reader.fileno())
        for block in iter(lambda: reader.read(BUFFER), b""):
            checksum.update(block)
            writer.write(block)
        after = os.fstat(reader.fileno())
    actual = checksum.hexdigest()
    if (before.st_size != size or after.st_size != size or before.st_mtime_ns != after.st_mtime_ns
            or target.stat().st_size != size or digest(target) != actual or (expected and actual != expected)):
        raise ValueError(f"Copy verification failed: {source} -> {target}")
    return actual


def separate(snapshot, roots):
    if any(snapshot.is_relative_to(root) or root.is_relative_to(snapshot) for root in roots.values()):
        raise ValueError("Use a snapshot directory separate from the project and Godot profile.")


def check_space(path, needed):
    parent = next(folder for folder in (path, *path.parents) if folder.is_dir())
    free = shutil.disk_usage(parent).free
    if free < needed:
        raise ValueError(f"{parent} has {mib(free)} free, while {mib(needed)} is needed.")


def backup(snapshot, roots, entries):
    separate(snapshot, roots)
    project = roots["project"]
    if git(project, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Commit the intended project state before taking a snapshot.")
    head = git(project, "rev-parse", "HEAD").decode().strip()
    git_storage = Path(git(project, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip())
    bundle_estimate = sum(file.stat().st_size for file in (git_storage / "objects").rglob("*") if file.is_file())
    check_space(snapshot, sum(row["size"] for row in entries) + bundle_estimate)
    snapshot.mkdir(parents=True, exist_ok=False)
    bundle = snapshot / "project.bundle"
    git(project, "bundle", "create", str(bundle), "--all")
    git(project, "bundle", "verify", str(bundle))
    for row in entries:
        source = manifest_path(roots[row["area"]], row["path"])
        target = snapshot / row["area"] / row["path"]
        row["sha256"] = copy_checked(source, target, row["size"])
    if git(project, "status", "--porcelain", "--untracked-files=all") or git(project, "rev-parse", "HEAD").decode().strip() != head:
        raise ValueError("The source tree changed while copying. Snapshot remains incomplete.")
    manifest = {"version": 1, "commit": head, "bundle_sha256": digest(bundle), "files": entries}
    marker = snapshot / "snapshot.json"
    marker.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Verified snapshot at {snapshot}")


def verify(snapshot):
    manifest = json.loads(manifest_path(snapshot, "snapshot.json").read_text(encoding="utf-8"))
    if manifest["version"] != 1:
        raise ValueError("Unsupported snapshot version.")
    if digest(manifest_path(snapshot, "project.bundle")) != manifest["bundle_sha256"]:
        raise ValueError("Git bundle checksum differs.")
    files = manifest["files"]
    seen = set()
    for row in files:
        key = row["area"], row["path"].casefold()
        if row["area"] not in {"project", "profile"} or key in seen:
            raise ValueError(f"Invalid or duplicate snapshot entry: {row['path']}")
        seen.add(key)
        source = manifest_path(snapshot, f"{row['area']}/{row['path']}")
        if not source.is_file() or source.stat().st_size != row["size"] or digest(source) != row["sha256"]:
            raise ValueError(f"Snapshot verification failed: {source}")
    print(f"Verified Git bundle and {len(files)} files ({manifest['commit']}).")
    return manifest


def restore(snapshot, roots):
    separate(snapshot, roots)
    if roots["profile"].is_relative_to(roots["project"]) or roots["project"].is_relative_to(roots["profile"]):
        raise ValueError("Choose separate project and profile directories.")
    manifest = verify(snapshot)
    if git(roots["project"], "rev-parse", "HEAD").decode().strip() != manifest["commit"]:
        raise ValueError("Check out the snapshot's recorded commit before restoring resources.")
    pending = []
    needed_by_drive = defaultdict(int)
    for row in manifest["files"]:
        target = manifest_path(roots[row["area"]], row["path"])
        if target.exists():
            if not target.is_file() or target.stat().st_size != row["size"] or digest(target) != row["sha256"]:
                raise ValueError(f"Restore would overwrite a different file: {target}")
        else:
            source = snapshot / row["area"] / row["path"]
            drive = Path(target.anchor)
            needed_by_drive[drive] += row["size"]
            pending.append((source, target, row))
    for drive, needed in needed_by_drive.items():
        check_space(drive, needed)
    for source, target, row in pending:
        copy_checked(source, target, row["size"], row["sha256"])
    print(f"Restored {len(pending)} files. Existing matching files were reused.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "backup", "verify", "restore"])
    parser.add_argument("snapshot", nargs="?", type=Path)
    parser.add_argument("--project", default=PROJECT, type=Path)
    parser.add_argument("--profile", default=PROFILE, type=Path)
    args = parser.parse_args()
    if args.action != "plan" and args.snapshot is None:
        parser.error("Choose a snapshot directory.")
    roots = {"project": args.project.resolve(), "profile": args.profile.resolve()}
    try:
        if args.action in {"plan", "backup", "restore"}:
            top = Path(os.fsdecode(git(roots["project"], "rev-parse", "--show-toplevel")).strip()).resolve()
            if top != roots["project"]:
                raise ValueError("Use the Git repository root as --project.")
        if args.action == "plan":
            print_plan(inventory(**roots))
        elif args.action == "backup":
            backup(args.snapshot.resolve(), roots, inventory(**roots))
        elif args.action == "verify":
            verify(args.snapshot.resolve())
        else:
            restore(args.snapshot.resolve(), roots)
    except (OSError, ValueError, RuntimeError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
