import React, { useEffect, useState } from 'react';
import { farmRecordAPI, FarmRecommendation } from '../../services/farmRecordAPI';

const tone = {
  warning: 'border-amber-300 bg-amber-50',
  info: 'border-blue-200 bg-blue-50',
  onboarding: 'border-gray-200 bg-gray-50',
};

const FarmRecommendations: React.FC = () => {
  const [items, setItems] = useState<FarmRecommendation[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    let active = true;
    farmRecordAPI.getRecommendations()
      .then(data => { if (active) setItems(data); })
      .catch(() => { if (active) setError('Farm recommendations are not available for this organization.'); })
      .finally(() => { if (active) setLoading(false); });
    return () => { active = false; };
  }, []);

  return <section aria-labelledby="farm-recommendations-title">
    <h2 id="farm-recommendations-title" className="text-xl font-bold">Farm recommendations</h2>
    {loading && <p className="mt-3">Loading recommendations...</p>}
    {error && <p role="alert" className="mt-3 rounded border border-red-200 bg-red-50 p-4 text-red-800">{error}</p>}
    {!loading && !error && items.length === 0 && <p className="mt-3 text-gray-600">No evidence-based recommendations are available yet.</p>}
    <div className="mt-4 grid gap-3">
      {items.map(item => <article key={`${item.ruleId}-${item.provenance.generatedAt}`} className={`rounded border p-4 ${tone[item.type]}`}>
        <div className="flex flex-wrap items-start justify-between gap-2">
          <h3 className="font-bold">{item.title}</h3>
          <span className="text-sm font-semibold">{Math.round(item.confidence * 100)}% confidence</span>
        </div>
        <p className="mt-2">{item.message}</p>
        <p className="mt-3 text-xs text-gray-600">Rule {item.ruleId} / {item.provenance.recordIds.length} source records</p>
      </article>)}
    </div>
  </section>;
};

export default FarmRecommendations;
