import React, { FormEvent, useState } from 'react';
import { useParams } from 'react-router-dom';
import { trustAPI } from '../services/trustAPI';

export default function TrustAppeal() {
  const { caseId = '' } = useParams();
  const [statement, setStatement] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [submitted, setSubmitted] = useState(false);
  const [error, setError] = useState('');

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    setSubmitting(true);
    setError('');
    try {
      await trustAPI.submitAppeal(caseId, statement.trim());
      setSubmitted(true);
    } catch {
      setError('The appeal could not be submitted. It may already be under review.');
    } finally {
      setSubmitting(false);
    }
  };

  if (submitted) return <main className="mx-auto max-w-2xl px-4 py-12"><div role="status" className="rounded-xl border border-green-200 bg-green-50 p-6"><h1 className="text-2xl font-bold">Appeal submitted</h1><p className="mt-2">A different reviewer will assess the decision. You can follow progress from your trust status page.</p></div></main>;

  return <main className="mx-auto max-w-2xl px-4 py-12"><h1 className="text-3xl font-black">Appeal a trust decision</h1><p className="mt-2 text-gray-600">Explain what should be reconsidered. Do not enter your NIN, BVN, OTP, or bank details.</p><form className="mt-8 space-y-4" onSubmit={submit}><label className="block font-bold" htmlFor="appeal-statement">Appeal statement</label><textarea id="appeal-statement" value={statement} onChange={(event) => setStatement(event.target.value)} minLength={20} maxLength={2000} required rows={8} className="w-full rounded-xl border p-4" />{error && <p role="alert" className="text-sm text-red-700">{error}</p>}<button disabled={submitting || statement.trim().length < 20} className="rounded-xl bg-primary-600 px-6 py-3 font-bold text-white disabled:opacity-50">{submitting ? 'Submitting…' : 'Submit appeal'}</button></form></main>;
}
