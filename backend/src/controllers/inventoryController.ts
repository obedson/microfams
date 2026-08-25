import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import { inventoryService } from '../domains/inventory/inventoryService.js';

export const inventoryController = {
  async list(req: TenantRequest, res: Response) { return res.json({ success: true, data: await inventoryService.list(req.tenant!.id) }); },
  async create(req: TenantRequest, res: Response) { try { return res.status(201).json({ success: true, data: await inventoryService.create(req.tenant!.id, req.body) }); } catch (e) { return res.status(400).json({ success: false, error: e instanceof Error ? e.message : 'INVENTORY_CREATE_FAILED' }); } },
  async move(req: TenantRequest, res: Response) { try { return res.json({ success: true, data: await inventoryService.move(req.tenant!.id, req.params.id, req.body) }); } catch (e) { return res.status(400).json({ success: false, error: e instanceof Error ? e.message : 'INVENTORY_MOVE_FAILED' }); } },
};
