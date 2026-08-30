import { logAudit } from '../utils/audit.js';
import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

jest.mock('../utils/supabase.js', () => ({ supabase: { from: jest.fn() } }));
jest.mock('../utils/logger.js', () => ({ logger: { error: jest.fn() } }));

describe('audit evidence persistence', () => {
  beforeEach(() => jest.clearAllMocks());
  it('persists stable resource keys with tenant and correlation attribution', async () => {
    const insert = jest.fn().mockResolvedValue({ error: null });
    (supabase.from as jest.Mock).mockReturnValue({ insert });
    await expect(logAudit({
      organization_id: '00000000-0000-4000-8000-000000000101', user_id: null,
      correlation_id: '00000000-0000-4000-8000-000000000102',
      action: 'payment_timeout_job_executed', resource_type: 'system',
      resource_id: 'payment_timeout_job',
    })).resolves.toBe(true);
    expect(insert).toHaveBeenCalledWith(expect.objectContaining({
      resource_id: null, resource_key: 'payment_timeout_job', details: {},
    }));
  });
  it('retains UUID resource identifiers in the established column', async () => {
    const insert = jest.fn().mockResolvedValue({ error: null });
    (supabase.from as jest.Mock).mockReturnValue({ insert });
    await logAudit({ user_id: null, action: 'wallet.updated', resource_type: 'wallet',
      resource_id: '00000000-0000-4000-8000-000000000104' });
    expect(insert).toHaveBeenCalledWith(expect.objectContaining({
      resource_id: '00000000-0000-4000-8000-000000000104', resource_key: null,
    }));
  });
  it('reports storage failures without exposing audit details', async () => {
    const insert = jest.fn().mockResolvedValue({ error: { message: 'database unavailable' } });
    (supabase.from as jest.Mock).mockReturnValue({ insert });
    await expect(logAudit({ user_id: null, action: 'wallet.updated',
      resource_type: 'wallet', details: { secret: 'must-not-be-logged' } })).resolves.toBe(false);
    expect(logger.error).toHaveBeenCalledWith('Audit evidence persistence failed',
      expect.not.objectContaining({ details: expect.anything() }));
  });
});