import { randomUUID } from 'node:crypto';
import { Request, Response, NextFunction } from 'express';
import { withCorrelationContext } from '../utils/correlationContext.js';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

declare module 'express-serve-static-core' {
  interface Request { correlationId?: string; }
}

export const requestContext = (req: Request, res: Response, next: NextFunction) => {
  const supplied = req.header('x-correlation-id');
  const correlationId = supplied && UUID.test(supplied) ? supplied : randomUUID();
  req.correlationId = correlationId;
  res.setHeader('x-correlation-id', correlationId);
  return withCorrelationContext(correlationId, next);
};