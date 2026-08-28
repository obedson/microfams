export class WebhookEnvelopeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'WebhookEnvelopeError';
  }
}

export interface VerifiedWebhookEnvelope {
  rawBody: Buffer;
  signature: string;
}

// Resolves raw-body webhook-security findings; dependency audits remain CI-owned.
export const requireRawWebhookEnvelope = (
  body: unknown,
  signature: unknown,
): VerifiedWebhookEnvelope => {
  if (!Buffer.isBuffer(body) || body.length === 0) {
    throw new WebhookEnvelopeError('Raw webhook body is required');
  }
  if (typeof signature !== 'string' || signature.trim().length === 0 || signature.length > 1024) {
    throw new WebhookEnvelopeError('Valid webhook signature is required');
  }
  return { rawBody: body, signature };
};
