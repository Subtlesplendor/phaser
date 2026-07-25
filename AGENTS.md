# Phaser Agent Instructions

These instructions apply to the entire repository.

Before implementing or reviewing Phaser, read
[Phaser Engineering Style](ENGINEERING_STYLE.md),
[Phaser Development Workflow](DEVELOPMENT_WORKFLOW.md), and the specification
relevant to the subsystem being changed.

## External dependencies

Do not add, download, vendor, link, or declare a new external dependency without
the user's explicit permission. This includes runtime, build, test, benchmark,
fuzzing, code-generation, documentation, developer-tool, optional, and system
dependencies.

Before requesting permission, provide the dependency proposal required by the
“Dependencies” section of
[Phaser Engineering Style](ENGINEERING_STYLE.md): exact dependency and source,
purpose, internal alternative, justification, license and maintenance risks,
runtime behavior relevant to Phaser, and the boundary behind which it will be
isolated.

The pinned Zig compiler and Zig standard library are exempt. An already approved
dependency may be used only within its recorded scope. Changing its source,
version, enabled features, transitive dependency set, or role requires renewed
permission.

Reading public documentation or source to evaluate a dependency is allowed and
does not constitute adoption.
