import fs from 'node:fs';
import path from 'node:path';

const read = (file: string) => fs.readFileSync(path.resolve(process.cwd(), file), 'utf8');

describe('outbox operations API contract', () => {
  it('exposes platform-admin-only booking notification queue health', () => {
    const routes = read('src/routes/admin.ts');
    expect(routes).toContain("router.use(requirePlatformAdministrator);");
    expect(routes).toContain("router.get('/operations/outbox/booking-notifications'");
    expect(routes).toContain("outboxOperationsController.bookingNotificationHealth");
  });

  it('returns aggregate state counts without exposing payloads', () => {
    const controller = read('src/controllers/outboxOperationsController.ts');
    expect(controller).toContain("select('state'");
    expect(controller).not.toContain('public_payload');
    expect(controller).not.toContain('event_key');
  });
});
