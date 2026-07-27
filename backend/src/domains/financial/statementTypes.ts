export type StatementOwnerType = 'user' | 'group';

export interface StatementQuery {
  organizationId: string;
  ownerType: StatementOwnerType;
  ownerId: string;
  currency: string;
  from: string;
  to: string;
  cutoff: string;
  page: number;
  limit: number;
}

export interface StatementAccount {
  id: string;
  name: string;
  currency: string;
  normalSide: 'debit' | 'credit';
}

export interface StatementLine {
  id: string;
  journalEntryId: string;
  effectiveDate: string;
  postedAt: string;
  description: string;
  sourceDomain: string;
  sourceRecordId: string;
  correlationId: string;
  side: 'debit' | 'credit';
  amountMinor: string;
  memo: string | null;
}

export interface StatementReadResult {
  account: StatementAccount;
  openingBalanceMinor: string;
  pageOpeningBalanceMinor: string;
  closingBalanceMinor: string;
  lines: StatementLine[];
  total: number;
}

export interface FinancialStatementGateway {
  assertOwnerAccess(query: StatementQuery, actorId: string): Promise<void>;
  read(query: StatementQuery): Promise<StatementReadResult>;
}
