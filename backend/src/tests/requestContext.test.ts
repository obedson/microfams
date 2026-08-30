import { requestContext } from '../middleware/requestContext.js';
import { currentCorrelationId } from '../utils/correlationContext.js';

describe('request correlation context', () => {
  it('preserves a valid correlation id in response and async context', () => {
    const id = '123e4567-e89b-12d3-a456-426614174000';
    const req = { header: () => id, correlationId: undefined as string | undefined };
    const setHeader = jest.fn();
    const next = jest.fn(() => expect(currentCorrelationId()).toBe(id));
    requestContext(req as never, { setHeader } as never, next);
    expect(req.correlationId).toBe(id);
    expect(setHeader).toHaveBeenCalledWith('x-correlation-id', id);
    expect(next).toHaveBeenCalled();
  });

  it('replaces malformed client values with a generated UUID', () => {
    const req = { header: () => 'client-supplied-not-a-uuid', correlationId: undefined as string | undefined };
    const res = { setHeader: jest.fn() } as never;
    requestContext(req as never, res, jest.fn());
    expect(req.correlationId).toMatch(/^[0-9a-f-]{36}$/i);
    expect(req.correlationId).not.toBe('client-supplied-not-a-uuid');
  });
});