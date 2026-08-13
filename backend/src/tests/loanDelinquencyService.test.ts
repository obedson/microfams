import { LoanDelinquencyService, LoanDelinquencyValidationError } from '../domains/financial/loanDelinquencyService.js';

const command = {
  organizationId: '00000000-0000-4000-8000-000000000701',
  actorId: '00000000-0000-4000-8000-000000000702',
  applicationId: '00000000-0000-4000-8000-000000000703',
  contractId: '00000000-0000-4000-8000-000000000704',
  assessedOn: '2026-08-13',
  correlationId: '00000000-0000-4000-8000-000000000705',
  idempotencyKey: 'loan-delinquency-1',
};

describe('loan delinquency service', () => {
  it('passes tenant-scoped assessment evidence to the atomic gateway', async () => {
    const gateway = { assess: jest.fn().mockResolvedValue({ state: 'delinquent' }) };
    await expect(new LoanDelinquencyService(gateway).assess(command)).resolves.toEqual({ state: 'delinquent' });
    expect(gateway.assess).toHaveBeenCalledWith(command);
  });

  it.each(['2026-02-30', '13-08-2026', ''])('rejects invalid assessment date %p', (assessedOn) => {
    const gateway = { assess: jest.fn() };
    expect(() => new LoanDelinquencyService(gateway).assess({ ...command, assessedOn }))
      .toThrow(LoanDelinquencyValidationError);
    expect(gateway.assess).not.toHaveBeenCalled();
  });

  it('rejects cross-tenant identifiers before storage', () => {
    const gateway = { assess: jest.fn() };
    expect(() => new LoanDelinquencyService(gateway).assess({ ...command, organizationId: 'other' }))
      .toThrow(LoanDelinquencyValidationError);
    expect(gateway.assess).not.toHaveBeenCalled();
  });
});
