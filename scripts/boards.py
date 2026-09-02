#!/usr/bin/env python3
"""Everything derived from boards.yml, so nothing has to be written twice.

boards.yml is the source of truth for which boards runtt supports. This script
turns it into the things that used to be maintained by hand and in triplicate:

    --build-plan      what CI should build, one shell line per supported board
    --collect DIR     copy each provisioning artefact to its published asset name
    --release-notes   the markdown table that goes in the GitHub release
    --readme-table    the markdown section for README.md
    --write-readme    replace that section in README.md in place
    --check-readme    exit non-zero if README.md has drifted from boards.yml

The last one is the point. Generating a table is a convenience; a check that
fails the build when the copies disagree is what stops the drift, because
otherwise the generator is one more thing to remember to run.
"""
import argparse
import pathlib
import shutil
import subprocess
import sys

import yaml

REPO = pathlib.Path(__file__).resolve().parent.parent
MANIFEST = REPO / "boards.yml"
README = REPO / "README.md"
RELEASES = "https://github.com/shaunmulligan/runtt-boards/releases"

# The generated section is delimited so the surrounding prose stays hand-written.
BEGIN = "<!-- BEGIN GENERATED: supported devices (scripts/boards.py) -->"
END = "<!-- END GENERATED -->"


def load():
    with MANIFEST.open() as f:
        boards = yaml.safe_load(f)["boards"]
    for b in boards:
        missing = {"id", "name", "soc", "status"} - set(b)
        if missing:
            sys.exit(f"boards.yml: {b.get('name', b.get('id', '?'))} is missing {sorted(missing)}")
        if b["status"] == "supported":
            if not b.get("build") or not b.get("provision"):
                sys.exit(f"boards.yml: {b['name']} is `supported` but has no build/provision")
    return boards


def supported(boards):
    return [b for b in boards if b["status"] == "supported"]


def build_plan(boards):
    """One line per board. CI runs these in order."""
    for b in supported(boards):
        print(f"{b['build']['script']} {b['build']['mode']}")


def collect(boards, outdir):
    out = pathlib.Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    for b in supported(boards):
        for art in b["provision"]:
            src = REPO / art["from"]
            if not src.is_file():
                sys.exit(
                    f"{b['name']}: expected {art['from']} and it is not there.\n"
                    f"  Did `{b['build']['script']} {b['build']['mode']}` run first?"
                )
            shutil.copy2(src, out / art["as"])
            print(f"  {art['as']}  ({src.stat().st_size} bytes)")
    sums = subprocess.run(["sha256sum", *sorted(p.name for p in out.iterdir())],
                          cwd=out, capture_output=True, text=True, check=True)
    (out / "SHA256SUMS").write_text(sums.stdout)
    print("  SHA256SUMS")


def _rows(boards, link_base):
    rows = []
    for b in supported(boards):
        files = " + ".join(f"[`{a['as']}`]({link_base}/{a['as']})" for a in b["provision"])
        probe = "Yes, SWD" if b.get("probe") else "**No**"
        note = (b.get("notes") or "").strip()
        rows.append(f"| **{b['name']}** ({b['soc']}) | {files} | {probe} | {b['flash']}."
                    + (f" **{note}** " if b.get("probe") else f" {note}") + " |")
    return rows


def readme_table(boards):
    base = f"{RELEASES}/latest/download"
    lines = [
        BEGIN,
        "",
        "| Board | Download | Probe needed? | How |",
        "|---|---|---|---|",
        *_rows(boards, base),
        "",
        f"Check what you downloaded against [`SHA256SUMS`]({base}/SHA256SUMS). Those",
        f"links always resolve to the newest release; [older releases]({RELEASES}) stay",
        "available.",
    ]
    inprog = [b for b in boards if b["status"] == "in-progress"]
    if inprog:
        lines += ["", "**Being brought up**, not yet published:", ""]
        lines += [f"* **{b['name']}** ({b['soc']}) — {(b.get('notes') or '').strip()}"
                  for b in inprog]
    lines += ["", END]
    return "\n".join(lines)


def release_notes(boards):
    base = ""  # release notes sit next to the assets; plain names are enough
    rows = []
    for b in supported(boards):
        files = " and ".join(f"`{a['as']}`" for a in b["provision"])
        probe = "SWD probe" if b.get("probe") else "no probe needed"
        note = (b.get("notes") or "").strip()
        rows.append(f"| **{b['name']}** ({b['soc']}) | {files} | {b['flash']} "
                    f"({probe}). {note} |")
    _ = base
    return "\n".join([
        "| Board | File | How to flash |",
        "|---|---|---|",
        *rows,
    ])


def _splice(text, section):
    if BEGIN not in text or END not in text:
        sys.exit(f"README.md has no generated block. Add these markers:\n{BEGIN}\n{END}")
    head = text.split(BEGIN)[0]
    tail = text.split(END, 1)[1]
    return head + section + tail


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--build-plan", action="store_true")
    g.add_argument("--collect", metavar="DIR")
    g.add_argument("--release-notes", action="store_true")
    g.add_argument("--readme-table", action="store_true")
    g.add_argument("--write-readme", action="store_true")
    g.add_argument("--check-readme", action="store_true")
    args = ap.parse_args()

    boards = load()

    if args.build_plan:
        build_plan(boards)
    elif args.collect:
        collect(boards, args.collect)
    elif args.release_notes:
        print(release_notes(boards))
    elif args.readme_table:
        print(readme_table(boards))
    elif args.write_readme:
        README.write_text(_splice(README.read_text(), readme_table(boards)))
        print(f"  updated {README.name} from {MANIFEST.name}")
    elif args.check_readme:
        want = _splice(README.read_text(), readme_table(boards))
        if want != README.read_text():
            sys.exit("README.md has drifted from boards.yml.\n"
                     "  Run: scripts/boards.py --write-readme")
        print("  README.md matches boards.yml")


if __name__ == "__main__":
    sys.exit(main())
