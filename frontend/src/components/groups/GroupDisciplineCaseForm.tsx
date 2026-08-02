import React, { FormEvent, useMemo, useState } from 'react';
import { CreateGroupDisciplineCaseInput } from '../../services/groupAdminAPI';

interface Props {
  memberName: string;
  submitting?: boolean;
  onCancel: () => void;
  onSubmit: (value: CreateGroupDisciplineCaseInput) => void;
}

const localDateTime = (date: Date) => {
  const shifted = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return shifted.toISOString().slice(0, 16);
};

export default function GroupDisciplineCaseForm({ memberName, submitting, onCancel, onSubmit }: Props) {
  const defaults = useMemo(() => {
    const now = Date.now();
    return {
      responseDueAt: localDateTime(new Date(now + 48 * 60 * 60 * 1000)),
      proposalClosesAt: localDateTime(new Date(now + 96 * 60 * 60 * 1000)),
    };
  }, []);
  const [proposedAction, setProposedAction] = useState<'suspend' | 'expel'>('suspend');
  const [reasonCode, setReasonCode] = useState('MATERIAL_POLICY_BREACH');
  const [publicNotice, setPublicNotice] = useState('');
  const [evidence, setEvidence] = useState('');
  const [responseDueAt, setResponseDueAt] = useState(defaults.responseDueAt);
  const [proposalClosesAt, setProposalClosesAt] = useState(defaults.proposalClosesAt);
  const [appealWindowDays, setAppealWindowDays] = useState(30);

  const submit = (event: FormEvent) => {
    event.preventDefault();
    onSubmit({
      proposedAction,
      reasonCode: reasonCode.trim().toUpperCase(),
      publicNotice: publicNotice.trim(),
      privateEvidenceRefs: evidence.split(/[\n,]/).map((value) => value.trim()).filter(Boolean),
      responseDueAt: new Date(responseDueAt).toISOString(),
      proposalClosesAt: new Date(proposalClosesAt).toISOString(),
      appealWindowDays,
    });
  };

  return (
    <form onSubmit={submit} className="space-y-4" aria-label={`Discipline review for ${memberName}`}>
      <div>
        <h3 className="font-bold text-gray-900">Start due-process review</h3>
        <p className="text-sm text-gray-600">{memberName} receives notice and time to respond before voting opens.</p>
      </div>
      <label className="block text-sm font-medium">
        Proposed action
        <select value={proposedAction} onChange={(event) => setProposedAction(event.target.value as 'suspend' | 'expel')} className="mt-1 w-full rounded-lg border-gray-300">
          <option value="suspend">Suspend</option>
          <option value="expel">Expel</option>
        </select>
      </label>
      <label className="block text-sm font-medium">
        Reason code
        <input required pattern="[A-Z][A-Z0-9_]{2,63}" value={reasonCode} onChange={(event) => setReasonCode(event.target.value)} className="mt-1 w-full rounded-lg border-gray-300" />
      </label>
      <label className="block text-sm font-medium">
        Notice shown to the member
        <textarea required minLength={20} maxLength={1000} value={publicNotice} onChange={(event) => setPublicNotice(event.target.value)} className="mt-1 w-full rounded-lg border-gray-300" rows={4} />
      </label>
      <label className="block text-sm font-medium">
        Private evidence references
        <textarea required value={evidence} onChange={(event) => setEvidence(event.target.value)} placeholder="One secure reference per line" className="mt-1 w-full rounded-lg border-gray-300" rows={3} />
      </label>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <label className="block text-sm font-medium">Response due
          <input required type="datetime-local" value={responseDueAt} onChange={(event) => setResponseDueAt(event.target.value)} className="mt-1 w-full rounded-lg border-gray-300" />
        </label>
        <label className="block text-sm font-medium">Voting closes
          <input required type="datetime-local" value={proposalClosesAt} onChange={(event) => setProposalClosesAt(event.target.value)} className="mt-1 w-full rounded-lg border-gray-300" />
        </label>
      </div>
      <label className="block text-sm font-medium">Appeal window (days)
        <input required type="number" min={1} max={90} value={appealWindowDays} onChange={(event) => setAppealWindowDays(Number(event.target.value))} className="mt-1 w-full rounded-lg border-gray-300" />
      </label>
      <p className="text-xs text-gray-500">Financial balances, claims, and audit history are preserved regardless of the decision.</p>
      <div className="flex justify-end gap-3">
        <button type="button" onClick={onCancel} className="px-4 py-2 rounded-lg border border-gray-300">Cancel</button>
        <button disabled={submitting} type="submit" className="px-4 py-2 rounded-lg bg-red-700 text-white disabled:opacity-50">{submitting ? 'Creating…' : 'Issue notice'}</button>
      </div>
    </form>
  );
}
