import express from 'express';
import request from 'supertest';
import reportRoutes from '../routes/reports.js';
import { ReportingService } from '../services/reportingService.js';

jest.mock('../middleware/auth.js', () => ({ authenticateToken: (req: any, _res: any, next: any) => { req.user = { id: 'user-1', role: 'owner' }; next(); } }));
jest.mock('../middleware/tenant.js', () => ({
  resolveTenant: (req: any, _res: any, next: any) => { req.tenant = { id: 'org-a', role: 'owner', permissions: [] }; next(); },
  requireTenantRole: () => (_req: any, _res: any, next: any) => next(),
}));
jest.mock('../services/reportingService.js', () => ({ ReportingService: { exportToCSV: jest.fn() } }));

const app = express(); app.use(express.json()); app.use('/api/reports', reportRoutes);

describe('reporting tenant API', () => {
  it('passes the resolved tenant to exports and returns CSV', async () => {
    (ReportingService.exportToCSV as jest.Mock).mockResolvedValue('"id"\n"row-1"');
    await request(app).post('/api/reports/export').send({ table: 'bookings', fields: ['id'] }).expect(200, '"id"\n"row-1"');
    expect(ReportingService.exportToCSV).toHaveBeenCalledWith('org-a', 'bookings', ['id']);
  });
});
