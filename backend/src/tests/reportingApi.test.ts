import express from 'express';
import request from 'supertest';
import reportRoutes from '../routes/reports.js';
import { ReportingService } from '../services/reportingService.js';

jest.mock('../middleware/auth.js', () => ({ authenticateToken: (req: any, _res: any, next: any) => { req.user = { id: 'user-1', role: 'owner' }; next(); } }));
jest.mock('../middleware/tenant.js', () => ({
  resolveTenant: (req: any, _res: any, next: any) => { req.tenant = { id: 'org-a', role: 'owner', permissions: [] }; next(); },
  requireTenantRole: () => (_req: any, _res: any, next: any) => next(),
}));
jest.mock("../services/reportingService.js", () => ({ ReportingService: { getBookingReport: jest.fn(), getEngagementReport: jest.fn(), getRetentionBI: jest.fn(), exportToCSV: jest.fn() } }));

const app = express(); app.use(express.json()); app.use('/api/reports', reportRoutes);

describe('reporting tenant API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('passes the resolved tenant to booking reports', async () => { (ReportingService.getBookingReport as jest.Mock).mockResolvedValue({ summary: { total_bookings: 0 }, bookings: [] }); await request(app).get('/api/reports/bookings?start_date=2027-01-01&end_date=2027-01-31').expect(200); expect(ReportingService.getBookingReport).toHaveBeenCalledWith('org-a', '2027-01-01', '2027-01-31'); });

  it('rejects invalid booking date ranges before service access', async () => { await request(app).get('/api/reports/bookings?start_date=2027-02-01&end_date=2027-01-31').expect(400, { error: 'Invalid reporting date range' }); expect(ReportingService.getBookingReport).not.toHaveBeenCalled(); });

  it('passes the resolved tenant to engagement and retention reports', async () => { (ReportingService.getEngagementReport as jest.Mock).mockResolvedValue({ period_days: 365 }); (ReportingService.getRetentionBI as jest.Mock).mockResolvedValue({ active_member_count: 2 }); await request(app).get('/api/reports/engagement?days=9999').expect(200); await request(app).get('/api/reports/retention').expect(200); expect(ReportingService.getEngagementReport).toHaveBeenCalledWith('org-a', 365); expect(ReportingService.getRetentionBI).toHaveBeenCalledWith('org-a'); });
  it('passes the resolved tenant to exports and returns CSV', async () => {
    (ReportingService.exportToCSV as jest.Mock).mockResolvedValue('"id"\n"row-1"');
    await request(app).post('/api/reports/export').send({ table: 'bookings', fields: ['id'] }).expect(200, '"id"\n"row-1"');
    expect(ReportingService.exportToCSV).toHaveBeenCalledWith('org-a', 'bookings', ['id']);
  });
});
