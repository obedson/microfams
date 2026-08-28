import request from 'supertest';
import app from '../index.js';
import { paymentService } from '../domains/financial/paymentService.js';

jest.mock('../domains/financial/paymentService.js', () => ({
  paymentService: { ingestWebhook: jest.fn() },
}));

describe('payment webhook API contract', () => {
  beforeEach(() => jest.clearAllMocks());

  it('preserves the exact raw body and provider signature', async () => {
    const raw = Buffer.from('{"event":"charge.success","data":{"reference":"PAY-1"}}');
    (paymentService.ingestWebhook as jest.Mock).mockResolvedValue({ eventId: 'event-1', duplicate: false });
    const response = await request(app).post('/api/webhooks/paystack')
      .set('content-type', 'application/json').set('x-paystack-signature', 'abcdef0123456789').send(raw.toString('utf8'));
    expect(response.status).toBe(202);
    expect(paymentService.ingestWebhook).toHaveBeenCalledWith(expect.any(Buffer), 'abcdef0123456789');
    expect((paymentService.ingestWebhook as jest.Mock).mock.calls[0][0].equals(raw)).toBe(true);
  });

  it('rejects callbacks without a signature before ingestion', async () => {
    const response = await request(app).post('/api/webhooks/paystack')
      .set('content-type', 'application/json').send('{}');
    expect(response.status).toBe(400);
    expect(paymentService.ingestWebhook).not.toHaveBeenCalled();
  });
});
