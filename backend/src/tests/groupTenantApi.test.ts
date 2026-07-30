import express from 'express';
import request from 'supertest';
import { GroupModel } from '../models/Group.js';
import groupRoutes from '../routes/groups.js';

jest.mock('../middleware/auth.js', () => ({
  authenticateToken: (req: any, _res: any, next: any) => {
    req.user = { id: 'user-1', role: 'farmer' };
    next();
  },
}));
jest.mock('../middleware/tenant.js', () => ({
  resolveTenant: (req: any, _res: any, next: any) => {
    req.tenant = { id: 'organization-1', jurisdiction: 'NG' };
    next();
  },
}));
jest.mock('../middleware/requireFeature.js', () => ({
  requireFeature: () => (_req: any, _res: any, next: any) => next(),
}));
jest.mock('../models/Group.js', () => ({
  GroupModel: {
    findPublicNearby: jest.fn(),
    findPublicById: jest.fn(),
    getMembers: jest.fn(),
    canCreateGroup: jest.fn(),
    createWithPayment: jest.fn(),
    joinGroup: jest.fn(),
    confirmPayment: jest.fn(),
  },
}));
jest.mock('../services/walletService.js', () => ({
  WalletService: jest.fn().mockImplementation(() => ({
    provisionGroupNuban: jest.fn(),
  })),
}));
jest.mock('../utils/supabase.js', () => ({
  __esModule: true,
  default: { from: jest.fn() },
}));

const app = express();
app.use(express.json());
app.use('/api/groups', groupRoutes);
app.use((error: Error, _req: express.Request, res: express.Response, _next: express.NextFunction) => {
  res.status(500).json({ error: error.message });
});

describe('group public projection and tenant API', () => {
  beforeEach(() => jest.clearAllMocks());

  it('uses the privacy-minimized public directory for discovery', async () => {
    (GroupModel.findPublicNearby as jest.Mock)
      .mockResolvedValue([{ id: 'group-1' }]);

    await request(app)
      .get('/api/groups/search?state_id=1&lga_id=2')
      .expect(200, [{ id: 'group-1' }]);

    expect(GroupModel.findPublicNearby).toHaveBeenCalledWith('1', '2');
  });

  it('uses a neutral not-found result outside the public projection', async () => {
    (GroupModel.findPublicById as jest.Mock).mockResolvedValue(null);

    await request(app)
      .get('/api/groups/foreign-group-id')
      .expect(404, { error: 'Group not found' });

    expect(GroupModel.findPublicById).toHaveBeenCalledWith('foreign-group-id');
  });

  it('scopes member listings to the verified organization', async () => {
    (GroupModel.getMembers as jest.Mock).mockResolvedValue([]);

    await request(app)
      .get('/api/groups/group-1/members')
      .expect(200, []);

    expect(GroupModel.getMembers).toHaveBeenCalledWith(
      'group-1', 'organization-1',
    );
  });
});
