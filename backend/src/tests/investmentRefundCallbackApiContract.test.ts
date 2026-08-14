import request from 'supertest';
import app from '../index.js';
import { investmentRefundSubmissionService } from '../domains/financial/investmentRefundSubmissionService.js';

jest.mock('../domains/financial/investmentRefundSubmissionService.js', () => ({
  investmentRefundSubmissionService: { ingestCallback: jest.fn() },
}));

describe('Investment refund callback API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('preserves the exact raw body and provider signature', async () => {
    const raw = Buffer.from('{"event":"refund.processed","data":{"id":9001}}');
    (investmentRefundSubmissionService.ingestCallback as jest.Mock).mockResolvedValue({
      eventId: '00000000-0000-4000-8000-000000000106', state: 'succeeded', duplicate: false,
    });
    const response = await request(app).post('/api/webhooks/paystack/investment-refunds')
      .set('content-type', 'application/json').set('x-paystack-signature', 'abcdef0123456789').send(raw.toString('utf8'));
    expect(response.status).toBe(202);
    expect(investmentRefundSubmissionService.ingestCallback).toHaveBeenCalledWith(expect.any(Buffer), 'abcdef0123456789');
    expect((investmentRefundSubmissionService.ingestCallback as jest.Mock).mock.calls[0][0].equals(raw)).toBe(true);
    expect(response.body).toEqual(expect.objectContaining({ refund_state: 'succeeded', duplicate: false }));
  });

  it('rejects callbacks without a provider signature before ingestion', async () => {
    const response = await request(app).post('/api/webhooks/paystack/investment-refunds')
      .set('content-type', 'application/json').send('{}');
    expect(response.status).toBe(400);
    expect(investmentRefundSubmissionService.ingestCallback).not.toHaveBeenCalled();
  });
});
