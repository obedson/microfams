import { Response } from 'express';
import { AuthRequest } from '../middleware/auth.js';
import { supabase } from '../utils/supabase.js';

export const outboxOperationsController = {
  async bookingNotificationHealth(_req: AuthRequest, res: Response) {
    const { data, error } = await supabase
      .from('booking_domain_notification_outbox')
      .select('state', { count: 'exact', head: false });
    if (error) return res.status(500).json({ error: 'Failed to fetch outbox health' });

    const counts = (data ?? []).reduce<Record<string, number>>((result, row: { state: string }) => {
      result[row.state] = (result[row.state] ?? 0) + 1;
      return result;
    }, {});
    return res.json({
      states: counts,
      total: Object.values(counts).reduce((sum, count) => sum + count, 0),
    });
  },
};
