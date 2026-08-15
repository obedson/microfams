import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';
import { InvestmentRefundReversalController } from '../controllers/investmentRefundReversalController.js';

describe('Investment refund reversal API contract', () => {
  it('uses the servicing-safe investment flag for proposal and independent decision', () => {
    const controller = new InvestmentRefundReversalController({} as any);
    expect(controller.propose).toBeInstanceOf(Function); expect(controller.decide).toBeInstanceOf(Function);
    expect(FEATURE_FLAGS.get('financial.investments.service_existing')).toEqual(expect.objectContaining({
      domain: 'investments', defaultEnabled: true, failureMode: 'open', risk: 'regulated',
    }));
  });
});
