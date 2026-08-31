import {
  IdentityChallengeExpiryRepository,
  IdentityChallengeExpiryWorker,
} from '../services/identityChallengeExpiryWorker.js';

const repository = (): jest.Mocked<IdentityChallengeExpiryRepository> => ({
  expire: jest.fn(),
});

describe('IdentityChallengeExpiryWorker', () => {
  const now = new Date('2026-08-31T15:00:00.000Z');

  it('returns safe success when no challenge is due', async () => {
    const expiry = repository();
    expiry.expire.mockResolvedValue(0);
    await expect(new IdentityChallengeExpiryWorker(expiry, () => now).runOnce())
      .resolves.toEqual({ expired: 0 });
    expect(expiry.expire).toHaveBeenCalledWith(100, now.toISOString());
  });

  it('reports the bounded batch result', async () => {
    const expiry = repository();
    expiry.expire.mockResolvedValue(12);
    await expect(new IdentityChallengeExpiryWorker(expiry, () => now).runOnce(25))
      .resolves.toEqual({ expired: 12 });
    expect(expiry.expire).toHaveBeenCalledWith(25, now.toISOString());
  });

  it('rejects unsafe batch limits before database access', async () => {
    const expiry = repository();
    await expect(new IdentityChallengeExpiryWorker(expiry, () => now).runOnce(501))
      .rejects.toThrow('between 1 and 500');
    expect(expiry.expire).not.toHaveBeenCalled();
  });
});
