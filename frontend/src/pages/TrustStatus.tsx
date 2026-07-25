import React, { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { ShieldCheck, AlertCircle } from 'lucide-react';
import { IdentityTrustStatus, TrustDecision, trustAPI } from '../services/trustAPI';
import { LoadingSpinner } from '../components/Loading';
import SuspensionBanner from '../components/trust/SuspensionBanner';

export default function TrustStatus() {
  const [status, setStatus] = useState<IdentityTrustStatus | null>(null);
  const [decisions, setDecisions] = useState<TrustDecision[]>([]);
  const [error, setError] = useState('');

  useEffect(() => {
    Promise.all([trustAPI.getIdentityStatus(), trustAPI.listSelfDecisions()])
      .then(([nextStatus, nextDecisions]) => { setStatus(nextStatus); setDecisions(nextDecisions); })
      .catch(() => setError('Your trust status could not be loaded. Please try again.'));
  }, []);

  if (!status && !error) return <LoadingSpinner size="lg" />;

  return (
    <main className="mx-auto max-w-3xl px-4 py-10">
      <h1 className="text-3xl font-black text-gray-900">Identity and trust status</h1>
      <p className="mt-2 text-gray-600">Track verification reviews, decisions, and appeals without exposing your identity data.</p>
      {error ? <div role="alert" className="mt-6 rounded-xl bg-red-50 p-4 text-red-800"><AlertCircle className="inline mr-2" size={18} />{error}</div> : (
        <div className="mt-8 space-y-4">
          {status?.suspended && <SuspensionBanner scope="account" reason="A trust decision currently limits access. An appeal remains available from this page." />}
          <section className="rounded-xl border bg-white p-6">
            <div className="flex items-center gap-3"><ShieldCheck className="text-primary-600" /><h2 className="font-bold">Trust access: {status?.suspended ? 'suspended' : 'active'}</h2></div>
          </section>
          {status?.activeCase && <section className="rounded-xl border border-amber-200 bg-amber-50 p-6"><h2 className="font-bold">Review in progress</h2><p className="mt-1 text-sm">State: {status.activeCase.state.replace(/_/g, ' ')}</p></section>}
          {decisions[0] && <section className="rounded-xl border bg-white p-6"><h2 className="font-bold">Latest decision: {decisions[0].outcome.replace(/_/g, ' ')}</h2><p className="mt-1 text-sm">Reason: {decisions[0].reasonCode.replace(/_/g, ' ')}</p>{decisions[0].outcome !== 'no_action' && <Link className="mt-4 inline-block font-bold text-primary-700 underline" to={`/trust/cases/${decisions[0].caseId}/appeal`}>Appeal this decision</Link>}</section>}
          {status?.activeAppeal && <section className="rounded-xl border border-blue-200 bg-blue-50 p-6"><h2 className="font-bold">Appeal: {status.activeAppeal.state.replace(/_/g, ' ')}</h2><p className="mt-1 text-sm">Submitted {new Date(status.activeAppeal.filedAt).toLocaleDateString()}</p></section>}
        </div>
      )}
    </main>
  );
}
