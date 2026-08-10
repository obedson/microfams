import crypto from 'crypto';
import { supabase } from '../../utils/supabase.js';
import { SupabaseFeatureFlagRepository } from '../../repositories/featureFlagRepository.js';
import { FeatureFlagService } from '../../services/featureFlagService.js';
import { FeatureFlagContext, FeatureFlagDecision } from '../../types/featureFlags.js';

export interface DueSavingsStandingOrder {
  id: string;
  organizationId: string;
  jurisdiction?: string;
}

export interface SavingsStandingOrderRepository {
  listDue(now: string, limit: number): Promise<DueSavingsStandingOrder[]>;
  service(organizationId: string, standingOrderId: string, workerId: string, at: string): Promise<{ state?: string }>;
}

export interface SavingsFeatureEvaluator {
  evaluate(key: string, context: FeatureFlagContext): Promise<FeatureFlagDecision>;
}

export class SupabaseSavingsStandingOrderRepository implements SavingsStandingOrderRepository {
  async listDue(now: string, limit: number): Promise<DueSavingsStandingOrder[]> {
    const { data, error } = await supabase
      .from('savings_standing_orders')
      .select('id, organization_id')
      .eq('state', 'active')
      .lte('next_due_at', now)
      .order('next_due_at', { ascending: true })
      .limit(limit);
    if (error) throw error;
    const rows = (data ?? []) as Array<{ id: string; organization_id: string }>;
    if (!rows.length) return [];
    const organizationIds = [...new Set(rows.map((row) => row.organization_id))];
    const { data: organizations, error: organizationError } = await supabase
      .from('organizations')
      .select('id, jurisdiction')
      .in('id', organizationIds);
    if (organizationError) throw organizationError;
    const jurisdictions = new Map(
      ((organizations ?? []) as Array<{ id: string; jurisdiction: string }>).map((row) => [row.id, row.jurisdiction]),
    );
    return rows.map((row) => ({
      id: row.id,
      organizationId: row.organization_id,
      jurisdiction: jurisdictions.get(row.organization_id),
    }));
  }

  async service(organizationId: string, standingOrderId: string, workerId: string, at: string) {
    const { data, error } = await supabase.rpc('service_savings_standing_order', {
      p_organization: organizationId,
      p_standing_order: standingOrderId,
      p_worker_id: workerId,
      p_at: at,
    });
    if (error || data === null) throw error ?? new Error('Standing-order servicing returned no result.');
    return data as { state?: string };
  }
}

const environment = (): FeatureFlagContext['environment'] => {
  if (process.env.NODE_ENV === 'production' || process.env.NODE_ENV === 'staging' || process.env.NODE_ENV === 'test') {
    return process.env.NODE_ENV;
  }
  return 'development';
};

export class SavingsStandingOrderWorker {
  constructor(
    private readonly repository: SavingsStandingOrderRepository,
    private readonly flags: SavingsFeatureEvaluator,
    private readonly clock: () => Date = () => new Date(),
    private readonly workerId = `savings-standing-${crypto.randomUUID()}`,
  ) {}

  async runOnce(limit = 50): Promise<{ due: number; serviced: number; skipped: number; errors: number }> {
    if (!Number.isSafeInteger(limit) || limit < 1 || limit > 200) throw new Error('Standing-order worker limit is invalid.');
    const now = this.clock();
    const due = await this.repository.listDue(now.toISOString(), limit);
    let serviced = 0;
    let skipped = 0;
    let errors = 0;
    for (const mandate of due) {
      const decision = await this.flags.evaluate('financial.savings.service_existing', {
        environment: environment(),
        tenantId: mandate.organizationId,
        jurisdiction: mandate.jurisdiction,
        now,
      });
      if (!decision.enabled) {
        skipped += 1;
        continue;
      }
      try {
        await this.repository.service(mandate.organizationId, mandate.id, this.workerId, now.toISOString());
        serviced += 1;
      } catch {
        errors += 1;
      }
    }
    return { due: due.length, serviced, skipped, errors };
  }
}

export const savingsStandingOrderWorker = new SavingsStandingOrderWorker(
  new SupabaseSavingsStandingOrderRepository(),
  new FeatureFlagService(new SupabaseFeatureFlagRepository()),
);
