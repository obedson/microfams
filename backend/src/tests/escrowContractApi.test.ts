import fs from 'node:fs';
import path from 'node:path';
const read = (file: string) => fs.readFileSync(path.resolve(process.cwd(), file), 'utf8');

describe('escrow contract API contract', () => {
  it('requires authentication, tenant ownership, and the acquisition flag', () => {
    const routes = read('src/routes/escrow.ts');
    expect(routes).toContain('authenticateToken, resolveTenant, requireTenantRole');
    expect(routes).toContain("requireFeature('financial.escrow.create')");
    expect(routes).toContain("router.post('/contracts'");
    expect(routes).toContain("router.post('/contracts/:contractId/activate'");
    expect(routes).toContain("router.post('/contracts/:contractId/fund'");
  });

  it('uses the approved RPCs and idempotency header', () => {
    const service = read('src/domains/financial/escrowContractService.ts');
    const controller = read('src/controllers/escrowController.ts');
    expect(service).toContain("create_escrow_contract_draft");
    expect(service).toContain("activate_escrow_contract");
    expect(service).toContain("fund_escrow_contract_from_wallet");
    expect(controller).toContain("req.headers['idempotency-key']");
    expect(controller).toContain('p_correlation_id: req.correlationId');
  });
});
