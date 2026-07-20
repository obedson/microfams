import { Response } from 'express';
import { TenantRequest } from '../middleware/tenant.js';
import { ReportingService } from '../services/reportingService.js';
import { validateReportExport } from '../services/reportingPolicy.js';

export const getBookingReport = async (req: TenantRequest, res: Response) => {
  const { start_date, end_date } = req.query;
  if (typeof start_date !== 'string' || typeof end_date !== 'string') {
    return res.status(400).json({ error: 'Start and end dates are required' });
  }
  if (Number.isNaN(Date.parse(start_date)) || Number.isNaN(Date.parse(end_date)) || Date.parse(start_date) > Date.parse(end_date)) {
    return res.status(400).json({ error: 'Invalid reporting date range' });
  }
  try {
    return res.json(await ReportingService.getBookingReport(req.tenant!.id, start_date, end_date));
  } catch (error) {
    return res.status(500).json({ error: error instanceof Error ? error.message : 'Report failed' });
  }
};

export const getEngagementReport = async (req: TenantRequest, res: Response) => {
  const days = Math.min(Math.max(Number(req.query.days) || 30, 1), 365);
  try {
    return res.json(await ReportingService.getEngagementReport(req.tenant!.id, days));
  } catch (error) {
    return res.status(500).json({ error: error instanceof Error ? error.message : 'Report failed' });
  }
};

export const getRetentionBI = async (req: TenantRequest, res: Response) => {
  try {
    return res.json(await ReportingService.getRetentionBI(req.tenant!.id));
  } catch (error) {
    return res.status(500).json({ error: error instanceof Error ? error.message : 'Report failed' });
  }
};

export const exportData = async (req: TenantRequest, res: Response) => {
  try {
    const selection = validateReportExport(req.body.table, req.body.fields);
    const csv = await ReportingService.exportToCSV(req.tenant!.id, selection.table, selection.fields);
    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', `attachment; filename=${selection.table}-export.csv`);
    return res.send(csv);
  } catch (error) {
    return res.status(400).json({ error: error instanceof Error ? error.message : 'Export failed' });
  }
};
