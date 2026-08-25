export type AgronomicRecord = {
  id: string;
  record_date?: string;
  livestock_count?: number;
  mortality_count?: number;
  expenses?: number;
};

export type AgronomicRecommendation = {
  type: 'warning' | 'info' | 'onboarding';
  title: string;
  message: string;
  ruleId: string;
  confidence: number;
  provenance: { source: 'farm_records'; recordIds: string[]; generatedAt: string };
};

export const buildAgronomicRecommendations = (records: AgronomicRecord[], generatedAt = new Date().toISOString()): AgronomicRecommendation[] => {
  const source = records.map(record => record.id);
  if (records.length === 0) return [{ type: 'onboarding', title: 'Start tracking', message: 'Begin logging farm activities to receive evidence-based insights.', ruleId: 'FARM_RECORDS_ONBOARDING_V1', confidence: 1, provenance: { source: 'farm_records', recordIds: [], generatedAt } }];
  const totalLivestock = records.reduce((sum, record) => sum + (record.livestock_count ?? 0), 0);
  const mortality = records.reduce((sum, record) => sum + (record.mortality_count ?? 0), 0);
  const mortalityRate = totalLivestock > 0 ? (mortality / totalLivestock) * 100 : 0;
  const recommendations: AgronomicRecommendation[] = [];
  if (mortalityRate > 5) recommendations.push({ type: 'warning', title: 'High mortality rate detected', message: `Current mortality is ${mortalityRate.toFixed(1)}%. Review health protocols with a qualified adviser.`, ruleId: 'LIVESTOCK_MORTALITY_OVER_5_PERCENT_V1', confidence: Math.min(0.99, 0.6 + Math.min(records.length, 20) / 100), provenance: { source: 'farm_records', recordIds: source, generatedAt } });
  const expenses = records.reduce((sum, record) => sum + (record.expenses ?? 0), 0);
  if (expenses > 100000) recommendations.push({ type: 'info', title: 'Review expense trend', message: 'Recent farm expenses exceed the configured review threshold. Compare input usage and approved supplier prices.', ruleId: 'FARM_EXPENSE_REVIEW_OVER_100000_MINOR_V1', confidence: Math.min(0.95, 0.6 + Math.min(records.length, 20) / 100), provenance: { source: 'farm_records', recordIds: source, generatedAt } });
  return recommendations;
};
