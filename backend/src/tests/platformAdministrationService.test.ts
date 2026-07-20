import { PlatformAdministrationService } from '../domains/platform/platformAdministrationService.js';
import { PlatformAdministrationRepository } from '../domains/platform/platformAdministrationTypes.js';

const repository = (): jest.Mocked<PlatformAdministrationRepository> => ({
  isActiveAdministrator: jest.fn(),
  listActiveAdministrators: jest.fn(),
  grant: jest.fn(),
  revoke: jest.fn(),
  suspend: jest.fn(),
  resume: jest.fn(),
});

describe('platform administration service', () => {
  it('uses explicit assignments instead of legacy user roles', async () => {
    const repo = repository();
    repo.isActiveAdministrator.mockResolvedValue(false);
    const service = new PlatformAdministrationService(repo);

    await expect(service.isAuthorized('legacy-admin')).resolves.toBe(false);
    expect(repo.isActiveAdministrator).toHaveBeenCalledWith('legacy-admin');
  });

  it('normalizes reason codes and bounded notes', async () => {
    const repo = repository();
    repo.suspend.mockResolvedValue({ status: 'active' });
    const service = new PlatformAdministrationService(repo);

    await service.suspend('actor-1', 'user-2', ' policy_breach ', ' reviewed evidence ');

    expect(repo.suspend).toHaveBeenCalledWith(
      'actor-1',
      'user-2',
      'POLICY_BREACH',
      'reviewed evidence',
    );
  });

  it('rejects malformed reason codes before persistence', async () => {
    const repo = repository();
    const service = new PlatformAdministrationService(repo);

    await expect(service.revoke('actor-1', 'user-2', 'not valid!'))
      .rejects.toMatchObject({ code: 'INVALID_REASON_CODE', status: 400 });
    expect(repo.revoke).not.toHaveBeenCalled();
  });

  it('rejects oversized suspension notes', async () => {
    const repo = repository();
    const service = new PlatformAdministrationService(repo);

    await expect(service.suspend('actor-1', 'user-2', 'POLICY_BREACH', 'x'.repeat(1001)))
      .rejects.toMatchObject({ code: 'INVALID_REASON_NOTE', status: 400 });
    expect(repo.suspend).not.toHaveBeenCalled();
  });

  it('does not expose database error details', async () => {
    const repo = repository();
    repo.resume.mockRejectedValue(new Error('sensitive database detail'));
    const service = new PlatformAdministrationService(repo);

    await expect(service.resume('actor-1', 'user-2', 'APPEAL_APPROVED'))
      .rejects.toMatchObject({
        code: 'PLATFORM_ADMINISTRATION_COMMAND_FAILED',
        status: 409,
      });
  });
});
