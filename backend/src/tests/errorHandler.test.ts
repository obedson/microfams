import multer from 'multer';
import {
  createError,
  errorHandler,
  notFound,
} from '../middleware/errorHandler.js';

const response = () => {
  const res: any = {};
  res.status = jest.fn().mockReturnValue(res);
  res.json = jest.fn().mockReturnValue(res);
  return res;
};

describe('API error envelope', () => {
  const req = {
    correlationId: '123e4567-e89b-12d3-a456-426614174000',
    originalUrl: '/api/missing',
  } as any;

  beforeEach(() => jest.clearAllMocks());

  it('emits stable codes and correlation evidence while preserving the V1 error alias', () => {
    const error = createError('The request conflicts with current state', 409, 'STATE_CONFLICT');
    error.details = { field: 'status' };
    const res = response();

    errorHandler(error, req, res, jest.fn());

    expect(res.status).toHaveBeenCalledWith(409);
    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      success: false,
      error: 'The request conflicts with current state',
      code: 'STATE_CONFLICT',
      message: 'The request conflicts with current state',
      correlationId: req.correlationId,
      details: { field: 'status' },
    }));
  });

  it('does not expose unexpected internal error messages', () => {
    const res = response();
    const failure = Object.assign(new Error('sensitive database detail'), { details: { query: 'secret' } });

    errorHandler(failure, req, res, jest.fn());

    const result = (res.json as jest.Mock).mock.calls[0][0];
    expect(result).toMatchObject({
      success: false,
      error: 'Internal Server Error',
      code: 'INTERNAL_SERVER_ERROR',
      correlationId: req.correlationId,
    });
    expect(JSON.stringify(result)).not.toContain('sensitive database detail');
    expect(result).not.toHaveProperty('details');
  });

  it('uses a machine-readable route-not-found code', () => {
    const next = jest.fn();
    notFound(req, response(), next);

    expect(next).toHaveBeenCalledWith(expect.objectContaining({
      statusCode: 404,
      code: 'ROUTE_NOT_FOUND',
    }));
  });

  it('normalizes upload failures without dropping the legacy message', () => {
    const res = response();
    errorHandler(new multer.MulterError('LIMIT_FILE_SIZE'), req, res, jest.fn());

    expect(res.json).toHaveBeenCalledWith(expect.objectContaining({
      error: 'File too large. Maximum size is 5MB per image.',
      code: 'FILE_TOO_LARGE',
      correlationId: req.correlationId,
    }));
  });
});
