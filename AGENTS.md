# Phaser Agent Instructions

These instructions apply to the entire repository.

Before implementing or reviewing Phaser, read the "Quick reference" table near
the top of [Phaser Engineering Style](ENGINEERING_STYLE.md) and of
[Phaser Development Workflow](DEVELOPMENT_WORKFLOW.md), then read only the
sections those tables point to for the change at hand, plus the specification
relevant to the subsystem being changed. [docs/AGENT_GUIDE.md](docs/AGENT_GUIDE.md)
routes source and test paths to the exact document and heading that governs
them; [docs/README.md](docs/README.md) indexes whole documents by subsystem
and implementation status for anything not covered there. Read a document in
full only when its own scope requires that (for example, when reviewing the
style guide or workflow document itself, or when a change is broad enough
that most sections apply).

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
