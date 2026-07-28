/*
 * abi_client.c -- a C consumer of the Phaser C ABI.
 *
 * This is a conformance consumer, not an alternate implementation: it contains
 * no physics and computes nothing itself. It exists to prove that a real C
 * program, compiled by a compiler that is not Zig and linked against either
 * library product, can drive the boundary and observe what the header promises.
 *
 * It grows with the ABI. Today it covers the version, context, model, and
 * diagnostics operations; derive, compile, bind, and evaluate join it as those
 * handles are added.
 *
 * Exit status is 0 when every check held, 1 otherwise, and every failure prints
 * what it expected. Build it with:
 *
 *   cc -std=c11 -Iinclude examples/c/abi_client.c zig-out/lib/libphaser.a -o client
 */

#include <stdio.h>
#include <string.h>

#include "phaser.h"

static int failures = 0;

static void check(int condition, const char *what) {
    if (condition) {
        printf("  ok    %s\n", what);
    } else {
        printf("  FAIL  %s\n", what);
        failures++;
    }
}

/* A small valid model. Two parameters and one real scalar field. */
static const char valid_model[] =
    "{\n"
    "  \"schema\": \"phaser.qft-model/0.1\",\n"
    "  \"spacetime_dimension\": 4,\n"
    "  \"conventions\": {\n"
    "    \"metric\": \"mostly_plus\",\n"
    "    \"scalar_representation\": \"real_components\",\n"
    "    \"fermions\": \"two_component_weyl\"\n"
    "  },\n"
    "  \"parameters\": {\n"
    "    \"lambda\": {\"domain\": \"real\", \"mass_dimension\": 0},\n"
    "    \"m2\": {\"domain\": \"real\", \"mass_dimension\": 2}\n"
    "  },\n"
    "  \"fields\": {\n"
    "    \"real_scalars\": [{\"id\": \"phi\"}],\n"
    "    \"weyl_fermions\": [],\n"
    "    \"gauge_vectors\": []\n"
    "  },\n"
    "  \"tensors\": {\n"
    "    \"scalar_mass_squared\": {\n"
    "      \"components\": [{\"indices\": [\"phi\", \"phi\"], \"value\": \"m2\"}]\n"
    "    },\n"
    "    \"scalar_quartic\": {\n"
    "      \"components\": [\n"
    "        {\"indices\": [\"phi\", \"phi\", \"phi\", \"phi\"], \"value\": \"lambda\"}\n"
    "      ]\n"
    "    }\n"
    "  }\n"
    "}\n";

static void check_versions(void) {
    uint32_t major = 0xffffffffu;
    uint32_t minor = 0xffffffffu;
    uint32_t patch = 0xffffffffu;

    printf("versions\n");
    check(phaser_abi_version() == PHASER_ABI_VERSION,
          "library ABI version matches the header it was built against");
    check(phaser_abi_experimental() != 0,
          "ABI version 0 reports itself as experimental");

    phaser_library_version(&major, &minor, &patch);
    check(major != 0xffffffffu && minor != 0xffffffffu && patch != 0xffffffffu,
          "library version is written to every requested field");

    /* Every pointer is documented as optional. */
    phaser_library_version(NULL, NULL, NULL);
    check(1, "library version tolerates null out parameters");
}

static void check_valid_model(phaser_context *context) {
    phaser_model *model = NULL;
    phaser_diagnostics *diagnostics = NULL;
    uint8_t fingerprint[PHASER_FINGERPRINT_BYTES];
    uint8_t again[PHASER_FINGERPRINT_BYTES];
    size_t parameters = 0;
    size_t scalars = 0;
    phaser_status status;

    printf("valid model\n");
    status = phaser_model_load(context, valid_model, strlen(valid_model),
                               &model, &diagnostics);
    check(status == PHASER_STATUS_OK, "a valid model loads");
    check(model != NULL, "a model handle is produced");
    check(diagnostics == NULL, "success produces no diagnostics");
    if (model == NULL) {
        return;
    }

    check(phaser_model_parameter_count(model, &parameters) == PHASER_STATUS_OK &&
              parameters == 2,
          "the model reports its two parameters");
    check(phaser_model_scalar_field_count(model, &scalars) == PHASER_STATUS_OK &&
              scalars == 1,
          "the model reports its one real scalar field");

    check(phaser_model_fingerprint(model, fingerprint, sizeof fingerprint) ==
              PHASER_STATUS_OK,
          "the fingerprint is written into an exactly sized buffer");
    check(phaser_model_fingerprint(model, again, sizeof again - 1) ==
              PHASER_STATUS_INSUFFICIENT_SPACE,
          "one byte less is a reported capacity failure");

    phaser_model_destroy(model);
}

