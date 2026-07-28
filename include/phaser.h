/*
 * phaser.h -- Phaser's public C application binary interface.
 *
 * This header is the authoritative ABI contract. It is written and reviewed as
 * source rather than generated; see docs/decisions/0014-public-header-and-
 * toolchain-baseline.md. The Zig implementation is checked against this file by
 * layout, constant, and symbol tests, not the other way round.
 *
 * ABI version 0 is EXPERIMENTAL. Breaking changes are permitted while the
 * version is 0, and are recorded in release notes and visible through
 * phaser_abi_version(). Do not build a distributed product against it.
 *
 * Language baseline: C11, and includable from C++17. See
 * docs/architecture/LANGUAGE_AND_INTEROPERABILITY.md section 5.
 */

#ifndef PHASER_H
#define PHASER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Symbol visibility.
 *
 * PHASER_BUILD_SHARED is defined while building the shared library itself.
 * PHASER_SHARED is defined by consumers linking against it. Neither is defined
 * for static linkage. Windows is the reason this distinction exists at all: an
 * import declaration is not optional there, whereas ELF and Mach-O need only
 * the export side.
 */
#if defined(_WIN32)
#  if defined(PHASER_BUILD_SHARED)
#    define PHASER_API __declspec(dllexport)
#  elif defined(PHASER_SHARED)
#    define PHASER_API __declspec(dllimport)
#  else
#    define PHASER_API
#  endif
#else
#  if defined(PHASER_BUILD_SHARED)
#    define PHASER_API __attribute__((visibility("default")))
#  else
#    define PHASER_API
#  endif
#endif

/* ---------------------------------------------------------------------------
 * Versions
 * ------------------------------------------------------------------------- */

/* The ABI version this header declares. */
#define PHASER_ABI_VERSION 0u

/* Nonzero for as long as the ABI is experimental. */
#define PHASER_ABI_EXPERIMENTAL 1

/* Length in bytes of a model fingerprint. */
#define PHASER_FINGERPRINT_BYTES 32u

/* ---------------------------------------------------------------------------
 * Opaque handles
 *
 * Ownership is unique and non-shared: exactly one owner, exactly one
 * destructor, no retain or release. A handle derived from another does not
 * extend its parent's lifetime; each operation documents the required
 * outlives-relationship. Representations are private -- do not allocate, copy,
 * inspect, or free one except through the operations below.
 * ------------------------------------------------------------------------- */

typedef struct phaser_context     phaser_context;
typedef struct phaser_model       phaser_model;
typedef struct phaser_request     phaser_request;
typedef struct phaser_artifact    phaser_artifact;
typedef struct phaser_kernel      phaser_kernel;
typedef struct phaser_point       phaser_point;
typedef struct phaser_binding     phaser_binding;
typedef struct phaser_diagnostics phaser_diagnostics;

/* ---------------------------------------------------------------------------
 * Status
 *
 * Two status spaces exist and are never converted into one another. This one is
 * the control plane: whether a call was structurally well formed. The per-point
 * numerical space below reports what happened to a given evaluation point. A
 * negative eigenvalue is a successful complex result, not a failed call, and
 * collapsing the two would discard that distinction at the boundary.
 * ------------------------------------------------------------------------- */

typedef enum phaser_status {
    PHASER_STATUS_OK = 0,
    /* Null handle, bad length, misaligned or overlapping caller buffer. */
    PHASER_STATUS_INVALID_ARGUMENT = 1,
    /* Parse or validation failed. This is the only status that promises
       diagnostics; every other status writes NULL to the out parameter. */
    PHASER_STATUS_INVALID_SOURCE = 2,
    /* Outside the explicitly supported domain. */
    PHASER_STATUS_UNSUPPORTED = 3,
    /* A declared resource limit was reached. */
    PHASER_STATUS_LIMIT_EXCEEDED = 4,
    /* A caller buffer or workspace is too small. Reported before any output is
       written, and an ordinary result rather than an error to avoid. */
    PHASER_STATUS_INSUFFICIENT_SPACE = 5,
    PHASER_STATUS_OUT_OF_MEMORY = 6,
    /* Contained invariant failure. Never a disguised scientific result. */
    PHASER_STATUS_INTERNAL = 7
} phaser_status;

