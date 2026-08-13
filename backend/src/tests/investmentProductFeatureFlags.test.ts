import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';

describe('investment product feature controls', () => {
  it('fails closed for governed investment product configuration', () => {
    expect(FEATURE_FLAGS.get('financial.investments.configure')).toEqual(expect.objectContaining({
      domain: 'investments',
      defaultEnabled: false,
      failureMode: 'closed',
      risk: 'regulated',
    }));
  });

  it('keeps approved investment product reads available', () => {
    expect(FEATURE_FLAGS.get('financial.investments.read')).toEqual(expect.objectContaining({
      domain: 'investments',
      defaultEnabled: true,
      failureMode: 'open',
      risk: 'regulated',
    }));
  });
});
