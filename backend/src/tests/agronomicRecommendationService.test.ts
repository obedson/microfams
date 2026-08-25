import { buildAgronomicRecommendations } from '../services/agronomicRecommendationService.js';

test('emits deterministic provenance and confidence for mortality evidence', () => {
  const result = buildAgronomicRecommendations([{ id: 'record-1', livestock_count: 100, mortality_count: 10 }], '2026-08-25T00:00:00.000Z');
  expect(result[0]).toMatchObject({ type: 'warning', ruleId: 'LIVESTOCK_MORTALITY_OVER_5_PERCENT_V1', confidence: 0.61, provenance: { source: 'farm_records', recordIds: ['record-1'], generatedAt: '2026-08-25T00:00:00.000Z' } });
});

test('returns safe onboarding recommendation without source records', () => {
  expect(buildAgronomicRecommendations([], '2026-08-25T00:00:00.000Z')[0]).toMatchObject({ type: 'onboarding', confidence: 1, provenance: { recordIds: [] } });
});
