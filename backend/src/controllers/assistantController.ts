import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import { assistantService } from '../domains/intelligence/assistantService.js';
export const assistantController = { async answer(req: TenantRequest, res: Response) { try { return res.json({ success: true, data: await assistantService.answer(req.body) }); } catch (e) { return res.status(400).json({ success: false, error: e instanceof Error ? e.message : 'ASSISTANT_REQUEST_FAILED' }); } } };
