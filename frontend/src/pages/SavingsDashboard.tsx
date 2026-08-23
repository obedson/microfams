import React, { FormEvent, useEffect, useState } from 'react';
import { CheckCircle2, LockKeyhole, RefreshCw, ShieldCheck } from 'lucide-react';
import { SavingsEnrolmentRecord, SavingsProductRecord, savingsAPI } from '../services/savingsAPI';

const money = (minor: number | null | undefined, currency: string) =>
  new Intl.NumberFormat(undefined, { style: 'currency', currency }).format((minor ?? 0) / 100);

export default function SavingsDashboard() {
  const [products, setProducts] = useState<SavingsProductRecord[]>([]);
  const [enrolments, setEnrolments] = useState<SavingsEnrolmentRecord[]>([]);
  const [selected, setSelected] = useState<SavingsProductRecord | null>(null);
  const [target, setTarget] = useState('');
  const [accepted, setAccepted] = useState(false);
  const [busy, setBusy] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');

  const load = async () => {
    setBusy(true);
    setError('');
    try {
      const [available, current] = await Promise.all([savingsAPI.listProducts(), savingsAPI.listEnrolments()]);
      setProducts(available);
      setEnrolments(current);
    } catch {
      setError('Savings products could not be loaded for this organisation.');
    } finally {
      setBusy(false);
    }
  };
  useEffect(() => { void load(); }, []);

  const enrol = async (event: FormEvent) => {
    event.preventDefault();
    if (!selected || !accepted) return;
    setSubmitting(true);
    setError('');
    setNotice('');
    try {
      const targetMinor = target ? Math.round(Number(target) * 100) : undefined;
      if (target && (!Number.isSafeInteger(targetMinor) || (targetMinor ?? 0) < 1)) throw new Error('Enter a valid target amount.');
      await savingsAPI.enrol(selected.product.id, {
        ...(targetMinor ? { targetMinor } : {}),
        disclosureVersion: selected.version.disclosure_version,
        disclosureContentHash: selected.version.disclosure_content_hash,
      });
      setNotice('Savings account enrolled successfully.');
      setSelected(null);
      setAccepted(false);
      setTarget('');
      await load();
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'The savings enrolment could not be completed.');
    } finally {
      setSubmitting(false);
    }
  };

  return <main className="mx-auto max-w-6xl px-4 py-10">
    <div className="flex items-start justify-between gap-4">
      <div><p className="text-sm font-bold uppercase tracking-wide text-primary-700">Financial products</p><h1 className="text-3xl font-black text-gray-900">Savings</h1><p className="mt-2 text-gray-600">Choose an approved product and accept its exact disclosure before opening an account.</p></div>
      <button type="button" onClick={() => void load()} disabled={busy} aria-label="Refresh savings" className="rounded-lg border p-3 text-gray-700 hover:bg-gray-50 disabled:opacity-50"><RefreshCw size={18} /></button>
    </div>
    {error && <p role="alert" className="mt-5 rounded-lg bg-red-50 p-4 text-red-800">{error}</p>}
    {notice && <p role="status" className="mt-5 rounded-lg bg-green-50 p-4 text-green-800">{notice}</p>}
    <section className="mt-8"><h2 className="text-xl font-bold">Available products</h2>
      {busy ? <p className="mt-4 text-gray-600">Loading products...</p> : products.length === 0 ? <p className="mt-4 rounded-lg border p-5 text-gray-600">No approved savings products are available.</p> : <div className="mt-4 grid gap-4 md:grid-cols-2">{products.map((item) => <article key={item.product.id} className="rounded-lg border bg-white p-5 shadow-sm">
        <div className="flex items-start justify-between gap-3"><div><h3 className="text-lg font-bold">{item.product.name}</h3><p className="text-sm text-gray-500">{item.product.code} · version {item.version.version} · {item.product.currency}</p></div><ShieldCheck className="text-green-700" size={22} /></div>
        <dl className="mt-4 grid grid-cols-2 gap-3 text-sm"><div><dt className="text-gray-500">Contribution range</dt><dd className="font-semibold">{money(item.version.minimum_contribution_minor, item.product.currency)} - {money(item.version.maximum_contribution_minor, item.product.currency)}</dd></div><div><dt className="text-gray-500">Frequency</dt><dd className="font-semibold capitalize">{item.version.contribution_frequency}</dd></div><div><dt className="text-gray-500">Lock period</dt><dd className="font-semibold">{item.version.lock_period_days} days</dd></div><div><dt className="text-gray-500">Return</dt><dd className="font-semibold">{item.version.return_method === 'simple_interest' ? `${item.version.annual_rate_basis_points / 100}% simple interest` : 'None'}</dd></div></dl>
        <button type="button" onClick={() => { setSelected(item); setAccepted(false); setError(''); }} className="mt-5 w-full rounded-lg bg-primary-700 px-4 py-3 font-bold text-white hover:bg-primary-800">Review and enrol</button>
      </article>)}</div>}
    </section>
    {enrolments.length > 0 && <section className="mt-10"><h2 className="text-xl font-bold">Your savings accounts</h2><div className="mt-4 overflow-x-auto rounded-lg border bg-white"><table className="min-w-full text-left text-sm"><thead className="border-b bg-gray-50"><tr><th className="px-4 py-3">Product</th><th className="px-4 py-3">State</th><th className="px-4 py-3">Target</th><th className="px-4 py-3">Disclosure</th></tr></thead><tbody>{enrolments.map((item) => <tr key={item.enrolment.id} className="border-b last:border-0"><td className="px-4 py-3 font-semibold">{item.product.name}</td><td className="px-4 py-3 capitalize">{item.enrolment.state}</td><td className="px-4 py-3">{item.enrolment.target_minor ? money(item.enrolment.target_minor, item.enrolment.currency) : 'No target'}</td><td className="px-4 py-3 font-mono text-xs">{item.enrolment.accepted_disclosure_version}</td></tr>)}</tbody></table></div></section>}
    {selected && <div role="dialog" aria-modal="true" aria-labelledby="savings-enrolment-title" className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"><form onSubmit={enrol} className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-lg bg-white p-6 shadow-xl">
      <div className="flex items-start justify-between gap-4"><div><h2 id="savings-enrolment-title" className="text-xl font-bold">Review {selected.product.name}</h2><p className="mt-1 text-sm text-gray-600">Product version {selected.version.version} is approved for enrolment.</p></div><LockKeyhole className="text-primary-700" /></div>
      <div className="mt-5 rounded-lg border bg-gray-50 p-4 text-sm"><p className="font-semibold">Immutable disclosure</p><p className="mt-2">Version: <span className="font-mono">{selected.version.disclosure_version}</span></p><p className="break-all">SHA-256: <span className="font-mono text-xs">{selected.version.disclosure_content_hash}</span></p><p className="mt-3 text-gray-600">By accepting, you bind this enrolment to the exact version and content hash shown above.</p></div>
      <label className="mt-5 block text-sm font-semibold">Target amount (optional)<input inputMode="decimal" value={target} onChange={(event) => setTarget(event.target.value)} className="mt-2 block w-full rounded-lg border p-3" placeholder="e.g. 10000" /></label>
      <label className="mt-5 flex gap-3 text-sm"><input type="checkbox" checked={accepted} onChange={(event) => setAccepted(event.target.checked)} className="mt-1" /> <span>I have read and accept this disclosure for version {selected.version.version}.</span></label>
      <div className="mt-6 flex justify-end gap-3"><button type="button" onClick={() => setSelected(null)} className="rounded-lg border px-4 py-3 font-semibold">Cancel</button><button type="submit" disabled={!accepted || submitting} className="inline-flex items-center gap-2 rounded-lg bg-primary-700 px-4 py-3 font-bold text-white disabled:opacity-50">{submitting ? 'Enrolling...' : <><CheckCircle2 size={18} /> Enrol</>}</button></div>
    </form></div>}
  </main>;
}
