#!/usr/bin/env python3
"""Executes a notebook from a fresh kernel and fails if any cell errors.

Required by `docs/architecture/IMPLEMENTATION_ROADMAP.md` section 3: every
maintained notebook "runs from a fresh kernel without hidden execution-order
state" and "is executed in an appropriate CI or scheduled validation tier."
Executing it is the only way to check that, since a notebook that is merely
read still rots as the API moves under it.

The executed copy is deliberately discarded. Phaser does not version notebook
outputs -- see decision 0015 -- so this script never writes the notebook back,
and a run therefore cannot dirty the working tree.

Uses nbclient and nbformat, approved in decision 0015 for exactly this job.
"""

import argparse
import pathlib
import sys

import nbformat
from nbclient import NotebookClient
from nbclient.exceptions import CellExecutionError


def execute(path, timeout):
    notebook = nbformat.read(path, as_version=4)
    client = NotebookClient(
        notebook,
        timeout=timeout,
        kernel_name="python3",
        # A cell that raises fails the build. Without this nbclient stores the
        # traceback as an output and exits zero, which would report a passing
        # notebook that does not run.
        allow_errors=False,
    )
    # The kernel starts in the notebook's own directory, which is what the
    # notebook assumes when it locates the committed example inputs.
    client.execute(cwd=str(path.parent))
    return notebook


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("notebooks", nargs="+", type=pathlib.Path)
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="per-cell timeout in seconds (default: 300)",
    )
    arguments = parser.parse_args(argv)

    failed = False
    for path in arguments.notebooks:
        if not path.exists():
            print(f"{path}: not found", file=sys.stderr)
            failed = True
            continue
        try:
            notebook = execute(path, arguments.timeout)
        except CellExecutionError as error:
            print(f"{path}: a cell failed\n{error}", file=sys.stderr)
            failed = True
        else:
            executed = sum(1 for cell in notebook.cells if cell.cell_type == "code")
            print(f"{path}: {executed} code cells executed")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
