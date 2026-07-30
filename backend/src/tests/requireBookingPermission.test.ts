import { jest } from '@jest/globals';
import { requireBookingPermission } from '../middleware/requireBookingPermission.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => ({
  supabase: { rpc: jest.fn() },
}));

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

describe('booking permission middleware', () => {
  beforeEach(() => jest.clearAllMocks());

  it('uses verified tenant identity and forwards one correlation identifier', async () => {
    (supabase.rpc as jest.Mock).mockResolvedValue({
      data: { allowed: true },
      error: null,
    } as never);
    const next = jest.fn();
    const req: any = {
      headers: { 'idempotency-key': 'settlement-read-001' },
      params: { id: '00000000-0000-4000-8000-000000001003' },
      tenant: { id: '00000000-0000-4000-8000-000000001001' },
      user: { id: '00000000-0000-4000-8000-000000001002' },
    };
    await requireBookingPermission(
      'booking.settlements.read',
      'booking.settlement.read',
      'booking_settlement',
      'id',
    )(req, response(), next);

    expect(supabase.rpc).toHaveBeenCalledWith(
      'evaluate_booking_authorization',
      expect.objectContaining({
        p_organization_id: req.tenant.id,
        p_actor_id: req.user.id,
        p_required_permission: 'booking.settlements.read',
        p_resource_id: req.params.id,
        p_idempotency_key: 'settlement-read-001',
      }),
    );
    expect(req.headers['x-correlation-id']).toMatch(
      /^[0-9a-f]{8}-[0-9a-f-]{27}$/i,
    );
    expect(next).toHaveBeenCalledTimes(1);
  });

  it('returns a stable denial without calling the command handler', async () => {
    (supabase.rpc as jest.Mock).mockResolvedValue({
      data: { allowed: false },
      error: null,
    } as never);
    const next = jest.fn();
    const res = response();
    await requireBookingPermission(
      'booking.disputes.resolve',
      'booking.dispute.resolution.propose',
      'booking_dispute',
      'disputeId',
    )({
      headers: {},
      params: { disputeId: '00000000-0000-4000-8000-000000001004' },
      tenant: { id: '00000000-0000-4000-8000-000000001001' },
      user: { id: '00000000-0000-4000-8000-000000001002' },
    } as any, res, next);

    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      success: false,
      error: 'BOOKING_PERMISSION_DENIED',
    }));
    expect(next).not.toHaveBeenCalled();
  });

  it('fails closed when durable authorization evidence cannot be recorded', async () => {
    (supabase.rpc as jest.Mock).mockResolvedValue({
      data: null,
      error: { message: 'database unavailable' },
    } as never);
    const next = jest.fn();
    const res = response();
    await requireBookingPermission(
      'booking.settlements.release',
      'booking.settlement.release',
      'booking_settlement',
      'id',
    )({
      headers: {},
      params: { id: '00000000-0000-4000-8000-000000001005' },
      tenant: { id: '00000000-0000-4000-8000-000000001001' },
      user: { id: '00000000-0000-4000-8000-000000001002' },
    } as any, res, next);

    expect(res.status).toHaveBeenCalledWith(503);
    expect(next).not.toHaveBeenCalled();
  });

  it('fails closed when the authorization RPC rejects', async () => {
    (supabase.rpc as jest.Mock).mockRejectedValue(
      new Error('database unavailable') as never,
    );
    const next = jest.fn();
    const res = response();
    await requireBookingPermission(
      'booking.settlements.release',
      'booking.settlement.release',
      'booking_settlement',
      'id',
    )({
      headers: {},
      params: { id: '00000000-0000-4000-8000-000000001005' },
      tenant: { id: '00000000-0000-4000-8000-000000001001' },
      user: { id: '00000000-0000-4000-8000-000000001002' },
    } as any, res, next);

    expect(res.status).toHaveBeenCalledWith(503);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: 'BOOKING_AUTHORIZATION_UNAVAILABLE',
    }));
    expect(next).not.toHaveBeenCalled();
  });
});
