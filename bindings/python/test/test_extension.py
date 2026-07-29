"""Tests for the native Phaser extension.

Run through ``zig build test-python``, which builds the extension, installs it
where an interpreter can find it, and runs this file with that interpreter.

These tests are written against the interpreter rather than against the Zig
types behind it, because what matters here is what an importing interpreter
sees: whether the module loads at all, whether its results match the C ABI, and
whether a rejected document raises rather than returning something wrong.

The standard library's ``unittest`` is used deliberately. Decision 0015 approved
a Python dependency set for the binding and the notebook; a test runner was not
in it, and nothing here needs one.
"""

import sys
import unittest

import phaser

# The smallest valid model: two parameters and one real scalar field. Kept here
# rather than shared with the Zig fixtures so a change to one cannot silently
# change what the other asserts.
VALID_MODEL = b"""{
  "schema": "phaser.qft-model/0.1",
  "spacetime_dimension": 4,
  "conventions": {
    "metric": "mostly_plus",
    "scalar_representation": "real_components",
    "fermions": "two_component_weyl"
  },
  "parameters": {
    "lambda": {"domain": "real", "mass_dimension": 0},
    "m2": {"domain": "real", "mass_dimension": 2}
  },
  "fields": {
    "real_scalars": [{"id": "phi"}],
    "weyl_fermions": [],
    "gauge_vectors": []
  },
  "tensors": {
    "scalar_mass_squared": {
      "components": [{"indices": ["phi", "phi"], "value": "m2"}]
    },
    "scalar_quartic": {
      "components": [{"indices": ["phi", "phi", "phi", "phi"], "value": "lambda"}]
    }
  }
}
"""


class TestInterpreterRequirements(unittest.TestCase):
    def test_interpreter_meets_the_documented_minimum(self):
        # The extension is built against the Limited API at 3.11, which is the
        # version from which the complete Py_buffer structure is part of the
        # Stable ABI. Running it on an older interpreter is not supported, and
        # this states that rather than leaving it to a confusing failure later.
        self.assertGreaterEqual(sys.version_info[:2], (3, 11))


class TestVersions(unittest.TestCase):
    def test_abi_version_is_zero(self):
        self.assertEqual(phaser.abi_version(), 0)

    def test_abi_reports_itself_experimental(self):
        # Milestone 4 requires that version 0 stay explicitly experimental, and
        # every surface has to say so, not just the header.
        self.assertIs(phaser.abi_experimental(), True)

    def test_library_version_is_a_three_part_tuple(self):
        version = phaser.library_version()
        self.assertIsInstance(version, tuple)
        self.assertEqual(len(version), 3)
        for part in version:
            self.assertIsInstance(part, int)
            self.assertGreaterEqual(part, 0)


class TestModelMetadata(unittest.TestCase):
    def test_a_valid_model_reports_its_counts(self):
        metadata = phaser.model_metadata(VALID_MODEL)
        self.assertEqual(metadata["parameter_count"], 2)
        self.assertEqual(metadata["scalar_field_count"], 1)

    def test_the_fingerprint_is_stable_and_well_formed(self):
        first = phaser.model_metadata(VALID_MODEL)["fingerprint"]
        second = phaser.model_metadata(VALID_MODEL)["fingerprint"]
        self.assertEqual(first, second)
        self.assertEqual(len(first), 64)
        # Hexadecimal, so it survives being written into a document or a log.
        int(first, 16)

    def test_whitespace_changes_do_not_change_the_fingerprint(self):
        # The fingerprint identifies the canonical model, not its source text.
        # A reformatted document is the same model.
        compact = b" ".join(VALID_MODEL.split())
        self.assertEqual(
            phaser.model_metadata(compact)["fingerprint"],
            phaser.model_metadata(VALID_MODEL)["fingerprint"],
        )

    def test_an_invalid_model_raises_with_its_diagnostic(self):
        with self.assertRaises(ValueError) as raised:
            phaser.model_metadata(b"{ not json")
        message = str(raised.exception)
        # The structured diagnostic reaches the exception, so a caller learns
        # why the document was rejected rather than only that it was.
        self.assertIn("model", message)
        self.assertIn("invalid_json", message)

    def test_a_semantically_invalid_model_also_raises(self):
        # Valid JSON, wrong schema. This goes down a different path in the
        # loader than a parse failure and must still surface as an exception.
        with self.assertRaises(ValueError):
            phaser.model_metadata(b'{"schema": "not.a.phaser.schema/0.1"}')

    def test_str_is_rejected_rather_than_guessed_at(self):
        # The binding takes bytes, so the caller decides the encoding. Accepting
        # str would mean guessing one.
        with self.assertRaises(TypeError):
            phaser.model_metadata(VALID_MODEL.decode())

    def test_empty_input_raises(self):
        with self.assertRaises(ValueError):
            phaser.model_metadata(b"")


if __name__ == "__main__":
    unittest.main(verbosity=2)
