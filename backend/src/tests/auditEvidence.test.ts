import { logAudit } from '../utils/audit.js';
import { withCorrelationContext } from '../utils/correlationContext.js';
import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

jest.mock('../utils/supabase.js', () => ({ supabase: { from: jest.fn() } }));
jest.mock('../utils/logger.js', () => ({ logger: { error: jest.fn() } }));

describe('audit evidence persistence', () => {
  beforeEach(() => jest.clearAllMocks());
  it('inherits request correlation for stable operational resource keys', async () => {
    const insert = jest.fn().mockResolvedValue({ error: null });
    (supabase.from as jest.Mock).mockReturnValue({ insert });
    const correlationId = '00000000-0000-4000-8000-000000000102';
    await withCorrelationContext(correlationId, () => logAudit({
      organization_id: '00000000-0000-4000-8000-000000000101', user_id: null,
      action: 'payment_timeout_job_executed', resource_type: 'system',
      resource_id: 'payment_timeout_job',
    }));
    expect(insert).toHaveBeenCalledWith(expect.objectContaining({
      correlation_id: correlationId, resource_id: null,
      resource_key: 'payment_timeout_job', details: {},
    }));
  });
  it('retains explicit correlation and UUID resource identifiers', async () => {
    const insert = jest.fn().mockResolvedValue({ error: null });
    (supabase.from as jest.Mock).mockReturnValue({ insert });
    await logAudit({ user_id: null, action: 'wallet.updated', resource_type: 'wallet',
      correlation_id: '00000000-0000-4000-8000-000000000105',
      resource_id: '00000000-0000-4000-8000-000000000104' });
    expect(insert).toHaveBeenCalledWith(expect.objectContaining({
      correlation_id: '00000000-0000-4000-8000-000000000105',
      resource_id: '00000000-0000-4000-8000-000000000104', resource_key: null,
    }));
  });
  it('generates correlation for background audit evidence', async () => {
    const insert = jest.fn().mockResolvedValue({ error: null });
    (supabase.from as jest.Mock).mockReturnValue({ insert });
    await logAudit({ user_id: null, action: 'job.completed', resource_type: 'system' });
    expect(insert).toHaveBeenCalledWith(expect.objectContaining({
      correlation_id: expect.stringMatching(/^[0-9a-f-]{36}$/i),
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