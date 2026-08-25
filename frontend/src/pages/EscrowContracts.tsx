import React, { useState } from 'react';
import { escrowContractAPI, EscrowContractCommand } from '../services/escrowContractAPI';

const initial: EscrowContractCommand = { payerId: '', beneficiaryId: '', currency: 'NGN', amountMinor: 0, purpose: '' };

export default function EscrowContracts() {
  const [command, setCommand] = useState(initial);
  const [contractId, setContractId] = useState('');
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');
  const run = async (operation: () => Promise<unknown>, success: string) => {
    setBusy(true); setError(''); setNotice('');
    try { await operation(); setNotice(success); } catch { setError('Escrow command was rejected. Check permissions, feature flags, and command evidence.'); } finally { setBusy(false); }
  };
  return <main className="mx-auto max-w-3xl px-4 py-10">
    <p className="text-sm font-bold uppercase tracking-wide text-primary-700">Escrow</p>
    <h1 className="text-3xl font-black">Escrow contract administration</h1>
    <p className="mt-2 text-gray-600">Create a controlled contract draft, then activate it after terms and release evidence are approved.</p>
    {error && <p role="alert" className="mt-5 rounded bg-red-50 p-4 text-red-800">{error}</p>}
    {notice && <p role="status" className="mt-5 rounded bg-green-50 p-4 text-green-800">{notice}</p>}
    <form className="mt-8 space-y-4 rounded-lg border bg-white p-5 shadow-sm" onSubmit={event => { event.preventDefault(); void run(() => escrowContractAPI.create(command), 'Escrow contract draft created.'); }}>
      <label className="block"><span className="font-bold">Payer ID</span><input aria-label="Payer ID" className="mt-1 w-full rounded border p-2" value={command.payerId} onChange={e => setCommand({ ...command, payerId: e.target.value })} required /></label>
      <label className="block"><span className="font-bold">Beneficiary ID</span><input aria-label="Beneficiary ID" className="mt-1 w-full rounded border p-2" value={command.beneficiaryId} onChange={e => setCommand({ ...command, beneficiaryId: e.target.value })} required /></label>
      <div className="grid gap-4 sm:grid-cols-2"><label className="block"><span className="font-bold">Currency</span><input aria-label="Currency" maxLength={3} className="mt-1 w-full rounded border p-2" value={command.currency} onChange={e => setCommand({ ...command, currency: e.target.value.toUpperCase() })} required /></label><label className="block"><span className="font-bold">Amount (minor units)</span><input aria-label="Amount (minor units)" type="number" min="1" className="mt-1 w-full rounded border p-2" value={command.amountMinor} onChange={e => setCommand({ ...command, amountMinor: Number(e.target.value) })} required /></label></div>
      <label className="block"><span className="font-bold">Purpose</span><textarea aria-label="Purpose" className="mt-1 w-full rounded border p-2" value={command.purpose} onChange={e => setCommand({ ...command, purpose: e.target.value })} required /></label>
      <button disabled={busy} className="rounded bg-primary-700 px-5 py-3 font-bold text-white disabled:opacity-50">Create draft</button>
    </form>
    <section className="mt-8 rounded-lg border bg-white p-5 shadow-sm"><h2 className="text-xl font-bold">Activate contract</h2><label className="mt-3 block"><span className="font-bold">Contract ID</span><input aria-label="Contract ID" className="mt-1 w-full rounded border p-2" value={contractId} onChange={e => setContractId(e.target.value)} /></label><button disabled={busy || !contractId} onClick={() => void run(() => escrowContractAPI.activate(contractId), 'Escrow contract activated.')} className="mt-4 rounded border px-5 py-3 font-bold disabled:opacity-50">Activate</button></section>
  </main>;
}
