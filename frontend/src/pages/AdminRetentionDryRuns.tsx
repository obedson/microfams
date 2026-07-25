import React, { FormEvent, useState } from 'react';
import { RetentionDryRun, trustAPI } from '../services/trustAPI';

export default function AdminRetentionDryRuns() {
  const [policyId, setPolicyId] = useState('');
  const [organizationId, setOrganizationId] = useState('');
  const [result, setResult] = useState<RetentionDryRun | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setBusy(true);
    setError('');
    setResult(null);
    try {
      const planned = await trustAPI.createRetentionDryRun({
        policyId,
        ...(organizationId ? { organizationId } : {}),
      });
      setResult(await trustAPI.selectRetentionItems(planned.runId));
    } catch {
      setError('The retention dry run could not be completed. Check the policy, scope, and feature flag.');
    } finally {
      setBusy(false);
    }
  };

  return <main className="mx-auto max-w-4xl px-4 py-10">
    <h1 className="text-3xl font-black">Retention dry runs</h1>
    <p className="mt-2 text-gray-600">Preview policy effects. This tool never anonymizes or deletes source records.</p>
    <form onSubmit={submit} className="mt-8 grid gap-4 rounded-xl border bg-white p-6 md:grid-cols-2">
      <label className="font-bold">Policy ID<input aria-label="Policy ID" required value={policyId} onChange={(event) => setPolicyId(event.target.value)} className="mt-2 block w-full rounded-lg border p-3 font-mono" /></label>
      <label className="font-bold">Organization ID (optional)<input aria-label="Organization ID" value={organizationId} onChange={(event) => setOrganizationId(event.target.value)} className="mt-2 block w-full rounded-lg border p-3 font-mono" /></label>
      <button disabled={busy} className="rounded-lg bg-primary-700 px-5 py-3 font-bold text-white disabled:opacity-50">{busy ? 'Classifying records…' : 'Run safe preview'}</button>
    </form>
    {error && <p role="alert" className="mt-5 rounded-lg bg-red-50 p-4 text-red-800">{error}</p>}
    {result?.summary && <section aria-labelledby="retention-summary" className="mt-8 rounded-xl border bg-white p-6">
      <h2 id="retention-summary" className="text-xl font-bold">Completed preview</h2>
      <p className="mt-1 text-sm text-gray-600">Data class: {result.summary.dataClass}</p>
      <dl className="mt-5 grid grid-cols-2 gap-4 md:grid-cols-5">
        <Summary label="Total" value={result.summary.total} />
        <Summary label="Held" value={result.summary.held} />
        <Summary label="Retained" value={result.summary.retained} />
        <Summary label="Would anonymize" value={result.summary.wouldAnonymize} />
        <Summary label="Would delete" value={result.summary.wouldDelete} />
      </dl>
    </section>}
  </main>;
}

function Summary({ label, value }: { label: string; value: number }) {
  return <div className="rounded-lg bg-gray-50 p-4"><dt className="text-sm text-gray-600">{label}</dt><dd className="text-2xl font-black">{value}</dd></div>;
}