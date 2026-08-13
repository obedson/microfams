import { InvestmentSubscriptionController } from '../controllers/investmentSubscriptionController.js';
describe('Investment subscription API contract',()=>{it('exposes intent and verified-settlement handlers',()=>{const c=new InvestmentSubscriptionController({} as any);expect(c.create).toBeInstanceOf(Function);expect(c.settle).toBeInstanceOf(Function);});});
