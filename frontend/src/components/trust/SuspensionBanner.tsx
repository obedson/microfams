import React from 'react';
import { Link } from 'react-router-dom';
import { ShieldAlert } from 'lucide-react';

interface SuspensionBannerProps {
  scope: 'account' | 'organization' | 'membership';
  reason?: string;
  appealHref?: string;
}

export default function SuspensionBanner({ scope, reason, appealHref }: SuspensionBannerProps) {
  const labels = {
    account: 'Your Micro Fams account is suspended.',
    organization: 'This organization is suspended.',
    membership: 'Your membership in this organization is suspended.'
  };

  return (
    <section role="alert" className="rounded-xl border border-red-200 bg-red-50 p-4 text-red-900">
      <div className="flex items-start gap-3">
        <ShieldAlert aria-hidden="true" className="mt-0.5 shrink-0" size={20} />
        <div>
          <p className="font-bold">{labels[scope]}</p>
          <p className="mt-1 text-sm">{reason || 'Access is limited while this decision is reviewed.'}</p>
          {appealHref && <Link className="mt-3 inline-block text-sm font-bold underline" to={appealHref}>Request a review</Link>}
        </div>
      </div>
    </section>
  );
}
