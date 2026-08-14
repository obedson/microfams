import { InvestmentRefundSubmissionController } from '../controllers/investmentRefundSubmissionController.js';
import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';

describe('Investment refund submission API contract', () => {
  it('exposes submission and recovery handlers with separate acquisition and servicing gates', () => {
    const controller = new InvestmentRefundSubmissionController({} as any);
    expect(controller.submit).toBeInstanceOf(Function);
    expect(controller.recover).toBeInstanceOf(Function);
    expect(FEATURE_FLAGS.get('financial.investments.refund_provider_submission')).toEqual(expect.objectContaining({
      domain: 'investments', defaultEnabled: false, failureMode: 'closed', risk: 'provider',
    }));
    expect(FEATURE_FLAGS.get('financial.investments.service_existing')).toEqual(expect.objectContaining({
      domain: 'investments', defaultEnabled: true, failureMode: 'open', risk: 'regulated',
    }));
  });
});
