import crypto from 'node:crypto';
import { SupabasePlatformAdministrationRepository } from './platformAdministrationRepository.js';
import { PlatformAdministrationRepository } from './platformAdministrationTypes.js';

const reasonCodePattern = /^[A-Z][A-Z0-9_]{2,63}$/;

export class PlatformAdministrationError extends Error {
  constructor(
    readonly code: string,
    readonly status: number,
    message = code,
  ) {
    super(message);
  }
}

const validateReasonCode = (reasonCode: string): string => {
  const normalized = reasonCode.trim().toUpperCase();
  if (!reasonCodePattern.test(normalized)) {
    throw new PlatformAdministrationError('INVALID_REASON_CODE', 400);
  }
  return normalized;
};

const commandFailure = () => new PlatformAdministrationError(
  'PLATFORM_ADMINISTRATION_COMMAND_FAILED',
  409,
  'The platform administration command could not be completed',
);

export class PlatformAdministrationService {
  constructor(private readonly repository: PlatformAdministrationRepository) {}

  async isAuthorized(userId: string): Promise<boolean> {
    return this.repository.isActiveAdministrator(userId);
  }

  async list() {
    return this.repository.listActiveAdministrators();
  }

  async grant(actorId: string, userId: string, reasonCode: string, expiresAt?: string) {
    try {
      return await this.repository.grant(
        actorId,
        userId,
        validateReasonCode(reasonCode),
        expiresAt,
      );
    } catch (error) {
      if (error instanceof PlatformAdministrationError) throw error;
      throw commandFailure();
    }
  }

  async revoke(actorId: string, userId: string, reasonCode: string) {
    try {
      return await this.repository.revoke(actorId, userId, validateReasonCode(reasonCode));
    } catch (error) {
      if (error instanceof PlatformAdministrationError) throw error;
      throw commandFailure();
    }
  }

  async suspend(
    actorId: string,
    userId: string,
    caseId: string,
    reasonCode: string,
    idempotencyKey: string,
    reasonNote?: string,
  ) {
    if (idempotencyKey.trim().length < 8 || idempotencyKey.length > 160) {
      throw new PlatformAdministrationError('IDEMPOTENCY_KEY_REQUIRED', 400);
    }
    const note = reasonNote?.trim();
    if (note && note.length > 1000) {
      throw new PlatformAdministrationError('INVALID_REASON_NOTE', 400);
    }
    try {
      return await this.repository.suspend(
        actorId,
        userId,
        caseId,
        validateReasonCode(reasonCode),
        idempotencyKey.trim(),
        crypto.createHash('sha256').update(JSON.stringify({ userId, caseId, reasonCode: validateReasonCode(reasonCode), note })).digest('hex'),
        note || undefined,
      );
    } catch (error) {
      if (error instanceof PlatformAdministrationError) throw error;
      throw commandFailure();
    }
  }

  async resume(actorId: string, userId: string, reasonCode: string) {
    try {
      return await this.repository.resume(actorId, userId, validateReasonCode(reasonCode));
    } catch (error) {
      if (error instanceof PlatformAdministrationError) throw error;
      throw commandFailure();
    }
  }
}

export const platformAdministrationService = new PlatformAdministrationService(
  new SupabasePlatformAdministrationRepository(),
);
