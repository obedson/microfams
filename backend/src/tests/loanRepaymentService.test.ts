import { LoanRepaymentService, LoanRepaymentValidationError } from '../domains/financial/loanRepaymentService.js';

const command = {
  organizationId: '00000000-0000-4000-8000-000000000601',
  actorId: '00000000-0000-4000-8000-000000000602',
  applicationId: '00000000-0000-4000-8000-000000000603',
  contractId: '00000000-0000-4000-8000-000000000604',
  amountMinor: 125000,
  effectiveDate: '2026-08-12',
  correlationId: '00000000-0000-4000-8000-000000000605',
  idempotencyKey: 'loan-repayment-1',
};

describe('loan repayment service', () => {
  it('passes tenant-scoped integer-minor-unit commands to the atomic gateway', async () => {
    const gateway = { record: jest.fn().mockResolvedValue({ remaining_minor: 0 }) };
    await expect(new LoanRepaymentService(gateway).record(command)).resolves.toEqual({ remaining_minor: 0 });
    expect(gateway.record).toHaveBeenCalledWith(command);
  });

  it.each([0, -1, 1.5, Number.MAX_SAFE_INTEGER + 1])('rejects invalid minor-unit amount %p', (amountMinor) => {
    const gateway = { record: jest.fn() };
    expect(() => new LoanRepaymentService(gateway).record({ ...command, amountMinor }))
      .toThrow(LoanRepaymentValidationError);
    expect(gateway.record).not.toHaveBeenCalled();
  });

  it.each(['2026-02-30', '12-08-2026', ''])('rejects invalid effective date %p', (effectiveDate) => {
    const gateway = { record: jest.fn() };
    expect(() => new LoanRepaymentService(gateway).record({ ...command, effectiveDate }))
      .toThrow(LoanRepaymentValidationError);
  });

  it('rejects cross-tenant identifiers before storage', () => {
    const gateway = { record: jest.fn() };
    expect(() => new LoanRepaymentService(gateway).record({ ...command, organizationId: 'other' }))
      .toThrow(LoanRepaymentValidationError);
    expect(gateway.record).not.toHaveBeenCalled();
  });
});
