"""Phaser's Python binding.

This package is a thin surface over the native extension, which is itself a
thin surface over Phaser's experimental C ABI. No physics, no numerics, and no
validation live here: every result comes from the same core the command-line
client and the C conformance client use.

ABI version 0 is experimental. Breaking changes are permitted while
``abi_experimental()`` returns True, and this package tracks them.
"""

from ._phaser import (  # noqa: F401
    abi_experimental,
    abi_version,
    library_version,
    model_metadata,
)

__all__ = [
    "abi_experimental",
    "abi_version",
    "library_version",
    "model_metadata",
]
