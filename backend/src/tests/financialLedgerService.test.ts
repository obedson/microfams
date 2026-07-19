import { FinancialLedgerService, FinancialFeatureDisabledError, FinancialValidationError } from '../domains/financial/financialLedgerService.js';
import { FinancialFeatureGate, FinancialJournalGateway, PostJournalCommand } from '../domains/financial/types.js';

const organizationId = '00000000-0000-4000-8000-000000000101';
const actorId = '00000000-0000-4000-8000-000000000101';
const assetAccountId = '00000000-0000-4000-8000-000000001001';
const liabilityAccountId = '00000000-0000-4000-8000-000000001002';

const command = (): PostJournalCommand => ({
  organizationId,
  actorId,
  currency: 'NGN',
  effectiveDate: '2026-07-19',
  sourceDomain: 'wallets',
  sourceRecordId: 'wallet-funding-1',
  idempotencyKey: 'wallet-funding-1',
  correlationId: '00000000-0000-4000-8000-000000009001',
  description: 'Confirmed wallet funding',
  lines: [
    { accountId: assetAccountId, lineNumber: 1, side: 'debit', amountMinor: 10000n },
    { accountId: liabilityAccountId, lineNumber: 2, side: 'credit', amountMinor: 10000n },
  ],
});

const enabledGate = (): FinancialFeatureGate => ({
  evaluate: jest.fn().mockResolvedValue({ enabled: true, reason: 'tenant override' }),
});

const gateway = (): FinancialJournalGateway => ({
  post: jest.fn().mockResolvedValue('00000000-0000-4000-8000-000000009999'),
});

describe('FinancialLedgerService', () => {
  it('fails closed before touching the posting gateway', async () => {
    const postingGateway = gateway();
    const service = new FinancialLedgerService(postingGateway, {
      evaluate: jest.fn().mockResolvedValue({ enabled: false, reason: 'not approved for tenant' }),
    }, 'test');

    await expect(service.post(command())).rejects.toBeInstanceOf(FinancialFeatureDisabledError);
    expect(postingGateway.post).not.toHaveBeenCalled();
  });

  it('rejects an unbalanced journal', async () => {
    const input = command();
    input.lines[1].amountMinor = 9999n;
    const service = new FinancialLedgerService(gateway(), enabledGate(), 'test');

    await expect(service.post(input)).rejects.toThrow('positive and balanced');
  });

  it('rejects duplicate line numbers and invalid integer money', async () => {
    const duplicate = command();
    duplicate.lines[1].lineNumber = 1;
    const service = new FinancialLedgerService(gateway(), enabledGate(), 'test');
    await expect(service.post(duplicate)).rejects.toThrow('line numbers must be unique');

    const invalid = command();
    invalid.lines[0].amountMinor = 0n;
    await expect(service.post(invalid)).rejects.toBeInstanceOf(FinancialValidationError);
  });

  it('rejects impossible calendar dates', async () => {
    const input = command();
    input.effectiveDate = '2026-02-30';
    const postingGateway = gateway();
    const service = new FinancialLedgerService(postingGateway, enabledGate(), 'test');

    await expect(service.post(input)).rejects.toThrow('valid YYYY-MM-DD');
    expect(postingGateway.post).not.toHaveBeenCalled();
  });

  it('canonicalizes line order and produces a stable idempotency hash', async () => {
    const postingGateway = gateway();
    const service = new FinancialLedgerService(postingGateway, enabledGate(), 'test');
    const first = command();
    const second = command();
    second.lines.reverse();

    const firstResult = await service.post(first);
    const secondResult = await service.post(second);

    expect(firstResult.requestHash).toMatch(/^[a-f0-9]{64}$/);
    expect(secondResult.requestHash).toBe(firstResult.requestHash);
    const calls = (postingGateway.post as jest.Mock).mock.calls;
    expect(calls[0][0].lines.map((line: { lineNumber: number }) => line.lineNumber)).toEqual([1, 2]);
    expect(calls[0][0].lines[0].amountMinor).toBe('10000');
  });

  it('evaluates the tenant accounting flag with actor context', async () => {
    const featureGate = enabledGate();
    const service = new FinancialLedgerService(gateway(), featureGate, 'staging');
    await service.post(command());

    expect(featureGate.evaluate).toHaveBeenCalledWith('financial.accounting.post', {
      environment: 'staging',
      tenantId: organizationId,
      actorId,
      jurisdiction: undefined,
    });
  });
});
