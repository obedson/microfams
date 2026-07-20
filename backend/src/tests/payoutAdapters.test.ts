import crypto from 'crypto';
import {
  assertLivePayoutActivationConfigured,
  configuredPayoutAdapter,
  DeterministicPayoutAdapter,
  parseNormalizedEvent,
} from '../domains/financial/payoutAdapters.js';

describe('payout adapters', () => {
  const originalEnv = { ...process.env };
  afterEach(() => { process.env = { ...originalEnv }; });

  it('uses a deterministic adapter outside production without pretending to be live', async () => {
    process.env.NODE_ENV = 'test';
    delete process.env.PAYOUT_PROVIDER_MODE;
    const adapter = configuredPayoutAdapter();
    expect(adapter.environment).toBe('deterministic');
    await expect(adapter.validateDestination('0000000000', '044')).resolves.toEqual({
      accountName: 'Synthetic Test Beneficiary', bankCode: '044',
    });
    const result = await adapter.submit({
      internalReference: 'WD-test-reference', amountMinor: 100000, currency: 'NGN',
      narration: 'Test', destination: { accountNumber: '0000000000', bankCode: '044', accountName: 'Synthetic User' },
    });
    expect(result).toMatchObject({ status: 'processing', amountMinor: 100000, currency: 'NGN' });
  });

  it('verifies the raw webhook bytes and rejects a tampered signature', () => {
    process.env.DETERMINISTIC_PAYOUT_WEBHOOK_SECRET = 'test-only-secret';
    const adapter = new DeterministicPayoutAdapter();
    const raw = Buffer.from(JSON.stringify({
      eventId: 'evt-1', internalReference: 'WD-test-reference', providerReference: 'DET-WD-test-reference',
      status: 'succeeded', amountMinor: 100000, currency: 'NGN',
    }));
    const signature = crypto.createHmac('sha256', 'test-only-secret').update(raw).digest('hex');
    expect(adapter.verifyAndParseWebhook(raw, signature)).toMatchObject({ status: 'succeeded', amountMinor: 100000 });
    expect(() => adapter.verifyAndParseWebhook(Buffer.concat([raw, Buffer.from(' ')]), signature)).toThrow('signature');
  });

  it('normalizes provider statuses but rejects invalid money and currency', () => {
    expect(parseNormalizedEvent({
      reference: 'WD-test-reference', status: 'completed', amount: 12345, currency: 'NGN',
    }).status).toBe('succeeded');
    expect(() => parseNormalizedEvent({ reference: 'WD-test-reference', status: 'success', amount: 1.5 })).toThrow('amount');
    expect(() => parseNormalizedEvent({ reference: 'WD-test-reference', status: 'success', amount: 100, currency: 'USD' })).toThrow('currency');
  });

  it('fails closed when live approval and reconciliation certification are absent', () => {
    process.env.NODE_ENV = 'production';
    process.env.PAYOUT_PROVIDER_MODE = 'live';
    process.env.INTERSWITCH_CLIENT_ID = 'synthetic';
    process.env.INTERSWITCH_CLIENT_SECRET = 'synthetic';
    process.env.INTERSWITCH_WEBHOOK_SECRET = 'synthetic';
    delete process.env.INTERSWITCH_LIVE_APPROVAL_ID;
    delete process.env.PAYOUT_RECONCILIATION_CERTIFIED;
    expect(configuredPayoutAdapter().environment).toBe('live');
    expect(() => assertLivePayoutActivationConfigured()).toThrow('approval metadata');
  });

  it('rejects an unknown provider mode instead of silently selecting an adapter', () => {
    process.env.PAYOUT_PROVIDER_MODE = 'unknown';
    expect(() => configuredPayoutAdapter()).toThrow('mode is invalid');
  });
});
