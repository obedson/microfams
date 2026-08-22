import { requestContext } from '../middleware/requestContext.js';

describe('request correlation context', () => {
  it('preserves a valid correlation id and emits it on the response', () => {
    const req = { header: () => '123e4567-e89b-12d3-a456-426614174000', correlationId: undefined as string | undefined };
    const setHeader = jest.fn();
    const res = { setHeader } as never;
    const next = jest.fn();
    requestContext(req as never, res, next);
    expect(req.correlationId).toBe('123e4567-e89b-12d3-a456-426614174000');
    expect(setHeader).toHaveBeenCalledWith('x-correlation-id', req.correlationId);
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