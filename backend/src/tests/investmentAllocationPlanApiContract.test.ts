import { InvestmentAllocationPlanController } from '../controllers/investmentAllocationPlanController.js';
describe('Investment allocation plan API contract',()=>{it('exposes planning and independent approval handlers',()=>{const c=new InvestmentAllocationPlanController({} as any);expect(c.create).toBeInstanceOf(Function);expect(c.approve).toBeInstanceOf(Function);});});

