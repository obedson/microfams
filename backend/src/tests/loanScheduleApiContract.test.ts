import { LoanScheduleController } from '../controllers/loanScheduleController.js';
import { LoanScheduleService } from '../domains/financial/loanScheduleService.js';

const organizationId = '00000000-0000-4000-8000-000000000401';
const actorId = '00000000-0000-4000-8000-000000000402';
const applicationId = '00000000-0000-4000-8000-000000000403';
const offerId = '00000000-0000-4000-8000-000000000404';

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

const service = () => ({ generate: jest.fn() }) as unknown as jest.Mocked<LoanScheduleService>;

describe('loan schedule API contract', () => {
  it('uses authenticated route context instead of client-supplied ownership', async () => {
    const domain = service();
    domain.generate.mockResolvedValue({ schedule: { state: 'contractual' } } as never);
    const res = response();
    await new LoanScheduleController(domain).generate({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId, offerId },
      body: {
        organizationId: '00000000-0000-4000-8000-000000000499',
        actorId: '00000000-0000-4000-8000-000000000498',
        idempotencyKey: 'loan-schedule-generate-api-1',
      },
    } as any, res);
    expect(domain.generate).toHaveBeenCalledWith({
      organizationId, actorId, applicationId, offerId,
      idempotencyKey: 'loan-schedule-generate-api-1',
    });
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('rejects incomplete commands before invoking the domain', async () => {
    const domain = service();
    const res = response();
    await new LoanScheduleController(domain).generate({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId, offerId }, body: {},
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(400);
    expect(domain.generate).not.toHaveBeenCalled();
  });

  it('does not leak database schedule details on a rejected command', async () => {
    const domain = service();
    domain.generate.mockRejectedValue(new Error('sensitive cross-tenant schedule row') as never);
    const res = response();
    await new LoanScheduleController(domain).generate({
      tenant: { id: organizationId }, user: { id: actorId }, params: { applicationId, offerId },
      body: { idempotencyKey: 'loan-schedule-generate-api-2' },
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: 'LOAN_SCHEDULE_COMMAND_REJECTED', message: expect.not.stringContaining('sensitive'),
    }));
  });
});
