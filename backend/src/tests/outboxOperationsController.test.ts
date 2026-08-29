import { outboxOperationsController } from '../controllers/outboxOperationsController.js';
import { supabase } from '../utils/supabase.js';

jest.mock('../utils/supabase.js', () => {
  const client = { from: jest.fn() };
  return { __esModule: true, supabase: client, default: client };
});

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

describe('outbox operations controller', () => {
  beforeEach(() => jest.clearAllMocks());

  it('returns aggregate queue state counts without event payloads', async () => {
    const select = jest.fn().mockResolvedValue({
      data: [
        { state: 'queued' },
        { state: 'queued' },
        { state: 'retry' },
        { state: 'dead_letter' },
      ],
      error: null,
    });
    (supabase.from as jest.Mock).mockReturnValue({ select });
    const res = response();

    await outboxOperationsController.bookingNotificationHealth({} as any, res);

    expect(supabase.from).toHaveBeenCalledWith('booking_domain_notification_outbox');
    expect(select).toHaveBeenCalledWith('state', { count: 'exact', head: false });
    expect(res.json).toHaveBeenCalledWith({
      states: { queued: 2, retry: 1, dead_letter: 1 },
      total: 4,
    });
    expect(JSON.stringify((res.json as jest.Mock).mock.calls[0][0])).not.toContain('payload');
  });

  it('returns a stable server error when queue health is unavailable', async () => {
    const select = jest.fn().mockResolvedValue({
      data: null,
      error: new Error('database unavailable'),
    });
    (supabase.from as jest.Mock).mockReturnValue({ select });
    const res = response();

    await outboxOperationsController.bookingNotificationHealth({} as any, res);

    expect(res.status).toHaveBeenCalledWith(500);
    expect(res.json).toHaveBeenCalledWith({ error: 'Failed to fetch outbox health' });
  });
});
