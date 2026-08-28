import { requireRawWebhookEnvelope, WebhookEnvelopeError } from '../services/webhookSecurityService.js';

describe('webhook-security findings envelope', () => {
  it('preserves the exact raw bytes and signature', () => {
    const rawBody = Buffer.from('{"event":"charge.success"}');
    const result = requireRawWebhookEnvelope(rawBody, 'abcdef0123456789');
    expect(result.rawBody).toBe(rawBody);
    expect(result.signature).toBe('abcdef0123456789');
  });

  it.each([
    {},
    '{"event":"charge.success"}',
    Buffer.alloc(0),
  ])('rejects a missing or reconstructed raw body', body => {
    expect(() => requireRawWebhookEnvelope(body, 'abcdef0123456789'))
      .toThrow(WebhookEnvelopeError);
  });

  it.each([undefined, '', '   ', 'a'.repeat(1025)])('rejects an invalid signature envelope', signature => {
    expect(() => requireRawWebhookEnvelope(Buffer.from('{}'), signature))
      .toThrow(WebhookEnvelopeError);
  });
});
