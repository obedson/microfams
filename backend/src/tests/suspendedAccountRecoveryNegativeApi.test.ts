import { jest } from '@jest/globals';
import { suspendedAccountRecoveryController } from '../controllers/suspendedAccountRecoveryController.js';
import { SuspendedRecoveryError, suspendedAccountRecoveryService } from '../domains/trust/suspendedAccountRecoveryService.js';

jest.mock('../domains/trust/suspendedAccountRecoveryService.js', () => {
  class MockSuspendedRecoveryError extends Error {
    constructor(readonly code: string, readonly status: number) { super(code); }
  }
  return {
    SuspendedRecoveryError: MockSuspendedRecoveryError,
    suspendedAccountRecoveryService: { request: jest.fn(), inspect: jest.fn(), fileAppeal: jest.fn() },
  };
});

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

describe('suspended recovery negative API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('rejects malformed public inputs before the service boundary', async () => {
    const inspectResponse = response();
    await suspendedAccountRecoveryController.inspect({ query: { token: 'short' } } as any, inspectResponse);
    expect(inspectResponse.status).toHaveBeenCalledWith(400);
    expect(suspendedAccountRecoveryService.inspect).not.toHaveBeenCalled();

    const requestResponse = response();
    await suspendedAccountRecoveryController.request({ body: { email: 'not-an-email' } } as any, requestResponse);
    expect(requestResponse.status).toHaveBeenCalledWith(400);
    expect(suspendedAccountRecoveryService.request).not.toHaveBeenCalled();
  });

  it('maps invalid or expired tokens to one non-enumerating response', async () => {
    (suspendedAccountRecoveryService.inspect as jest.Mock).mockRejectedValue(
      new SuspendedRecoveryError('INVALID_OR_EXPIRED_RECOVERY_TOKEN', 404) as never,
    );
    const res = response();
    await suspendedAccountRecoveryController.inspect({ query: { token: 'A'.repeat(43) } } as any, res);
    expect(res.status).toHaveBeenCalledWith(404);
    expect(res.json).toHaveBeenCalledWith({ success: false, error: 'INVALID_OR_EXPIRED_RECOVERY_TOKEN' });
  });

  it('rejects consumed-token appeal attempts without leaking persistence details', async () => {
    (suspendedAccountRecoveryService.fileAppeal as jest.Mock).mockRejectedValue(
      new SuspendedRecoveryError('INVALID_OR_EXPIRED_RECOVERY_TOKEN', 404) as never,
    );
    const res = response();
    await suspendedAccountRecoveryController.fileAppeal({
      body: { token: 'A'.repeat(43), grounds: 'Material evidence was omitted.' },
      header: () => 'negative-appeal-key',
    } as any, res);
    expect(res.status).toHaveBeenCalledWith(404);
    expect(JSON.stringify((res.json as jest.Mock).mock.calls[0][0])).not.toMatch(/database|digest|userId/i);
  });

  it('converts unexpected inspection failures to a generic unavailable response', async () => {
    (suspendedAccountRecoveryService.inspect as jest.Mock).mockRejectedValue(new Error('database host detail') as never);
    const res = response();
    await suspendedAccountRecoveryController.inspect({ query: { token: 'A'.repeat(43) } } as any, res);
    expect(res.status).toHaveBeenCalledWith(503);
    expect(res.json).toHaveBeenCalledWith({ success: false, error: 'RECOVERY_SERVICE_UNAVAILABLE' });
  });
});