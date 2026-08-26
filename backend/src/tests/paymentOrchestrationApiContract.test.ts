import fs from 'node:fs';
import path from 'node:path';
const read=(f:string)=>fs.readFileSync(path.resolve(process.cwd(),f),'utf8');
describe('payment orchestration API contract',()=>{it('separates acquisition from servicing and preserves webhook recovery routes',()=>{const routes=read('src/routes/payments.ts'); const webhooks=read('src/routes/webhooks.ts'); expect(routes).toContain("requireFeature('financial.payments.accept_new')"); expect(routes).toContain("requireFeature('financial.payments.service_existing')"); expect(webhooks).toContain("paymentService.ingestWebhook"); expect(webhooks).toContain("investmentRefundSubmissionService.ingestCallback");});});
