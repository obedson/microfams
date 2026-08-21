import express from 'express';
import request from 'supertest';
import farmRecordRoutes from '../routes/farmRecords.js';
import { FarmRecordModel } from '../models/FarmRecord.js';
import { FarmRecordService } from '../services/farmRecordService.js';

jest.mock('../middleware/auth.js', () => ({
  authenticateToken: (req: any, _res: any, next: any) => {
    req.user = { id: 'farmer-1', role: 'farmer' };
    next();
  },
}));

jest.mock('../middleware/tenant.js', () => ({
  resolveTenant: (req: any, _res: any, next: any) => {
    req.tenant = { id: 'organization-1', role: 'member', permissions: [] };
    next();
  },
}));

jest.mock('../models/FarmRecord.js', () => ({
  FarmRecordModel: {
    update: jest.fn(),
    delete: jest.fn(),
    findByFarmer: jest.fn(),
    create: jest.fn(),
    getAnalytics: jest.fn(),
  },
}));

jest.mock('../services/farmRecordService.js', () => ({
  FarmRecordService: {
    linkToBooking: jest.fn(),
    getPropertyProductivityReport: jest.fn(),
    getRecommendations: jest.fn(),
  },
}));

const app = express();
app.use(express.json());
app.use('/api/farm-records', farmRecordRoutes);

describe('farm record API ownership boundary', () => {
  beforeEach(() => jest.clearAllMocks());

  it('validates booking and property references before creating a record', async () => {
    const validateCreateReferences = jest.fn().mockResolvedValue(undefined);
    (FarmRecordService as any).validateCreateReferences = validateCreateReferences;
    (FarmRecordModel.create as jest.Mock).mockResolvedValue({ id: 'record-1' });

    await request(app).post('/api/farm-records').send({
      livestock_type: 'goat', record_date: '2026-08-21',
      booking_id: 'booking-1', property_id: 'property-1',
    }).expect(201);

    expect(validateCreateReferences).toHaveBeenCalledWith(
      'booking-1', 'property-1', 'organization-1', 'farmer-1'
    );
    expect(FarmRecordModel.create).toHaveBeenCalledWith(expect.objectContaining({
      farmer_id: 'farmer-1', organization_id: 'organization-1',
      booking_id: 'booking-1', property_id: 'property-1',
    }));
  });

  it('passes tenant and authenticated farmer to update and delete commands', async () => {
    (FarmRecordModel.update as jest.Mock).mockResolvedValue({ id: 'record-1' });
    (FarmRecordModel.delete as jest.Mock).mockResolvedValue(undefined);

    await request(app).put('/api/farm-records/record-1').send({ notes: 'Updated' }).expect(200);
    await request(app).delete('/api/farm-records/record-1').expect(200);

    expect(FarmRecordModel.update).toHaveBeenCalledWith(
      'record-1', 'organization-1', 'farmer-1', { notes: 'Updated' }
    );
    expect(FarmRecordModel.delete).toHaveBeenCalledWith(
      'record-1', 'organization-1', 'farmer-1'
    );
  });

  it('passes tenant and authenticated farmer when linking a booking', async () => {
    (FarmRecordService.linkToBooking as jest.Mock).mockResolvedValue({ id: 'record-1' });

    await request(app)
      .patch('/api/farm-records/record-1/link-booking')
      .send({ booking_id: 'booking-1' })
      .expect(200);

    expect(FarmRecordService.linkToBooking).toHaveBeenCalledWith(
      'record-1', 'booking-1', 'organization-1', 'farmer-1'
    );
  });
});
