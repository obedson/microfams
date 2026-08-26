import fs from 'node:fs';
import path from 'node:path';
const read=(f:string)=>fs.readFileSync(path.resolve(process.cwd(),f),'utf8');
describe('financial account purpose contract',()=>{it('defines canonical wallet, escrow, investment, clearing, fee, and settlement purposes',()=>{const sql=read('../backend/migrations/create_financial_account_provisioning.sql'); for(const purpose of ['individual_wallet_funds','group_wallet_funds','escrow_funds_held','investor_subscriptions_payable','investor_redemptions_payable','provider_clearing','settlement_receivable','platform_fee_revenue','provider_processing_fee']) expect(sql).toContain(purpose);});});
