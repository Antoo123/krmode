"""Bake NPC body animation tracks from a Koikatsu Sunshine catalog."""

import argparse
from collections import defaultdict
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from zipfile import ZipFile

VENDOR = Path(__file__).with_name("vendor")
if VENDOR.is_dir():
    sys.path.insert(0, str(VENDOR))

def compile_plugin(stage):
    source = Path(__file__).with_name("KksLibraryCapture.cs")
    managed = stage / "CharaStudio_Data" / "Managed"
    compiler = Path(os.environ["WINDIR"]) / "Microsoft.NET/Framework64/v4.0.30319/csc.exe"
    plugins = stage / "BepInEx/plugins"
    refs = [stage / "BepInEx/core/BepInEx.dll", managed / "UnityEngine.dll"]
    refs += [managed / f"UnityEngine.{name}.dll" for name in ("CoreModule", "AnimationModule", "AssetBundleModule")]
    target = plugins / "KksLibraryCapture.dll"
    if target.exists() and target.stat().st_mtime >= source.stat().st_mtime:
        return
    subprocess.run([str(compiler), "/nologo", "/target:library", f"/out:{target}",
                    *(f"/reference:{ref}" for ref in refs), str(source)], check=True)


def prepare_stage(game, stage):
    stage.mkdir(parents=True, exist_ok=True)
    for name in ("CharaStudio.exe", "UnityPlayer.dll", "UnityCrashHandler64.exe", "winhttp.dll", "doorstop_config.ini"):
        if not (stage / name).exists():
            shutil.copy2(game / name, stage / name)
    for name in ("CharaStudio_Data", "MonoBleedingEdge", "BepInEx/core"):
        if not (stage / name).exists():
            shutil.copytree(game / name, stage / name)
    for name in ("abdata", "DefaultData"):
        if not (stage / name).exists():
            source = str(game / name).replace("'", "''")
            target = str(stage / name).replace("'", "''")
            command = f"New-Item -ItemType Junction -Path '{target}' -Target '{source}' | Out-Null"
            subprocess.run(["powershell.exe", "-NoProfile", "-Command", command], check=True)
    (stage / "BepInEx/plugins").mkdir(parents=True, exist_ok=True)


def unpack_bundle(game, stage, bundle, archive):
    if not archive:
        return game / bundle
    cache = stage / "bundles"
    cache.mkdir(exist_ok=True)
    key = hashlib.sha256(f"{archive}:{bundle}".encode()).hexdigest()[:32]
    output = cache / f"{key}.unity3d"
    if not output.exists():
        partial = output.with_suffix(".partial")
        with ZipFile(game / archive) as file, file.open(bundle) as source, partial.open("wb") as dest:
            shutil.copyfileobj(source, dest)
        partial.replace(output)
    return output


def register_clip_paths(path, stage):
    import UnityPy

    aliases = stage / "indexed"
    aliases.mkdir(exist_ok=True)
    identity = f"{path}:{path.stat().st_size}:{path.stat().st_mtime_ns}"
    key = hashlib.sha256(identity.encode()).hexdigest()[:32]
    output = aliases / f"{key}.unity3d"
    if output.exists():
        return output
    env = UnityPy.load(str(path))
    manifest = next(obj for obj in env.objects if obj.type.name == "AssetBundle")
    bundle = manifest.read()
    info_type = type(bundle.m_Container[0][1])
    pointer_type = type(bundle.m_Container[0][1].asset)
    for obj in env.objects:
        if obj.type.name != "AnimationClip" or obj.assets_file != manifest.assets_file:
            continue
        pointer = pointer_type(m_FileID=0, m_PathID=obj.path_id, assetsfile=manifest.assets_file)
        info = info_type(asset=pointer, preloadIndex=len(bundle.m_PreloadTable), preloadSize=1)
        bundle.m_PreloadTable.append(pointer)
        bundle.m_Container.append((clip_alias(obj.path_id), info))
    bundle.m_Container.sort(key=lambda entry: entry[0])
    bundle.save()
    partial = output.with_suffix(".partial")
    partial.write_bytes(env.file.save(packer="lz4"))
    partial.replace(output)
    return output


