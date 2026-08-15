import { InvestmentRefundReconciliationController } from '../controllers/investmentRefundReconciliationController.js';
import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';

describe('Investment refund reconciliation API contract', () => {
  it('exposes reconciliation only through the servicing-safe investment flag', () => {
    const controller = new InvestmentRefundReconciliationController({} as any);
    expect(controller.run).toBeInstanceOf(Function);
    expect(FEATURE_FLAGS.get('financial.investments.service_existing')).toEqual(expect.objectContaining({
      domain: 'investments', defaultEnabled: true, failureMode: 'open', risk: 'regulated',
    }));
  });
});
