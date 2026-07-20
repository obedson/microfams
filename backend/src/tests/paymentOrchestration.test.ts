import crypto from 'crypto';
import {
  DeterministicPaymentAdapter,
  parsePaystackPaymentEvent,
} from '../domains/financial/paymentAdapters.js';
import {
  paymentTransitionAllowed,
  refundTransitionAllowed,
} from '../domains/financial/paymentStateMachine.js';
import { reconcilePayoutCandidates } from '../domains/financial/reconciliationService.js';

describe('provider-neutral inbound payment orchestration', () => {
  const originalEnvironment = process.env.NODE_ENV;
  const originalSecret = process.env.DETERMINISTIC_PAYMENT_WEBHOOK_SECRET;

  afterEach(() => {
    process.env.NODE_ENV = originalEnvironment;
    process.env.DETERMINISTIC_PAYMENT_WEBHOOK_SECRET = originalSecret;
  });

  it('allowlists monotonic payment and refund transitions', () => {
    expect(paymentTransitionAllowed('created', 'requires_action')).toBe(true);
    expect(paymentTransitionAllowed('requires_action', 'succeeded')).toBe(true);
    expect(paymentTransitionAllowed('succeeded', 'partially_refunded')).toBe(true);
    expect(paymentTransitionAllowed('partially_refunded', 'refunded')).toBe(true);
    expect(paymentTransitionAllowed('succeeded', 'processing')).toBe(false);
    expect(paymentTransitionAllowed('refunded', 'succeeded')).toBe(false);
    expect(refundTransitionAllowed('created', 'processing')).toBe(true);
    expect(refundTransitionAllowed('processing', 'succeeded')).toBe(true);
    expect(refundTransitionAllowed('succeeded', 'processing')).toBe(false);
  });

  it('returns contract-compatible deterministic initialization and refund outcomes', async () => {
    const adapter = new DeterministicPaymentAdapter();
    const initialized = await adapter.initialize({
      internalReference: 'PAY-test-reference',
      amountMinor: 125050,
      currency: 'NGN',
      customerEmail: 'payer@example.test',
      callbackUrl: 'https://example.test/callback',
      metadata: { source_id: 'source-1' },
    });
    expect(initialized).toEqual(expect.objectContaining({
      status: 'requires_action',
      amountMinor: 125050,
      currency: 'NGN',
    }));
    expect(initialized.authorizationUrl).toContain('PAY-test-reference');

    const refund = await adapter.refund({
      internalReference: 'REF-test-reference',
      providerPaymentReference: 'PAY-test-reference',
      amountMinor: 25050,
      currency: 'NGN',
      reason: 'Test partial refund',
    });
    expect(refund).toEqual(expect.objectContaining({
      status: 'processing',
      amountMinor: 25050,
      currency: 'NGN',
    }));
  });

  it('verifies the exact raw webhook bytes and rejects changed content', () => {
    process.env.DETERMINISTIC_PAYMENT_WEBHOOK_SECRET = 'deterministic-secret';
    const adapter = new DeterministicPaymentAdapter();
    const raw = Buffer.from(JSON.stringify({
      event: 'charge.success',
      data: {
        id: 12345,
        reference: 'PAY-webhook-reference',
        amount: 45000,
        currency: 'NGN',
        status: 'success',
      },
    }));
    const signature = crypto.createHmac('sha512', 'deterministic-secret').update(raw).digest('hex');
    expect(adapter.verifyAndParseWebhook(raw, signature)).toEqual(expect.objectContaining({
      internalReference: 'PAY-webhook-reference',
      status: 'succeeded',
      amountMinor: 45000,
    }));
    expect(() => adapter.verifyAndParseWebhook(Buffer.concat([raw, Buffer.from(' ')]), signature))
      .toThrow('Invalid provider webhook signature');
  });

  it('normalizes reversal events without mutating the original success event', () => {
    expect(parsePaystackPaymentEvent({
      event: 'charge.reversal',
      data: {
        id: 7788,
        reference: 'PAY-reversal-reference',
        amount: 9900,
        currency: 'NGN',
        status: 'success',
      },
    })).toEqual(expect.objectContaining({
      eventType: 'charge.reversal',
      internalReference: 'PAY-reversal-reference',
      status: 'reversed',
      amountMinor: 9900,
    }));
  });

  it('reconciles inbound payments with the same exact identity rules as payouts', () => {
    const occurredAt = '2026-07-20T08:00:00.000Z';
    const internal = [{
      paymentId: 'payment-1',
      providerReference: 'provider-1',
      internalReference: 'PAY-reconcile-1',
      amountMinor: 50000,
      currency: 'NGN',
      direction: 'inbound' as const,
      occurredAt,
    }];
    const matches = reconcilePayoutCandidates(internal, [
      { ...internal[0] },
      { ...internal[0] },
      { ...internal[0], providerReference: 'provider-2' },
    ], 24);
    expect(matches.map((match) => match.state)).toEqual(['matched', 'duplicate', 'unmatched']);
    expect(matches[0].paymentId).toBe('payment-1');
  });
});
