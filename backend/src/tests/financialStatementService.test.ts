import { FinancialStatementService, StatementValidationError } from '../domains/financial/financialStatementService.js';
import { FinancialStatementGateway, StatementQuery } from '../domains/financial/statementTypes.js';

const ORG = '00000000-0000-4000-8000-000000000101';
const USER = '00000000-0000-4000-8000-000000000102';
const NOW = new Date('2026-07-27T12:00:00.000Z');

const gateway = (): jest.Mocked<FinancialStatementGateway> => ({
  assertOwnerAccess: jest.fn().mockResolvedValue(undefined),
  read: jest.fn().mockResolvedValue({
    account: { id: ORG, name: 'Member wallet', currency: 'NGN', normalSide: 'credit' },
    openingBalanceMinor: '10000',
    pageOpeningBalanceMinor: '10000',
    closingBalanceMinor: '11500',
    total: 2,
    lines: [
      {
        id: ORG, journalEntryId: ORG, effectiveDate: '2026-07-02', postedAt: NOW.toISOString(),
        description: 'Funding', sourceDomain: 'payments', sourceRecordId: 'pay-1',
        correlationId: ORG, side: 'credit', amountMinor: '2500', memo: null,
      },
      {
        id: USER, journalEntryId: USER, effectiveDate: '2026-07-03', postedAt: NOW.toISOString(),
        description: 'Transfer', sourceDomain: 'wallet', sourceRecordId: 'tx-1',
        correlationId: USER, side: 'debit', amountMinor: '1000', memo: null,
      },
    ],
  }),
});

describe('FinancialStatementService', () => {
  it('derives movements and balances from normal-side journal lines', async () => {
    const adapter = gateway();
    const service = new FinancialStatementService(adapter, () => NOW);
    const statement = await service.getStatement({
      organizationId: ORG, actorId: USER, ownerType: 'user', ownerId: USER,
      from: '2026-07-01', to: '2026-07-31', cutoff: NOW.toISOString(),
    });
    expect(statement.entries.map((entry) => [entry.movementMinor, entry.balanceMinor])).toEqual([
      ['2500', '12500'], ['-1000', '11500'],
    ]);
    expect(statement.closingBalanceMinor).toBe('11500');
    expect(adapter.assertOwnerAccess).toHaveBeenCalledWith(expect.objectContaining({
      organizationId: ORG, ownerId: USER,
    }) as StatementQuery, USER);
  });

  it('rejects inverted dates, future cutoffs, and oversized pages before storage access', async () => {
    const adapter = gateway();
    const service = new FinancialStatementService(adapter, () => NOW);
    for (const request of [
      { from: '2026-08-01', to: '2026-07-01' },
      { from: '2026-02-30' },
      { to: '2026-13-01' },
      { cutoff: '2026-07-28T00:00:00.000Z' },
      { page: 0 },
      { limit: 0 },
      { limit: 101 },
    ]) {
      await expect(service.getStatement({
        organizationId: ORG, actorId: USER, ownerType: 'user', ownerId: USER, ...request,
      })).rejects.toBeInstanceOf(StatementValidationError);
    }
    expect(adapter.read).not.toHaveBeenCalled();
  });

  it('checks tenant-owner access before reading financial data', async () => {
    const adapter = gateway();
    adapter.assertOwnerAccess.mockRejectedValue(new Error('denied'));
    const service = new FinancialStatementService(adapter, () => NOW);
    await expect(service.getStatement({
      organizationId: ORG, actorId: USER, ownerType: 'group', ownerId: ORG,
    })).rejects.toThrow('denied');
    expect(adapter.read).not.toHaveBeenCalled();
  });
});
