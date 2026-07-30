import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';

describe('booking settlement feature controls', () => {
  it.each([
    'booking.settlements.create',
    'booking.disputes.open',
    'financial.payments.accept_new',
    'financial.payouts.create',
  ])('fails closed for new exposure through %s', (flag) => {
    expect(FEATURE_FLAGS.get(flag)).toEqual(expect.objectContaining({
      defaultEnabled: false,
      failureMode: 'closed',
      risk: 'regulated',
    }));
  });

  it.each([
    'booking.settlements.service_existing',
    'booking.disputes.service_existing',
    'financial.payments.service_existing',
    'financial.payouts.service_existing',
  ])('keeps existing obligations serviceable through %s', (flag) => {
    expect(FEATURE_FLAGS.get(flag)).toEqual(expect.objectContaining({
      defaultEnabled: true,
      failureMode: 'open',
      risk: 'regulated',
    }));
  });
});
