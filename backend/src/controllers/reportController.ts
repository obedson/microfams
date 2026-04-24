import { Response } from 'express';
import { AuthRequest } from '../middleware/auth.js';
import { ReportingService } from '../services/reportingService.js';

export const getBookingReport = async (req: AuthRequest, res: Response) => {
  try {
    const { start_date, end_date } = req.query;
    if (!start_date || !end_date) {
      return res.status(400).json({ error: 'Start and end dates are required' });
    }

    const report = await ReportingService.getBookingReport(
      start_date as string,
      end_date as string
    );
    res.json(report);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const getEngagementReport = async (req: AuthRequest, res: Response) => {
  try {
    const { days } = req.query;
    const report = await ReportingService.getEngagementReport(
      days ? parseInt(days as string) : 30
    );
    res.json(report);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const getRetentionBI = async (req: AuthRequest, res: Response) => {
  try {
    const report = await ReportingService.getRetentionBI();
    res.json(report);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};

export const exportData = async (req: AuthRequest, res: Response) => {
  try {
    const { table, fields } = req.body;
    if (!table || !fields || !Array.isArray(fields)) {
      return res.status(400).json({ error: 'Table and fields array are required' });
    }

    const csv = await ReportingService.exportToCSV(table, fields);
    
    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', `attachment; filename=${table}-export.csv`);
    res.send(csv);
  } catch (error: any) {
    res.status(500).json({ error: error.message });
  }
};
