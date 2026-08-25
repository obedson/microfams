import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import { weatherService } from '../domains/intelligence/weatherService.js';
export const weatherController = { async forecast(req: TenantRequest, res: Response) { try { const latitude=Number(req.query.latitude), longitude=Number(req.query.longitude); const at=typeof req.query.at==='string'?req.query.at:undefined; return res.json({ success:true, data: await weatherService.forecast({latitude,longitude,at}) }); } catch(error) { return res.status(400).json({success:false,error:error instanceof Error?error.message:'WEATHER_REQUEST_FAILED'}); } } };
