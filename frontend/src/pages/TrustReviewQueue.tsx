import React, { useEffect, useState } from 'react';
import { trustAPI, TrustDecision, TrustReviewCase } from '../services/trustAPI';
import { LoadingSpinner } from '../components/Loading';
import { useAuthStore } from '../store/authStore';

export default function TrustReviewQueue() {
  const [reviews, setReviews] = useState<TrustReviewCase[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const reviewerId = useAuthStore((state) => state.user?.id);
  const [decisionCaseId, setDecisionCaseId] = useState('');
  const [outcome, setOutcome] = useState<TrustDecision['outcome']>('no_action');
  const [reasonCode, setReasonCode] = useState('');
  const [rationale, setRationale] = useState('');

  const load = () => {
    setLoading(true);
    trustAPI.listReviews().then(setReviews).catch(() => setError('The review queue is unavailable.')).finally(() => setLoading(false));
  };
  useEffect(load, []);

  if (loading) return <LoadingSpinner size="lg" />;
  return <main className="mx-auto max-w-6xl px-4 py-10"><h1 className="text-3xl font-black">Trust review queue</h1><p className="mt-2 text-gray-600">Personally identifiable numbers and provider payloads are never shown here.</p>{error && <p role="alert" className="mt-6 rounded-xl bg-red-50 p-4 text-red-800">{error}</p>}<div className="mt-8 overflow-hidden rounded-xl border bg-white"><table className="w-full text-left text-sm"><thead className="bg-gray-50"><tr><th className="p-4">Case</th><th className="p-4">Source</th><th className="p-4">State</th><th className="p-4">Priority</th><th className="p-4">Action</th></tr></thead><tbody>{reviews.map((review) => <tr key={review.id} className="border-t"><td className="p-4 font-mono text-xs">{review.id}</td><td className="p-4">{review.subjectType.replace(/_/g, ' ')}</td><td className="p-4">{review.state.replace(/_/g, ' ')}</td><td className="p-4">{review.priority}</td><td className="p-4">{review.assignedReviewerId ? <button onClick={() => setDecisionCaseId(review.id)} className="font-bold text-primary-700">Record decision</button> : <button disabled={!reviewerId} onClick={async () => { if (!reviewerId) return; await trustAPI.assignReview(review.id, reviewerId); load(); }} className="font-bold text-primary-700 disabled:text-gray-400">Assign to me</button>}</td></tr>)}</tbody></table>{reviews.length === 0 && !error && <p className="p-8 text-center text-gray-500">No cases are waiting for review.</p>}</div>{decisionCaseId && <form className="mt-6 space-y-4 rounded-xl border bg-white p-6" onSubmit={async (event) => { event.preventDefault(); await trustAPI.decideReview(decisionCaseId, outcome, reasonCode, rationale); setDecisionCaseId(''); setReasonCode(''); setRationale(''); load(); }}><h2 className="text-xl font-bold">Record immutable decision</h2><label className="block font-bold" htmlFor="review-outcome">Outcome</label><select id="review-outcome" className="w-full rounded-lg border p-3" value={outcome} onChange={(event) => setOutcome(event.target.value as TrustDecision['outcome'])}><option value="no_action">No action</option><option value="warning">Warning</option><option value="suspend_membership">Suspend membership</option><option value="suspend_organization">Suspend organization</option><option value="suspend_user">Suspend user</option><option value="refer">Refer</option></select><label className="block font-bold" htmlFor="review-reason">Reason code</label><input id="review-reason" required pattern="[A-Z][A-Z0-9_]{2,63}" value={reasonCode} onChange={(event) => setReasonCode(event.target.value.toUpperCase())} className="w-full rounded-lg border p-3 font-mono" /><label className="block font-bold" htmlFor="review-rationale">Rationale</label><textarea id="review-rationale" required minLength={20} maxLength={4000} rows={5} value={rationale} onChange={(event) => setRationale(event.target.value)} className="w-full rounded-lg border p-3" /><div className="flex gap-3"><button className="rounded-lg bg-primary-600 px-5 py-3 font-bold text-white">Confirm decision</button><button type="button" onClick={() => setDecisionCaseId('')} className="rounded-lg border px-5 py-3 font-bold">Cancel</button></div></form>}</main>;
}
