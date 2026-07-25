import React, { FormEvent, useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { SuspendedRecoveryStatus, trustAPI } from '../services/trustAPI';

export default function SuspendedAccountRecovery() {
 const [params]=useSearchParams(); const token=params.get('token')||'';
 const [email,setEmail]=useState(''); const [grounds,setGrounds]=useState('');
 const [status,setStatus]=useState<SuspendedRecoveryStatus|null>(null); const [message,setMessage]=useState(''); const [error,setError]=useState('');
 useEffect(()=>{ if(token) trustAPI.inspectSuspendedRecovery(token).then(setStatus).catch(()=>setError('This recovery link is invalid or has expired.')); },[token]);
 const request=async(e:FormEvent)=>{e.preventDefault();setError('');try{await trustAPI.requestSuspendedRecovery(email);setMessage('If the account is eligible, a recovery link has been sent.');}catch{setError('Recovery is temporarily unavailable.');}};
 const appeal=async(e:FormEvent)=>{e.preventDefault();setError('');try{await trustAPI.submitSuspendedRecoveryAppeal(token,grounds);setMessage('Appeal submitted. The trust team will review it independently.');setStatus(null);}catch{setError('The appeal could not be submitted. The link may be invalid or expired.');}};
 return <main className="mx-auto max-w-xl px-4 py-10"><h1 className="text-2xl font-semibold">Account suspension review</h1>
  {!token&&<form onSubmit={request} className="mt-6 space-y-4"><p>Enter the verified email address on your suspended account. This does not sign you in.</p><label className="block">Email<input aria-label="Email" type="email" required value={email} onChange={e=>setEmail(e.target.value)} className="mt-1 block w-full rounded border p-2"/></label><button className="rounded bg-green-700 px-4 py-2 text-white">Send recovery link</button></form>}
  {token&&!error&&!status&&!message&&<p role="status" className="mt-6">Checking recovery link…</p>}
  {status&&<form onSubmit={appeal} className="mt-6 space-y-4"><p>Your account is suspended. This link permits only one appeal and expires at {new Date(status.expiresAt).toLocaleString()}.</p><label className="block">Appeal statement<textarea aria-label="Appeal statement" required minLength={10} maxLength={4000} value={grounds} onChange={e=>setGrounds(e.target.value)} className="mt-1 block min-h-32 w-full rounded border p-2"/></label><button className="rounded bg-green-700 px-4 py-2 text-white">Submit appeal</button></form>}
  {message&&<p role="status" className="mt-6 rounded bg-green-50 p-3 text-green-900">{message}</p>}{error&&<p role="alert" className="mt-6 rounded bg-red-50 p-3 text-red-900">{error}</p>}
 </main>;
}