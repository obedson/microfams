import { LoanDelinquencyController } from '../controllers/loanDelinquencyController.js';
import { LoanDelinquencyService } from '../domains/financial/loanDelinquencyService.js';

const response = () => { const res: any = {}; res.status = jest.fn().mockReturnValue(res); res.json = jest.fn().mockReturnValue(res); return res; };
const service = () => ({ assess: jest.fn() }) as unknown as jest.Mocked<LoanDelinquencyService>;

describe('loan delinquency API contract', () => {
  it('uses authenticated tenant and actor context and strips client identities', async () => {
    const domain = service(); domain.assess.mockResolvedValue({ state: 'delinquent' } as never); const res = response();
    await new LoanDelinquencyController(domain).assess({
      tenant: { id: '00000000-0000-4000-8000-000000000711' },
      user: { id: '00000000-0000-4000-8000-000000000712' },
      params: { applicationId: '00000000-0000-4000-8000-000000000713', contractId: '00000000-0000-4000-8000-000000000714' },
      body: { organizationId: 'untrusted', actorId: 'untrusted', assessedOn: '2026-08-13', correlationId: '00000000-0000-4000-8000-000000000715', idempotencyKey: 'delinquency-api-1' },
    } as any, res);
    expect(domain.assess).toHaveBeenCalledWith({
      organizationId: '00000000-0000-4000-8000-000000000711', actorId: '00000000-0000-4000-8000-000000000712',
      applicationId: '00000000-0000-4000-8000-000000000713', contractId: '00000000-0000-4000-8000-000000000714',
      assessedOn: '2026-08-13', correlationId: '00000000-0000-4000-8000-000000000715', idempotencyKey: 'delinquency-api-1',
    });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects incomplete commands before invoking the domain', async () => {
    const domain = service(); const res = response();
    await new LoanDelinquencyController(domain).assess({ tenant: { id: 'x' }, user: { id: 'y' }, params: {}, body: {} } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.assess).not.toHaveBeenCalled();
  });

  it('does not leak database details from rejected commands', async () => {
    const domain = service(); domain.assess.mockRejectedValue(new Error('tenant row and account secret') as never); const res = response();
    await new LoanDelinquencyController(domain).assess({ tenant: { id: '00000000-0000-4000-8000-000000000711' }, user: { id: '00000000-0000-4000-8000-000000000712' }, params: { applicationId: '00000000-0000-4000-8000-000000000713', contractId: '00000000-0000-4000-8000-000000000714' }, body: { assessedOn: '2026-08-13', correlationId: '00000000-0000-4000-8000-000000000715', idempotencyKey: 'delinquency-api-1' } } as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({ message: expect.not.stringContaining('secret') }));
  });
});
