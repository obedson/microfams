# V1 test-layer matrix

`docs/V1_TEST_LAYER_MATRIX.json` inventories WP-P8-001 validation layers.

- `present` means a repeatable executable repository or CI gate exists for the implemented scope. It does not establish complete V1 coverage.
- `partial` means only a smoke, subset, mocked slice, or otherwise release-insufficient gate exists.
- `missing` means there is no executable evidence.

The matrix must not promote a layer from `partial` merely because a runbook or test filename exists. Critical-journey and release-validation coverage remains partial, so release remains NO-GO.
