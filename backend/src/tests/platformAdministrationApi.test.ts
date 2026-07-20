import { jest } from '@jest/globals';
import { platformAdministrationController } from '../controllers/platformAdministrationController.js';
import {
  PlatformAdministrationError,
  platformAdministrationService,
} from '../domains/platform/platformAdministrationService.js';

jest.mock('../domains/platform/platformAdministrationService.js', () => {
  class MockPlatformAdministrationError extends Error {
    constructor(readonly code: string, readonly status: number, message = code) {
      super(message);
    }
  }
  return {
    PlatformAdministrationError: MockPlatformAdministrationError,
    platformAdministrationService: {
      list: jest.fn(),
      grant: jest.fn(),
      revoke: jest.fn(),
      suspend: jest.fn(),
      resume: jest.fn(),
    },
  };
});

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

describe('platform administration API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('grants an explicit assignment with a normalized reason', async () => {
    (platformAdministrationService.grant as jest.Mock).mockResolvedValue({
      userId: '00000000-0000-4000-8000-000000000202',
      status: 'active',
    } as never);
    const res = response();

    await platformAdministrationController.grant({
      user: { id: '00000000-0000-4000-8000-000000000201' },
      body: {
        userId: '00000000-0000-4000-8000-000000000202',
        reasonCode: 'security_team',
      },
    } as any, res);

    expect(platformAdministrationService.grant).toHaveBeenCalledWith(
      '00000000-0000-4000-8000-000000000201',
      '00000000-0000-4000-8000-000000000202',
      'SECURITY_TEAM',
      undefined,
    );
    expect(res.status).toHaveBeenCalledWith(201);
  });

  it('requires a machine-readable suspension reason', async () => {
    const res = response();

    await platformAdministrationController.suspend({
      user: { id: '00000000-0000-4000-8000-000000000201' },
      params: { id: '00000000-0000-4000-8000-000000000202' },
      body: { reasonNote: 'missing code' },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(400);
    expect(platformAdministrationService.suspend).not.toHaveBeenCalled();
  });

  it('does not expose persistence errors', async () => {
    (platformAdministrationService.resume as jest.Mock).mockRejectedValue(
      new PlatformAdministrationError(
        'PLATFORM_ADMINISTRATION_COMMAND_FAILED',
        409,
        'The platform administration command could not be completed',
      ) as never,
    );
    const res = response();

    await platformAdministrationController.resume({
      user: { id: '00000000-0000-4000-8000-000000000201' },
      params: { id: '00000000-0000-4000-8000-000000000202' },
      body: { reasonCode: 'APPEAL_APPROVED' },
    } as any, res);

    expect(res.status).toHaveBeenCalledWith(409);
    expect(JSON.stringify((res.json as jest.Mock).mock.calls[0][0]))
      .not.toContain('database');
  });
});