static void check_invalid_model(phaser_context *context) {
    phaser_model *model = NULL;
    phaser_diagnostics *diagnostics = NULL;
    phaser_diagnostic entry;
    size_t count = 0;
    size_t required = 0;
    phaser_status status;
    char rendered[512];

    printf("invalid model\n");
    status = phaser_model_load(context, "{ not json", 10, &model, &diagnostics);
    check(status == PHASER_STATUS_INVALID_SOURCE,
          "invalid source is reported as such");
    check(model == NULL, "no model handle is produced");
    check(diagnostics != NULL, "diagnostics are produced");
    if (diagnostics == NULL) {
        return;
    }

    check(phaser_diagnostics_count(diagnostics, &count) == PHASER_STATUS_OK &&
              count > 0,
          "at least one diagnostic is reported");

    memset(&entry, 0, sizeof entry);
    entry.struct_size = (uint32_t)sizeof entry;
    check(phaser_diagnostics_at(diagnostics, 0, &entry) == PHASER_STATUS_OK,
          "the first diagnostic is readable through the typed query");
    check(entry.code != 0, "the diagnostic carries a code");
    check(entry.severity >= 0 && entry.severity <= 2,
          "the diagnostic carries a known severity");

    check(phaser_diagnostics_at(diagnostics, count, &entry) ==
              PHASER_STATUS_INVALID_ARGUMENT,
          "an out-of-range index is rejected");

    /* The documented sizing call: null buffer, read the required length. */
    check(phaser_diagnostics_render(diagnostics, 0, NULL, 0, &required) ==
              PHASER_STATUS_INSUFFICIENT_SPACE &&
              required > 0,
          "rendering reports the length it needs");
    if (required <= sizeof rendered) {
        size_t written = 0;
        check(phaser_diagnostics_render(diagnostics, 0, rendered,
                                        sizeof rendered, &written) ==
                  PHASER_STATUS_OK &&
                  written == required,
              "rendering fills a large enough buffer exactly");
        printf("        rendered: %.*s\n", (int)written, rendered);
    }

    phaser_diagnostics_destroy(diagnostics);
}

static void check_misuse(phaser_context *context) {
    size_t count = 0;

    printf("misuse is reported, not undefined\n");
    check(phaser_context_create(NULL, NULL) == PHASER_STATUS_INVALID_ARGUMENT,
          "a null out parameter is rejected");
    check(phaser_model_parameter_count(NULL, &count) ==
              PHASER_STATUS_INVALID_ARGUMENT,
          "a null model handle is rejected");
    check(phaser_diagnostics_count(NULL, &count) ==
              PHASER_STATUS_INVALID_ARGUMENT,
          "a null diagnostics handle is rejected");

    /* A context passed where a model is expected. Handles carry a type tag so
       this is reported rather than misinterpreted as a struct of another kind. */
    check(phaser_model_parameter_count((const phaser_model *)context, &count) ==
              PHASER_STATUS_INVALID_ARGUMENT,
          "a handle of the wrong type is rejected");

    /* Destroying NULL is documented as a no-op everywhere. */
    phaser_context_destroy(NULL);
    phaser_model_destroy(NULL);
    phaser_diagnostics_destroy(NULL);
    check(1, "destroying a null handle is a no-op");
}

int main(void) {
    phaser_context *context = NULL;
    phaser_context_options options;

    check_versions();

    memset(&options, 0, sizeof options);
    options.struct_size = (uint32_t)sizeof options;
    options.abi_version = PHASER_ABI_VERSION;
    options.max_diagnostics = 32;
    options.max_related_locations = 128;

    printf("context\n");
    check(phaser_context_create(&options, &context) == PHASER_STATUS_OK,
          "a context is created from explicit options");
    if (context == NULL) {
        printf("\n%d check(s) failed\n", failures + 1);
        return 1;
    }

    check_valid_model(context);
    check_invalid_model(context);
    check_misuse(context);

    phaser_context_destroy(context);

    if (failures != 0) {
        printf("\n%d check(s) failed\n", failures);
        return 1;
    }
    printf("\nall C ABI checks passed\n");
    return 0;
}
