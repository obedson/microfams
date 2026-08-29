import { NextFunction, Request, Response } from 'express';
import { recordRequestMetric } from '../utils/requestMetrics.js';
export const requestMetrics = (req: Request, res: Response, next: NextFunction): void => { const started = process.hrtime.bigint(); res.on('finish', () => { const durationMs = Number(process.hrtime.bigint() - started) / 1_000_000; recordRequestMetric(req.method, req.path, res.statusCode, Math.round(durationMs * 100) / 100); }); next(); };
