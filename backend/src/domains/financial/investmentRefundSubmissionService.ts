import crypto from 'crypto';
import { supabase } from '../../utils/supabase.js';
import { configuredPaymentAdapter } from './paymentAdapters.js';
import { PaymentAdapter, ProviderRefundResult } from './paymentTypes.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export interface SubmitInvestmentRefundCommand {
  organizationId: string; actorId: string; obligationId: string; correlationId: string; idempotencyKey: string;
}
export interface RecoverInvestmentRefundCommand {
  organizationId: string; actorId: string; obligationId: string;
}
interface PreparedAttempt {
  id: string; state: string; provider_name: string; provider_environment: 'deterministic' | 'sandbox' | 'live';
}
interface RefundObligation { id: string; amount_minor: number | string; currency: 'NGN'; }
interface PreparedSubmission {
  replayed: boolean; attempt: PreparedAttempt; obligation: RefundObligation; provider_payment_reference: string;
}
interface PreparedRecovery {
  attempt: PreparedAttempt; obligation: RefundObligation; provider_payment_reference: string;
}
type LocalRefundState = 'submitted' | 'processing' | 'unknown' | 'failed' | 'manual_review' | 'succeeded';
interface CompleteResultCommand {
  organizationId: string; actorId: string; attemptId: string; state: LocalRefundState;
  providerReportedState?: ProviderRefundResult['status']; providerReference?: string;
  reportedAmountMinor?: number; reportedCurrency?: string; failureCode?: string;
  failureReason?: string; resultHash: string;
}

export interface InvestmentRefundSubmissionGateway {
  begin(command: SubmitInvestmentRefundCommand): Promise<PreparedSubmission>;
  complete(command: CompleteResultCommand): Promise<unknown>;
  prepareRecovery(command: RecoverInvestmentRefundCommand): Promise<PreparedRecovery>;
  completeRecovery(command: CompleteResultCommand): Promise<unknown>;
}

export class SupabaseInvestmentRefundSubmissionGateway implements InvestmentRefundSubmissionGateway {
  private async rpc(name: string, args: Record<string, unknown>) {
    const { data, error } = await supabase.rpc(name, args);
    if (error || data === null) throw error ?? new Error('Investment refund storage returned no result.');
    return data;
  }

  begin(c: SubmitInvestmentRefundCommand) {
    return this.rpc('begin_investment_refund_submission', {
      p_organization: c.organizationId, p_actor: c.actorId, p_obligation: c.obligationId,
      p_correlation: c.correlationId, p_idempotency_key: c.idempotencyKey,
    }) as Promise<PreparedSubmission>;
  }

  complete(c: CompleteResultCommand) {
    return this.rpc('complete_investment_refund_submission', this.resultArgs(c));
  }

  prepareRecovery(c: RecoverInvestmentRefundCommand) {
    return this.rpc('prepare_investment_refund_recovery', {
      p_organization: c.organizationId, p_actor: c.actorId, p_obligation: c.obligationId,
    }) as Promise<PreparedRecovery>;
  }

  completeRecovery(c: CompleteResultCommand) {
    return this.rpc('complete_investment_refund_recovery', this.resultArgs(c));
  }

  private resultArgs(c: CompleteResultCommand) {
    return {
      p_organization: c.organizationId, p_actor: c.actorId, p_attempt: c.attemptId,
      p_state: c.state, p_provider_reported_state: c.providerReportedState ?? null,
      p_provider_reference: c.providerReference ?? null,
      p_reported_amount_minor: c.reportedAmountMinor ?? null,
      p_reported_currency: c.reportedCurrency ?? null, p_failure_code: c.failureCode ?? null,
      p_failure_reason: c.failureReason ?? null, p_result_hash: c.resultHash,
    };
  }
}

export class InvestmentRefundSubmissionValidationError extends Error {
  constructor(message: string) { super(message); this.name = 'InvestmentRefundSubmissionValidationError'; }
}

const resultHash = (facts: Record<string, unknown>) =>
  crypto.createHash('sha256').update(JSON.stringify(facts)).digest('hex');

export class InvestmentRefundSubmissionService {
  constructor(
    private readonly gateway: InvestmentRefundSubmissionGateway = new SupabaseInvestmentRefundSubmissionGateway(),
    private readonly adapterFactory: () => PaymentAdapter = configuredPaymentAdapter,
  ) {}

  async submit(command: SubmitInvestmentRefundCommand) {
    this.validateSubmission(command);
    const prepared = await this.gateway.begin(command);
    if (prepared.replayed || prepared.attempt.state !== 'prepared') {
      return { attempt: prepared.attempt, obligation: prepared.obligation };
    }
    const amountMinor = this.money(prepared.obligation);
    if (prepared.attempt.provider_environment === 'live') {
      return this.completeSubmission(command, prepared, {
        state: 'manual_review', failureCode: 'live_submission_not_activated',
        failureReason: 'Live investment refund submission is not enabled in this release.',
      });
    }
    let adapter: PaymentAdapter;
    try { adapter = this.adapterFactory(); } catch {
      return this.completeSubmission(command, prepared, {
        state: 'manual_review', failureCode: 'provider_configuration_incomplete',
        failureReason: 'The original provider is not configured for submission.',
      });
    }
    if (!this.matchesAdapter(prepared, adapter)) {
      return this.completeSubmission(command, prepared, {
        state: 'manual_review', failureCode: 'original_provider_unavailable',
        failureReason: 'The configured adapter does not match the original settlement provider.',
      });
    }
    let result: ProviderRefundResult;
    try {
      result = await adapter.refund({
        internalReference: `investment-refund-${prepared.attempt.id}`,
        providerPaymentReference: prepared.provider_payment_reference, amountMinor, currency: 'NGN',
        reason: 'Approved investment oversubscription refund',
      });
    } catch {
      return this.completeSubmission(command, prepared, {
        state: 'unknown', failureCode: 'provider_response_ambiguous',
        failureReason: 'The provider submission result is unknown and requires recovery.',
      });
    }
    return this.completeSubmission(command, prepared, this.outcome(result, prepared.obligation, false));
  }

