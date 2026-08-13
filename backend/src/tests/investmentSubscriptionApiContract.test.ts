import { InvestmentSubscriptionController } from '../controllers/investmentSubscriptionController.js';
describe('Investment subscription API contract',()=>{it('exposes a subscription-intent handler',()=>{expect(new InvestmentSubscriptionController({} as any).create).toBeInstanceOf(Function);});});
