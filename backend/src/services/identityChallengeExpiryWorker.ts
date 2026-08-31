import { supabase } from '../utils/supabase.js';

export interface IdentityChallengeExpiryRepository {
  expire(limit: number, now: string): Promise<number>;
}

export class SupabaseIdentityChallengeExpiryRepository
implements IdentityChallengeExpiryRepository {
  async expire(limit: number, now: string): Promise<number> {
    const { data, error } = await supabase.rpc('expire_identity_verification_challenges', {
      p_limit: limit,
      p_now: now,
    });
    if (error) throw error;
    return Number(data ?? 0);
  }
}

export class IdentityChallengeExpiryWorker {
  constructor(
    private readonly repository: IdentityChallengeExpiryRepository,
    private readonly clock: () => Date = () => new Date(),
  ) {}

  async runOnce(limit = 100): Promise<{ expired: number }> {
    if (!Number.isInteger(limit) || limit < 1 || limit > 500) {
      throw new Error('Identity challenge expiry limit must be between 1 and 500');
    }
    return {
      expired: await this.repository.expire(limit, this.clock().toISOString()),
    };
  }
}

export const identityChallengeExpiryWorker = new IdentityChallengeExpiryWorker(
  new SupabaseIdentityChallengeExpiryRepository(),
);
