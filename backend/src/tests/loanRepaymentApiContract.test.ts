import { LoanRepaymentController } from '../controllers/loanRepaymentController.js';
import { LoanRepaymentService } from '../domains/financial/loanRepaymentService.js';

const response = () => { const res: any = {}; res.status = jest.fn().mockReturnValue(res); res.json = jest.fn().mockReturnValue(res); return res; };
const service = () => ({ record: jest.fn() }) as unknown as jest.Mocked<LoanRepaymentService>;

describe('loan repayment API contract', () => {
  it('uses authenticated tenant and actor context and strips client identities', async () => {
    const domain = service();
    domain.record.mockResolvedValue({ repayment_id: 'repayment' } as never);
    const res = response();
    await new LoanRepaymentController(domain).record({
      tenant: { id: '00000000-0000-4000-8000-000000000611' },
      user: { id: '00000000-0000-4000-8000-000000000612' },
      params: { applicationId: '00000000-0000-4000-8000-000000000613', contractId: '00000000-0000-4000-8000-000000000614' },
      body: { organizationId: 'untrusted', actorId: 'untrusted', amountMinor: 5000, effectiveDate: '2026-08-12', correlationId: '00000000-0000-4000-8000-000000000615', idempotencyKey: 'repayment-api-1' },
    } as any, res);
    expect(domain.record).toHaveBeenCalledWith({
      organizationId: '00000000-0000-4000-8000-000000000611', actorId: '00000000-0000-4000-8000-000000000612',
      applicationId: '00000000-0000-4000-8000-000000000613', contractId: '00000000-0000-4000-8000-000000000614',
      amountMinor: 5000, effectiveDate: '2026-08-12', correlationId: '00000000-0000-4000-8000-000000000615', idempotencyKey: 'repayment-api-1',
    });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects binary floating point amounts before invoking the domain', async () => {
    const domain = service(); const res = response();
    await new LoanRepaymentController(domain).record({ tenant: { id: 'x' }, user: { id: 'y' }, params: {}, body: { amountMinor: 12.5 } } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.record).not.toHaveBeenCalled();
  });

  it('does not leak database details from rejected commands', async () => {
    const domain = service(); domain.record.mockRejectedValue(new Error('tenant row and account secret') as never); const res = response();
    await new LoanRepaymentController(domain).record({ tenant: { id: '00000000-0000-4000-8000-000000000611' }, user: { id: '00000000-0000-4000-8000-000000000612' }, params: { applicationId: '00000000-0000-4000-8000-000000000613', contractId: '00000000-0000-4000-8000-000000000614' }, body: { amountMinor: 5000, effectiveDate: '2026-08-12', correlationId: '00000000-0000-4000-8000-000000000615', idempotencyKey: 'repayment-api-1' } } as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ message: expect.not.stringContaining('secret') }));
  });
});
