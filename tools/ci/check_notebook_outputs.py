#!/usr/bin/env python3
"""Fails if a committed notebook carries stored outputs or execution counts.

Phaser does not version notebook outputs. A notebook is committed as source and
executed by the reader or by CI; the rendered figures, printed numbers, and
base64 images stay out of the history.

That policy needs a guard, because saving a notebook from a frontend stores
outputs by default. Without this check the first person to open one and press
save commits a few hundred kilobytes of base64 PNG, and the second person's diff
is unreadable.

Standard library only, so this runs in the repository-checks tier alongside the
Markdown and whitespace checks, with no Python environment to install.
"""

import json
import pathlib
import sys

NOTEBOOK_ROOT = pathlib.Path("docs/notebooks")


def offences(path):
    """Yields a human-readable reason per offending cell."""
    document = json.loads(path.read_text(encoding="utf-8"))
    for index, cell in enumerate(document.get("cells", [])):
        if cell.get("cell_type") != "code":
            continue
        if cell.get("outputs"):
            yield f"cell {index} stores {len(cell['outputs'])} output(s)"
        if cell.get("execution_count") is not None:
            yield f"cell {index} stores execution_count {cell['execution_count']}"


def main():
    notebooks = sorted(NOTEBOOK_ROOT.rglob("*.ipynb"))
    if not notebooks:
        # Not an error: the tier exists before the first notebook does, and a
        # check that silently passes on an empty set is fine as long as it says
        # so rather than claiming to have checked something.
        print(f"no notebooks under {NOTEBOOK_ROOT}")
        return 0

    failed = False
    for path in notebooks:
        try:
            found = list(offences(path))
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            print(f"{path}: not readable as a notebook: {error}", file=sys.stderr)
            failed = True
            continue
        for reason in found:
            print(f"{path}: {reason}", file=sys.stderr)
            failed = True

    if failed:
        print(
            "\nCommitted notebooks must carry no outputs. Clear them before "
            "committing, for example with:\n"
            "  python3 tools/ci/clear_notebook_outputs.py <notebook>",
            file=sys.stderr,
        )
        return 1

    print(f"Checked {len(notebooks)} notebook(s); none stores outputs.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