/*
 * Per-point numerical outcome. Mirrors the kernel's internal status value for
 * value; a conformance test asserts the two agree, so drift fails at build time
 * rather than at a user's boundary.
 *
 * A client MUST treat an unrecognized value as a failure of its kind rather
 * than as success.
 */
typedef enum phaser_point_status {
    PHASER_POINT_OK = 0,
    PHASER_POINT_NON_FINITE = 1,
    PHASER_POINT_DIVISION_BY_ZERO = 2,
    /* A bounded numerical operation exhausted its convergence contract. */
    PHASER_POINT_NONCONVERGENT = 3,
    /* A requested derivative is mathematically singular, including an
       uncancelled zero-mode scalar Hessian term. */
    PHASER_POINT_SINGULAR_DERIVATIVE = 4
} phaser_point_status;

/* Diagnostic severity. Mirrors the internal enum. */
typedef enum phaser_severity {
    PHASER_SEVERITY_ERROR = 0,
    PHASER_SEVERITY_WARNING = 1,
    PHASER_SEVERITY_NOTE = 2
} phaser_severity;

/* Diagnostic category. Mirrors the internal enum. */
typedef enum phaser_category {
    PHASER_CATEGORY_SOURCE = 0,
    PHASER_CATEGORY_CAPACITY = 1,
    PHASER_CATEGORY_ALLOCATION = 2,
    PHASER_CATEGORY_CONFIGURATION = 3,
    PHASER_CATEGORY_JSON = 4,
    PHASER_CATEGORY_EXPRESSION = 5,
    PHASER_CATEGORY_MODEL = 6,
    PHASER_CATEGORY_CALCULATION = 7
} phaser_category;

/* ---------------------------------------------------------------------------
 * Extensible structures
 *
 * Each begins with struct_size and abi_version. The caller sets struct_size to
 * sizeof the struct it was compiled against; the implementation reads or writes
 * only fields present in that size. Reserved fields MUST be zero.
 * ------------------------------------------------------------------------- */

typedef struct phaser_context_options {
    uint32_t struct_size;
    uint32_t abi_version;
    /* Maximum diagnostics retained for one failed operation. Must be nonzero. */
    uint64_t max_diagnostics;
    /* Maximum related source locations across those diagnostics. */
    uint64_t max_related_locations;
} phaser_context_options;

typedef struct phaser_diagnostic {
    uint32_t struct_size;
    uint32_t abi_version;
    /* Stable numeric diagnostic code. */
    uint32_t code;
    /* One of phaser_category. */
    int32_t category;
    /* One of phaser_severity. */
    int32_t severity;
    /* Nonzero when the primary span fields are meaningful. */
    int32_t has_primary;
    uint32_t primary_source_id;
    uint32_t primary_start;
    uint32_t primary_end;
    /* Number of related source locations attached to this diagnostic. */
    uint32_t related_count;
    uint32_t reserved;
} phaser_diagnostic;

/* ---------------------------------------------------------------------------
 * Version and capability queries
 *
 * Infallible, callable before any context exists, and safe from any thread.
 * ------------------------------------------------------------------------- */

/* Returns the ABI version of the loaded library, which a caller compares
   against PHASER_ABI_VERSION to detect a header/library mismatch. */
PHASER_API uint32_t phaser_abi_version(void);

/* Returns nonzero for as long as the ABI is experimental. Separate from the
   version so that declaring version 1 and dropping the experimental marker are
   distinguishable events. */
PHASER_API int phaser_abi_experimental(void);

/* Library version, reported separately from the ABI version. Any pointer may
   be NULL. */
PHASER_API void phaser_library_version(uint32_t *major,
                                       uint32_t *minor,
                                       uint32_t *patch);

/* ---------------------------------------------------------------------------
 * Context
 *
 * Owns control-plane allocation policy and resource limits. There is no global
 * default context and no process-global mutable state. Separate contexts are
 * usable concurrently.
 * ------------------------------------------------------------------------- */

/*
 * Creates a context. `options` may be NULL for documented defaults. On success
 * writes a handle the caller owns; on failure writes NULL.
 *
 * Returns INVALID_ARGUMENT if out_context is NULL, if options->struct_size is
 * smaller than the first two fields or larger than this version understands, or
 * if a limit is zero.
 */
