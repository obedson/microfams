import { supabase } from '../utils/supabase.js';
import { FinancialAccountService } from '../domains/financial/financialAccountService.js';

jest.mock('../utils/supabase.js',()=>({supabase:{rpc:jest.fn()}}));
const rpcMock=supabase.rpc as jest.Mock;

describe('financial account provisioning',()=>{
 beforeEach(()=>rpcMock.mockReset());
 it('delegates canonical tenant provisioning to one atomic command',async()=>{
  rpcMock.mockResolvedValue({data:{id:'account-1',purpose:'escrow_funds_held'},error:null});
  const service=new FinancialAccountService();
  await expect(service.provision({organizationId:'org-1',actorId:'actor-1',code:'2200.ESCROW',name:'Escrow funds held',purpose:'escrow_funds_held',currency:'NGN',ownerType:'escrow_contract',ownerId:'escrow-1',effectiveFrom:'2026-07-27',idempotencyKey:'account-provision-001'})).resolves.toEqual({id:'account-1',purpose:'escrow_funds_held'});
  expect(rpcMock).toHaveBeenCalledWith('provision_financial_account',{p_organization:'org-1',p_actor:'actor-1',p_code:'2200.ESCROW',p_name:'Escrow funds held',p_purpose:'escrow_funds_held',p_currency:'NGN',p_owner_type:'escrow_contract',p_owner_id:'escrow-1',p_effective_from:'2026-07-27',p_key:'account-provision-001'});
 });
});
