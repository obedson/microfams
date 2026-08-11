import {
  GenerateLoanScheduleCommand,
  LoanScheduleGateway,
  LoanScheduleService,
} from '../domains/financial/loanScheduleService.js';

const command: GenerateLoanScheduleCommand = {
  organizationId: '00000000-0000-4000-8000-000000000401',
  actorId: '00000000-0000-4000-8000-000000000402',
  applicationId: '00000000-0000-4000-8000-000000000403',
  offerId: '00000000-0000-4000-8000-000000000404',
  idempotencyKey: 'loan-schedule-generate-command-1',
};

describe('LoanScheduleService', () => {
  it('binds schedule generation to exact tenant, actor, application, and accepted offer facts', async () => {
    const gateway: jest.Mocked<LoanScheduleGateway> = { generate: jest.fn() };
    gateway.generate.mockResolvedValue({ schedule: { state: 'contractual' }, installments: [] });
    await expect(new LoanScheduleService(gateway).generate(command)).resolves.toMatchObject({
      schedule: { state: 'contractual' },
    });
    expect(gateway.generate).toHaveBeenCalledWith(command);
  });

  it('rejects malformed identifiers before executing storage', () => {
    const gateway: jest.Mocked<LoanScheduleGateway> = { generate: jest.fn() };
    const service = new LoanScheduleService(gateway);
    expect(() => service.generate({ ...command, offerId: 'another-tenant-offer' })).toThrow('Offer ID');
    expect(gateway.generate).not.toHaveBeenCalled();
  });

  it('requires a bounded idempotency key', () => {
    const service = new LoanScheduleService({ generate: jest.fn() });
    expect(() => service.generate({ ...command, idempotencyKey: 'short' })).toThrow('8 to 160');
  });
});
