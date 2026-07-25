export type PlatformAdministratorStatus = 'active' | 'revoked';

export interface PlatformAdministrator {
  id: string;
  userId: string;
  status: PlatformAdministratorStatus;
  grantedAt: string;
  expiresAt: string | null;
  user?: {
    id: string;
    email: string;
    name: string;
    isSuspended: boolean;
  };
}

export interface PlatformAdministrationRepository {
  isActiveAdministrator(userId: string): Promise<boolean>;
  listActiveAdministrators(): Promise<PlatformAdministrator[]>;
  grant(actorId: string, userId: string, reasonCode: string, expiresAt?: string): Promise<unknown>;
  revoke(actorId: string, userId: string, reasonCode: string): Promise<unknown>;
  suspend(actorId: string, userId: string, reasonCode: string, reasonNote?: string): Promise<unknown>;
  resume(actorId: string, userId: string, reasonCode: string): Promise<unknown>;
}
