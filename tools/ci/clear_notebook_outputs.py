#!/usr/bin/env python3
"""Strips stored outputs from a notebook, in place.

Run this after opening a notebook and looking at it, before committing. Phaser
does not version notebook outputs, and a frontend stores them on save;
`check_notebook_outputs.py` fails the build if any survive.

Standard library only, and it rewrites nothing but the fields it clears: cell
sources, metadata, and formatting are left byte-identical wherever possible, so
the diff of a cleared notebook is the outputs and nothing else.
"""

import json
import pathlib
import sys


def clear(document):
    """Returns the number of cells changed."""
    changed = 0
    for cell in document.get("cells", []):
        if cell.get("cell_type") != "code":
            continue
        touched = False
        if cell.get("outputs"):
            cell["outputs"] = []
            touched = True
        if cell.get("execution_count") is not None:
            cell["execution_count"] = None
            touched = True
        # Frontends record per-cell execution timings here, which are both
        # nondeterministic and uninteresting.
        metadata = cell.get("metadata", {})
        for key in ("execution", "ExecuteTime"):
            if key in metadata:
                del metadata[key]
                touched = True
        changed += 1 if touched else 0
    return changed


def main(argv=None):
    paths = [pathlib.Path(argument) for argument in (argv or sys.argv[1:])]
    if not paths:
        paths = sorted(pathlib.Path("docs/notebooks").rglob("*.ipynb"))
    if not paths:
        print("no notebooks given and none found under docs/notebooks", file=sys.stderr)
        return 1

    for path in paths:
        text = path.read_text(encoding="utf-8")
        document = json.loads(text)
        changed = clear(document)
        if changed == 0:
            print(f"{path}: already clear")
            continue
        # A trailing newline, and the indentation Jupyter itself writes, so
        # that clearing a notebook does not reformat the whole file.
        path.write_text(
            json.dumps(document, indent=1, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"{path}: cleared {changed} cell(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
