import {
  assertLivePaymentActivationConfigured,
  configuredPaymentAdapter,
} from '../domains/financial/paymentAdapters.js';
import {
  assertLivePayoutActivationConfigured,
  configuredPayoutAdapter,
} from '../domains/financial/payoutAdapters.js';

describe('live provider activation evidence', () => {
  const originalEnv = { ...process.env };

  afterEach(() => {
    process.env = { ...originalEnv };
  });

  const paymentActivation = {
    PAYSTACK_LIVE_APPROVAL_ID: 'approval-test',
    PAYSTACK_CREDENTIALS_VALIDATED: 'true',
    PAYSTACK_WEBHOOK_VERIFIED: 'true',
    PAYSTACK_SETTLEMENT_ACCOUNT_ID: 'settlement-test',
    PAYMENT_RECONCILIATION_CERTIFIED: 'true',
    PAYMENT_COMPLIANCE_OWNER: 'compliance-test',
    PAYSTACK_ACTIVATION_EVIDENCE_ID: 'evidence-test',
  };

  it.each(Object.keys(paymentActivation))(
    'fails closed when live payment activation is missing %s',
    (missingKey) => {
      Object.assign(process.env, paymentActivation);
      delete process.env[missingKey];

      try {
        assertLivePaymentActivationConfigured();
        throw new Error('Expected live payment activation to fail');
      } catch (error: any) {
        expect(error.name).toBe('PaymentConfigurationError');
        expect(error.code).toBe('LIVE_PAYMENT_ACTIVATION_INCOMPLETE');
        expect(error.message).toBe('Live payment activation configuration is incomplete');
      }
    },
  );

  it('allows sandbox payments without live activation evidence', () => {
    process.env.NODE_ENV = 'test';
    process.env.PAYMENT_PROVIDER_MODE = 'sandbox';
    process.env.PAYSTACK_SECRET_KEY = 'sandbox-test';
    for (const key of Object.keys(paymentActivation)) delete process.env[key];

    expect(configuredPaymentAdapter().environment).toBe('sandbox');
  });

  const payoutActivation = {
    INTERSWITCH_LIVE_APPROVAL_ID: 'approval-test',
    INTERSWITCH_CREDENTIALS_VALIDATED: 'true',
    INTERSWITCH_BENEFICIARY_VALIDATION_CONFIGURED: 'true',
    INTERSWITCH_WEBHOOK_VERIFIED: 'true',
    INTERSWITCH_SETTLEMENT_ACCOUNT_ID: 'settlement-test',
    PAYOUT_RECONCILIATION_CERTIFIED: 'true',
    PAYOUT_COMPLIANCE_OWNER: 'compliance-test',
    INTERSWITCH_ACTIVATION_EVIDENCE_ID: 'evidence-test',
  };

  it.each(Object.keys(payoutActivation))(
    'fails closed when live payout activation is missing %s',
    (missingKey) => {
      Object.assign(process.env, payoutActivation);
      delete process.env[missingKey];

      try {
        assertLivePayoutActivationConfigured();
        throw new Error('Expected live payout activation to fail');
      } catch (error: any) {
        expect(error.name).toBe('PayoutConfigurationError');
        expect(error.code).toBe('LIVE_PAYOUT_ACTIVATION_INCOMPLETE');
        expect(error.message).toBe('Live payout activation configuration is incomplete');
      }
    },
  );

  it('allows sandbox payouts without live activation evidence', () => {
    process.env.NODE_ENV = 'test';
    process.env.PAYOUT_PROVIDER_MODE = 'sandbox';
    process.env.INTERSWITCH_CLIENT_ID = 'sandbox-test';
    process.env.INTERSWITCH_CLIENT_SECRET = 'sandbox-test';
    process.env.INTERSWITCH_WEBHOOK_SECRET = 'sandbox-test';
    for (const key of Object.keys(payoutActivation)) delete process.env[key];

    expect(configuredPayoutAdapter().environment).toBe('sandbox');
  });
});