PHASER_API phaser_status phaser_context_create(
    const phaser_context_options *options,
    phaser_context **out_context);

/* Destroys a context. NULL is a no-op. Every handle derived from this context
   must already have been destroyed. */
PHASER_API void phaser_context_destroy(phaser_context *context);

/* ---------------------------------------------------------------------------
 * Model
 * ------------------------------------------------------------------------- */

/*
 * Parses and validates a model from UTF-8 JSON source. `source` and
 * `source_length` describe the bytes; embedded null bytes are permitted and are
 * ordinary content.
 *
 * On PHASER_STATUS_OK writes a model the caller owns and NULL diagnostics. On
 * PHASER_STATUS_INVALID_SOURCE writes NULL model and a diagnostics handle the
 * caller owns. On any other status both out parameters are NULL.
 *
 * out_diagnostics may be NULL if the caller does not want them; the parse still
 * reports INVALID_SOURCE.
 *
 * Both out parameters are cleared before any validation, so that a caller which
 * ignores the status reads NULL rather than a stale pointer. The consequence is
 * that an out parameter MUST NOT alias a handle the caller still owns: passing
 * the address of a live phaser_model * overwrites it and leaks it.
 *
 * The returned model does not borrow from `source`; the caller may free the
 * source bytes immediately. The model must not outlive its context.
 */
PHASER_API phaser_status phaser_model_load(
    phaser_context *context,
    const void *source,
    size_t source_length,
    phaser_model **out_model,
    phaser_diagnostics **out_diagnostics);

/* Destroys a model. NULL is a no-op. */
PHASER_API void phaser_model_destroy(phaser_model *model);

/*
 * Writes the model's deterministic fingerprint. `out_bytes` must have room for
 * PHASER_FINGERPRINT_BYTES; `capacity` is checked and a smaller buffer reports
 * PHASER_STATUS_INSUFFICIENT_SPACE without writing.
 */
PHASER_API phaser_status phaser_model_fingerprint(const phaser_model *model,
                                                  uint8_t *out_bytes,
                                                  size_t capacity);

/* Typed counts, so a consumer need not parse metadata JSON to size a buffer. */
PHASER_API phaser_status phaser_model_parameter_count(const phaser_model *model,
                                                      size_t *out_count);
PHASER_API phaser_status phaser_model_scalar_field_count(
    const phaser_model *model,
    size_t *out_count);

/* ---------------------------------------------------------------------------
 * Diagnostics
 *
 * A diagnostics handle is immutable once produced and owned by the caller. It
 * does not borrow from the source buffer it describes. There is no "last error"
 * state, global or thread-local.
 *
 * Typed access is the primary path; rendering is a convenience over it.
 * ------------------------------------------------------------------------- */

/* Destroys a diagnostics handle. NULL is a no-op. */
PHASER_API void phaser_diagnostics_destroy(phaser_diagnostics *diagnostics);

/* Number of diagnostics in the handle. */
PHASER_API phaser_status phaser_diagnostics_count(
    const phaser_diagnostics *diagnostics,
    size_t *out_count);

/*
 * Copies diagnostic `index` into `out_diagnostic`, whose struct_size the caller
 * sets before the call. Reports INVALID_ARGUMENT for an out-of-range index.
 */
PHASER_API phaser_status phaser_diagnostics_at(
    const phaser_diagnostics *diagnostics,
    size_t index,
    phaser_diagnostic *out_diagnostic);

/*
 * Renders diagnostic `index` as UTF-8 text into `buffer`.
 *
 * Writes the byte length that was or would be written to `out_length` when it is
 * not NULL. If `buffer` is NULL, or `capacity` is smaller than the rendering,
 * reports PHASER_STATUS_INSUFFICIENT_SPACE and writes the required length --
 * so the ordinary sizing call passes NULL and reads out_length. No null
 * terminator is written; the length is authoritative.
 */
PHASER_API phaser_status phaser_diagnostics_render(
    const phaser_diagnostics *diagnostics,
    size_t index,
    void *buffer,
    size_t capacity,
    size_t *out_length);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* PHASER_H */
