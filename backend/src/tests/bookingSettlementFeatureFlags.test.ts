import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';

describe('booking settlement feature controls', () => {
  it('fails closed for new settlement and dispute exposure', () => {
    expect(FEATURE_FLAGS.get('booking.settlements.create')).toEqual(expect.objectContaining({
      defaultEnabled: false,
      failureMode: 'closed',
      risk: 'regulated',
    }));
    expect(FEATURE_FLAGS.get('booking.disputes.open')).toEqual(expect.objectContaining({
      defaultEnabled: false,
      failureMode: 'closed',
      risk: 'regulated',
    }));
  });

  it('keeps existing settlement and dispute obligations serviceable', () => {
    expect(FEATURE_FLAGS.get('booking.settlements.service_existing')).toEqual(expect.objectContaining({
      defaultEnabled: true,
      failureMode: 'open',
      risk: 'regulated',
    }));
    expect(FEATURE_FLAGS.get('booking.disputes.service_existing')).toEqual(expect.objectContaining({
      defaultEnabled: true,
      failureMode: 'open',
      risk: 'regulated',
    }));
  });
});
