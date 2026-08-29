import { Response } from 'express';
import { AuthRequest } from '../middleware/auth.js';
import { requestMetricSnapshot } from '../utils/requestMetrics.js';
export const metricsController = { snapshot(_req: AuthRequest, res: Response) { return res.json({ success: true, data: requestMetricSnapshot() }); } };
