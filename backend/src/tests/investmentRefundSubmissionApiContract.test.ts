import { InvestmentRefundSubmissionController } from '../controllers/investmentRefundSubmissionController.js';
import { FEATURE_FLAGS } from '../config/featureFlagCatalog.js';
describe('Investment refund submission API contract',()=>{
 it('exposes a submission handler behind a fail-closed provider flag',()=>{expect(new InvestmentRefundSubmissionController({} as any).submit).toBeInstanceOf(Function);expect(FEATURE_FLAGS.get('financial.investments.refund_provider_submission')).toEqual(expect.objectContaining({domain:'investments',defaultEnabled:false,failureMode:'closed',risk:'provider'}));});
});
