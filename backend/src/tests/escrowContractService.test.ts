import { EscrowContractGateway, EscrowContractService } from '../domains/financial/escrowContractService.js';

describe('EscrowContractService funding', () => {
  const gateway: jest.Mocked<EscrowContractGateway> = {
    create: jest.fn(),
    activate: jest.fn(),
    fund: jest.fn(),
  };
  const service = new EscrowContractService(gateway);

  beforeEach(() => jest.clearAllMocks());

  it('passes a valid wallet-funding command to the gateway', async () => {
    gateway.fund.mockResolvedValue({ id: 'funding-1' });
    const command = {
      p_organization: '00000000-0000-4000-8000-000000000101',
      p_actor: '00000000-0000-4000-8000-000000000102',
      p_contract: '00000000-0000-4000-8000-000000000103',
      p_idempotency_key: 'escrow-funding-001',
      p_correlation_id: '00000000-0000-4000-8000-000000000104',
    };
    await expect(service.fund(command)).resolves.toEqual({ id: 'funding-1' });
    expect(gateway.fund).toHaveBeenCalledWith(command);
  });

  it('rejects invalid evidence before persistence', async () => {
    expect(() => service.fund({ p_contract: '', p_idempotency_key: 'short', p_correlation_id: 'invalid' }))
      .toThrow('ESCROW_CONTRACT_INVALID');
    expect(gateway.fund).not.toHaveBeenCalled();
  });
});
