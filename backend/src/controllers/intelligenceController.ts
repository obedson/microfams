import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import { mappingService } from '../domains/intelligence/mappingService.js';
import { satelliteService } from '../domains/intelligence/satelliteService.js';

const coordinate = (req: TenantRequest) => ({ latitude: Number(req.query.latitude), longitude: Number(req.query.longitude) });
const at = (req: TenantRequest) => typeof req.query.at === 'string' ? req.query.at : undefined;

export const intelligenceController = {
  async mapping(req: TenantRequest, res: Response) {
    try { return res.json({ success: true, data: await mappingService.resolve(coordinate(req), at(req)) }); }
    catch (error) { return res.status(400).json({ success: false, error: error instanceof Error ? error.message : 'MAPPING_REQUEST_FAILED' }); }
  },
  async satellite(req: TenantRequest, res: Response) {
    try { return res.json({ success: true, data: await satelliteService.inspect({ location: coordinate(req), capturedAt: at(req) }) }); }
    catch (error) { return res.status(400).json({ success: false, error: error instanceof Error ? error.message : 'SATELLITE_REQUEST_FAILED' }); }
  },
};
