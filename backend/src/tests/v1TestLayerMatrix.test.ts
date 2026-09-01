import matrix from '../../../docs/V1_TEST_LAYER_MATRIX.json';

describe('V1 test-layer evidence', () => {
  it('tracks required layers and partial statuses', () => {
    const required = [
      'unit',
      'integration',
      'api',
      'component',
      'e2e',
      'security',
      'performance',
      'accessibility',
      'recovery',
      'reconciliation',
    ];
    expect(matrix.layers.map(layer => layer.layer).sort()).toEqual(required.sort());

    for (const layer of matrix.layers) {
      expect(['present', 'partial', 'missing']).toContain(layer.status);
      if (layer.status === 'missing') expect(layer.evidence).toBeNull();
      else expect(layer.evidence).toEqual(expect.any(String));
    }

    expect(matrix.layers.find(layer => layer.layer === 'e2e')?.status).toBe('partial');
    expect(matrix.layers.find(layer => layer.layer === 'security')?.status).toBe('partial');
    expect(matrix.decision).toBe('partial');
  });
});
