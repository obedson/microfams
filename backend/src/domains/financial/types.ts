import { FeatureFlagContext } from '../../types/featureFlags.js';

export type JournalSide = 'debit' | 'credit';

export interface JournalLineInput {
  accountId: string;
  lineNumber: number;
  side: JournalSide;
  amountMinor: bigint;
  memo?: string;
}

export interface PostJournalCommand {
  organizationId: string;
  currency: string;
  effectiveDate: string;
  sourceDomain: string;
  sourceRecordId: string;
  idempotencyKey: string;
  correlationId: string;
  description: string;
  actorId?: string;
  jurisdiction?: string;
  lines: JournalLineInput[];
}

export interface JournalPostingRecord extends Omit<PostJournalCommand, 'lines' | 'jurisdiction'> {
  requestHash: string;
  lines: Array<Omit<JournalLineInput, 'amountMinor'> & { amountMinor: string }>;
}

export interface FinancialJournalGateway {
  post(record: JournalPostingRecord): Promise<string>;
}

export interface FinancialFeatureGate {
  evaluate(key: string, context: FeatureFlagContext): Promise<{ enabled: boolean; reason: string }>;
}