def clip_alias(object_id):
    return f"assets/myproject/clip_{object_id}.anim"


def convert(game, stage, catalog, output, ids, sources, exact, scope, shard, decode_first):
    rows = json.loads(catalog.read_text(encoding="utf-8"))["clips"]
    keep = set(ids)
    selected = [row for row in rows if (not keep and not sources) or row["id"] in keep or
                any(text.casefold() in (row["bundle"] + " " + (row["archive"] or "")).casefold() for text in sources)]
    if scope != "all":
        selected = [row for row in selected if bool(row["archive"]) == (scope == "mods")]
    if shard:
        index, count = (int(value) for value in shard.split("/"))
        if not 0 <= index < count:
            raise SystemExit("Shard index must be between 0 and count-1")
        selected = [row for row in selected if int(hashlib.sha256(
            f"{row['archive']}:{row['bundle']}".encode()).hexdigest()[:8], 16) % count == index]
    if not selected:
        raise SystemExit("No entries matched")
    if decode_first:
        try:
            from decode_kks_motions import run
            run(game, catalog, output, {row["id"] for row in selected})
        except (ImportError, OSError, ValueError) as error:
            print(f"Direct curve decoder unavailable ({error}), using Studio capture.", flush=True)
        if all((output / (row["id"] + ".kma")).is_file() for row in selected):
            return
    prepare_stage(game, stage)
    compile_plugin(stage)
    output.mkdir(parents=True, exist_ok=True)
    report = output / (f"conversion-{scope}-{shard.replace('/', '-')}.tsv" if shard else "conversion.tsv")
    bundles = defaultdict(list)
    for row in selected:
        if not (output / (row["id"] + ".kma")).exists():
            bundles[(row["bundle"], row["archive"])].append(row)

    plan = [str(game / "abdata/chara/oo_base.unity3d"), str(report)]
    for (bundle, archive), members in bundles.items():
        path = unpack_bundle(game, stage, bundle, archive)
        use_aliases = exact
        if use_aliases:
            try:
                path = register_clip_paths(path, stage)
            except Exception as error:
                print(f"{bundle}: exact index unavailable ({error}); trying controller names.", flush=True)
                use_aliases = False
        for row in members:
            line = f"{path}\t{row['name']}\t{output / (row['id'] + '.kma')}"
            if use_aliases:
                line += "\t" + clip_alias(row["object_id"])
            plan.append(line)
    if len(plan) > 2:
        plan_file = stage / "library-plan.txt"
        plan_file.write_text("\n".join(plan) + "\n", encoding="utf-8")
        env = dict(os.environ, MYPROJECT_KKS_LIBRARY_PLAN=str(plan_file))
        log = stage / "library.log"
        with subprocess.Popen([str(stage / "CharaStudio.exe"), "-batchmode", "-nographics", "-logFile", str(log)],
                              cwd=stage, env=env, creationflags=subprocess.CREATE_NO_WINDOW) as studio:
            exit_code = studio.wait()
        if exit_code != 0:
            raise SystemExit(f"Motion converter exited {exit_code}. See {log}")
    count = sum((output / (row["id"] + ".kma")).is_file() for row in selected)
    print(f"{count} of {len(selected)} selected entries have playable body tracks. Report: {report}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("catalog", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--stage", type=Path, required=True)
    parser.add_argument("--id", action="append", default=[])
    parser.add_argument("--source", action="append", default=[])
    parser.add_argument("--exact", action="store_true", help="Open the exact animation object ID. Requires UnityPy.")
    parser.add_argument("--scope", choices=("all", "base", "mods"), default="all")
    parser.add_argument("--shard", help="Zero-based bundle shard, for example 0/2.")
    parser.add_argument("--decode-first", action="store_true", help="Try direct generic-curve decoding before starting Studio.")
    args = parser.parse_args()
    convert(args.game.resolve(), args.stage.resolve(), args.catalog, args.output.resolve(), args.id, args.source,
            args.exact, args.scope, args.shard, args.decode_first)
