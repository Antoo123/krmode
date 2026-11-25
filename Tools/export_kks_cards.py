"""Prepare portable cards from UserData/chara and DefaultData/chara."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from pack_portable_card import pack


def write_index(output, cards):
    temporary = output / "catalog.json.new"
    temporary.write_text(json.dumps(cards, ensure_ascii=False, indent=2), encoding="utf-8")
    temporary.replace(output / "catalog.json")


def export(game, output, stage_sources):
    output.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="Myproject-card-library-"))
    tasks = {}
    cards = []
    for folder in ("UserData", "DefaultData"):
        source = game / folder / "chara"
        for card in sorted(source.rglob("*.png")):
            digest = hashlib.sha256(card.read_bytes()).hexdigest()
            original = card.relative_to(source)
            relative = Path(folder) / original
            portable = output / relative
            status = "ready" if portable.is_file() else "pending"
            row = {"source": relative.as_posix(), "path": relative.as_posix(), "sha256": digest, "status": status}
            cards.append(row)
            if status == "pending":
                model = scratch / (digest + ".kcs")
                tasks.setdefault(digest, (card, model, []))[2].append(row)

    write_index(output, cards)
    if not tasks:
        return 0
    environment = os.environ.copy()
    environment.pop("MYPROJECT_KKS_COMPARE", None)
    environment.pop("MYPROJECT_KKS_WARDROBE", None)
    importer = Path(__file__).with_name("import_kks_card.ps1")
    jobs = list(tasks.values())
    processes = []
    for index, stage_source in enumerate(stage_sources):
        subset = jobs[index::len(stage_sources)]
        if not subset:
            continue
        plan = scratch / f"plan-{index}.txt"
        lines = []
        for card, model, _rows in subset:
            lines.extend((str(card), "255", "-1", str(model), ""))
        plan.write_text("\n".join(lines) + "\n", encoding="utf-8")
        command = [
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(importer),
            "-GameRoot", str(stage_source), "-BatchPlan", str(plan), "-TimeoutSeconds", "7200",
        ]
        log_name = "import.log" if index == 0 else f"import-{index + 1}.log"
        with (output / log_name).open("wb") as log:
            processes.append(subprocess.Popen(command, env=environment, stdout=log, stderr=subprocess.STDOUT))

    print(f"{len(cards)} cards, {len(tasks)} captures, {len(processes)} Studio processes.", flush=True)
    while tasks:
        finished = all(process.poll() is not None for process in processes)
        changed = False
        for digest, (card, model, rows) in list(tasks.items()):
            if not model.is_file():
                if finished:
                    for row in rows:
                        row["status"] = "failed"
                    changed = True
                continue
            for row in rows:
                portable = output / row["path"]
                temporary = portable.with_name(portable.name + ".pending")
                try:
                    portable.parent.mkdir(parents=True, exist_ok=True)
                    temporary.unlink(missing_ok=True)
                    pack(card, model, temporary)
                    temporary.replace(portable)
                except (OSError, ValueError) as error:
                    row["status"] = "failed"
                    print(f"{row['source']}: {error}", flush=True)
                else:
                    row["status"] = "ready"
            del tasks[digest]
            changed = True
        if changed:
            write_index(output, cards)
            print(f"Ready: {sum(row['status'] == 'ready' for row in cards)} / {len(cards)}", flush=True)
        if finished:
            break
        if tasks:
            time.sleep(2)
    codes = [process.wait() for process in processes]
    return int(any(codes) or any(row["status"] == "failed" for row in cards))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--stage-source", type=Path, action="append",
                        help="Path to the same installed game for a separate staging cache. Repeat to run two batches.")
    args = parser.parse_args()
    game = args.game.absolute()
    stage_sources = list(dict.fromkeys(path.absolute() for path in (args.stage_source or [game])))
    raise SystemExit(export(game, args.output.resolve(), stage_sources))