  async recover(command: RecoverInvestmentRefundCommand) {
    this.validateIdentity(command);
    const prepared = await this.gateway.prepareRecovery(command);
    const amountMinor = this.money(prepared.obligation);
    let adapter: PaymentAdapter;
    try { adapter = this.adapterFactory(); } catch {
      return this.completeRecovery(command, prepared, {
        state: 'manual_review', failureCode: 'provider_configuration_incomplete',
        failureReason: 'The original provider is not configured for recovery.',
      });
    }
    if (!this.matchesAdapter(prepared, adapter)) {
      return this.completeRecovery(command, prepared, {
        state: 'manual_review', failureCode: 'original_provider_unavailable',
        failureReason: 'The configured adapter does not match the original settlement provider.',
      });
    }
    let result: ProviderRefundResult | undefined;
    try {
      result = await adapter.recoverRefund({
        internalReference: `investment-refund-${prepared.attempt.id}`,
        providerPaymentReference: prepared.provider_payment_reference, amountMinor, currency: 'NGN',
      });
    } catch {
      return this.completeRecovery(command, prepared, {
        state: 'unknown', failureCode: 'provider_recovery_ambiguous',
        failureReason: 'The provider recovery query did not return authoritative evidence.',
      });
    }
    if (!result) {
      return this.completeRecovery(command, prepared, {
        state: 'unknown', failureCode: 'provider_recovery_not_found',
        failureReason: 'The provider has not returned matching refund evidence.',
      });
    }
    return this.completeRecovery(command, prepared, this.outcome(result, prepared.obligation, true));
  }

  private outcome(result: ProviderRefundResult, obligation: RefundObligation, finalSuccess: boolean) {
    const amountMinor = Number(obligation.amount_minor);
    if (!Number.isSafeInteger(result.amountMinor) || result.amountMinor !== amountMinor
      || result.currency !== obligation.currency) {
      return {
        state: 'manual_review' as const, providerReportedState: result.status,
        providerReference: result.providerReference, reportedAmountMinor: result.amountMinor,
        reportedCurrency: result.currency, failureCode: 'provider_money_mismatch',
        failureReason: 'The provider result did not match the approved refund obligation.',
      };
    }
    const state: LocalRefundState = result.status === 'succeeded' && finalSuccess ? 'succeeded'
      : result.status === 'failed' || result.status === 'cancelled' ? 'failed'
        : result.status === 'submitted' ? 'submitted' : 'processing';
    return {
      state, providerReportedState: result.status, providerReference: result.providerReference,
      reportedAmountMinor: result.amountMinor, reportedCurrency: result.currency,
      failureCode: result.failureCode, failureReason: result.failureReason,
    };
  }

  private completeSubmission(command: SubmitInvestmentRefundCommand, prepared: PreparedSubmission,
    outcome: Omit<CompleteResultCommand, 'organizationId' | 'actorId' | 'attemptId' | 'resultHash'>) {
    return this.gateway.complete(this.completed(command, prepared.attempt.id, outcome));
  }

  private completeRecovery(command: RecoverInvestmentRefundCommand, prepared: PreparedRecovery,
    outcome: Omit<CompleteResultCommand, 'organizationId' | 'actorId' | 'attemptId' | 'resultHash'>) {
    return this.gateway.completeRecovery(this.completed(command, prepared.attempt.id, outcome));
  }

  private completed(command: { organizationId: string; actorId: string }, attemptId: string,
    outcome: Omit<CompleteResultCommand, 'organizationId' | 'actorId' | 'attemptId' | 'resultHash'>) {
    const facts = {
      state: outcome.state, providerReportedState: outcome.providerReportedState ?? null,
      providerReference: outcome.providerReference ?? null,
      reportedAmountMinor: outcome.reportedAmountMinor ?? null,
      reportedCurrency: outcome.reportedCurrency ?? null, failureCode: outcome.failureCode ?? null,
      failureReason: outcome.failureReason ?? null,
    };
    return { organizationId: command.organizationId, actorId: command.actorId, attemptId,
      ...outcome, resultHash: resultHash(facts) };
  }

  private money(obligation: RefundObligation) {
    const amountMinor = Number(obligation.amount_minor);
    if (!Number.isSafeInteger(amountMinor) || amountMinor <= 0 || obligation.currency !== 'NGN') {
      throw new InvestmentRefundSubmissionValidationError('Stored investment refund money is invalid.');
    }
    return amountMinor;
  }

  private matchesAdapter(prepared: PreparedRecovery, adapter: PaymentAdapter) {
    return adapter.name === prepared.attempt.provider_name
      && adapter.environment === prepared.attempt.provider_environment;
  }

  private validateSubmission(c: SubmitInvestmentRefundCommand) {
    this.validateIdentity(c);
    if (!UUID.test(c.correlationId) || typeof c.idempotencyKey !== 'string'
      || c.idempotencyKey.length < 8 || c.idempotencyKey.length > 160) {
      throw new InvestmentRefundSubmissionValidationError('Investment refund submission identity is invalid.');
    }
  }

  private validateIdentity(c: { organizationId: string; actorId: string; obligationId: string }) {
    if (!UUID.test(c.organizationId) || !UUID.test(c.actorId) || !UUID.test(c.obligationId)) {
      throw new InvestmentRefundSubmissionValidationError('Investment refund identity is invalid.');
    }
  }
}

export const investmentRefundSubmissionService = new InvestmentRefundSubmissionService();
