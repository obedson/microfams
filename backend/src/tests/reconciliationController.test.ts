import { ReconciliationController } from '../controllers/reconciliationController.js';
import { ReconciliationService } from '../domains/financial/reconciliationService.js';

const response = () => { const res: any = {}; res.status = jest.fn().mockReturnValue(res); res.json = jest.fn().mockReturnValue(res); return res; };

test('uses the authenticated tenant and actor for reconciliation resolution requests', async () => {
  const service = { requestExceptionResolution: jest.fn().mockResolvedValue({ state: 'pending' }) } as unknown as jest.Mocked<ReconciliationService>;
  const res = response();
  await new ReconciliationController(service).requestResolution({
    tenant: { id: '00000000-0000-4000-8000-000000001001' }, user: { id: '00000000-0000-4000-8000-000000001002' },
    params: { exceptionId: '00000000-0000-4000-8000-000000001003' },
    body: { organizationId: 'untrusted', actorId: 'untrusted', resolutionType: 'writeoff',
      resolutionReason: 'Verified provider variance requires approved write-off.', evidenceReference: 'case:reconciliation-1',
      compensatingJournalEntryId: '00000000-0000-4000-8000-000000001004', idempotencyKey: 'resolution-api-001' },
  } as any, res);
  expect(service.requestExceptionResolution).toHaveBeenCalledWith(expect.objectContaining({
    organizationId: '00000000-0000-4000-8000-000000001001', actorId: '00000000-0000-4000-8000-000000001002',
    exceptionId: '00000000-0000-4000-8000-000000001003', resolutionType: 'writeoff',
  }));
  expect(res.status).toHaveBeenCalledWith(201);
});
