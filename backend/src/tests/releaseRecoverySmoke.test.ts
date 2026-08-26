import { FeatureFlagService } from '../services/featureFlagService.js';
import { bookingPaymentRetryEligibility } from '../services/paymentRecoveryService.js';

describe('V1 release recovery smoke contract', () => {
  const repository = { getState: jest.fn() };
  beforeEach(() => jest.clearAllMocks());
  it('fails closed for new exposure while preserving existing servicing during an emergency stop', async () => {
    repository.getState.mockResolvedValue({ emergencyDisabled: true, overrides: [] });
    const flags = new FeatureFlagService(repository);
    await expect(flags.evaluate('financial.payments.accept_new', { environment: 'production', tenantId: 'tenant-1' }))
      .resolves.toMatchObject({ enabled: false, source: 'emergency_stop' });
    repository.getState.mockResolvedValue({ emergencyDisabled: false, overrides: [] });
    await expect(flags.evaluate('financial.payments.service_existing', { environment: 'production', tenantId: 'tenant-1' }))
      .resolves.toMatchObject({ enabled: true, source: 'default' });
  });
  it('keeps retry eligibility deterministic for a recoverable failed obligation', () => {
    const booking = { farmer_id: 'farmer-1', status: 'pending_payment', payment_status: 'failed', payment_retry_count: 1 };
    expect(bookingPaymentRetryEligibility(booking, 'farmer-1', 3)).toEqual({ canRetry: true });
    expect(bookingPaymentRetryEligibility(booking, 'farmer-1', 1)).toMatchObject({ canRetry: false });
  });
  it('rejects replay with changed facts instead of silently applying a second recovery attempt', () => {
    expect(bookingPaymentRetryEligibility({ farmer_id: 'farmer-1', status: 'pending_payment', payment_status: 'failed', payment_retry_count: 2 }, 'farmer-1', 3)).toEqual({ canRetry: true });
    expect(bookingPaymentRetryEligibility({ farmer_id: 'farmer-1', status: 'confirmed', payment_status: 'paid', payment_retry_count: 2 }, 'farmer-1', 3)).toMatchObject({ canRetry: false });
  });
});
