#!/usr/bin/env python3
"""Checks committed notebooks for stored outputs and for private API use.

Two properties, both of which a notebook loses silently.

**No stored outputs.** Phaser does not version them. A notebook is committed as
source and executed by the reader or by CI; the rendered figures, printed
numbers, and base64 images stay out of the history. This needs a guard because
saving from a frontend stores outputs by default -- without it the first person
to open one and press save commits a few hundred kilobytes of base64 PNG, and
the second person's diff is unreadable.

**Public interfaces only.** Roadmap section 3 requires every maintained notebook
to use only public Phaser interfaces, and section 8 makes it a Milestone 4 exit
criterion. Reaching past the package into the extension or into a capsule would
still run, and would still look like a working example, while demonstrating
something no user should copy.

Standard library only, so this runs in the repository-checks tier alongside the
Markdown and whitespace checks, with no Python environment to install.
"""

import json
import pathlib
import sys

NOTEBOOK_ROOT = pathlib.Path("docs/notebooks")

# Substrings that mean a notebook has reached past the public package. The
# extension module and the capsule attribute are the two ways in; both are
# spelled with a leading underscore precisely so that this check can be a
# textual one.
PRIVATE_MARKERS = ("_phaser", "._capsule", "phaser._")


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
        source = "".join(cell.get("source", []))
        for marker in PRIVATE_MARKERS:
            if marker in source:
                yield f"cell {index} reaches past the public API: {marker!r}"


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
            "\nA committed notebook must carry no outputs and must use only "
            "public Phaser interfaces.\n"
            "To clear stored outputs:\n"
            "  python3 tools/ci/clear_notebook_outputs.py <notebook>\n"
            "Private API use has to be rewritten against the public package; "
            "see docs/architecture/IMPLEMENTATION_ROADMAP.md section 3.",
            file=sys.stderr,
        )
        return 1

    print(
        f"Checked {len(notebooks)} notebook(s): no stored outputs, "
        "no private API use."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
