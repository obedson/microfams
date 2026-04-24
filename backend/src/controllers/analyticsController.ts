import { Request, Response } from 'express';
import { AnalyticsService } from '../services/analyticsService.js';
import { logger } from '../utils/logger.js';
import supabase from '../utils/supabase.js';

interface AuthenticatedRequest extends Request {
  user: {
    id: string;
    role: string;
  };
}

/**
 * Get analytics for a specific property
 * GET /api/analytics/property/:id
 */
export const getPropertyAnalytics = async (req: Request, res: Response) => {
  try {
    const { id: propertyId } = req.params;
    const { start_date, end_date } = req.query;
    const userId = (req as AuthenticatedRequest).user.id;
    const userRole = (req as AuthenticatedRequest).user.role;

    // Verify property ownership (unless admin)
    if (userRole !== 'admin') {
      const { data: property, error } = await supabase
        .from('properties')
        .select('owner_id')
        .eq('id', propertyId)
        .single();

      if (error || !property) {
        return res.status(404).json({
          success: false,
          message: 'Property not found'
        });
      }

      if (property.owner_id !== userId) {
        return res.status(403).json({
          success: false,
          message: 'Access denied. You can only view analytics for your own properties.'
        });
      }
    }

    const analytics = await AnalyticsService.getPropertyAnalytics(
      propertyId,
      start_date as string,
      end_date as string
    );

    if (!analytics) {
      return res.status(404).json({
        success: false,
        message: 'Analytics not found for this property'
      });
    }

    res.json({
      success: true,
      data: analytics
    });
  } catch (error) {
    logger.error('Error fetching property analytics:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
};

/**
 * Get dashboard analytics for the authenticated user
 * GET /api/analytics/dashboard
 */
export const getDashboardAnalytics = async (req: Request, res: Response) => {
  try {
    const userId = (req as AuthenticatedRequest).user.id;
    const userRole = (req as AuthenticatedRequest).user.role;
    const { start_date, end_date } = req.query;

    if (userRole === 'farmer') {
      const analytics = await AnalyticsService.getFarmerDashboardAnalytics(userId);
      return res.json({
        success: true,
        data: analytics
      });
    }

    // For property owners, get their dashboard analytics
    const analytics = await AnalyticsService.getDashboardAnalytics(
      userId,
      start_date as string,
      end_date as string
    );

    res.json({
      success: true,
      data: analytics
    });
  } catch (error) {
    logger.error('Error fetching dashboard analytics:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
};

/**
 * Get revenue breakdown
 * GET /api/analytics/revenue-breakdown
 */
export const getRevenueBreakdown = async (req: Request, res: Response) => {
  try {
    const userId = (req as AuthenticatedRequest).user.id;
    const userRole = (req as AuthenticatedRequest).user.role;
    const { property_id, start_date, end_date } = req.query;

    if (userRole === 'farmer') {
      return res.status(403).json({
        success: false,
        message: 'Access denied'
      });
    }

    // Verify property ownership if property_id is provided
    if (property_id && userRole !== 'admin') {
      const { data: property, error } = await supabase
        .from('properties')
        .select('owner_id')
        .eq('id', property_id as string)
        .single();

      if (error || !property || property.owner_id !== userId) {
        return res.status(403).json({
          success: false,
          message: 'Access denied'
        });
      }
    }

    const breakdown = await AnalyticsService.getRevenueBreakdown(
      property_id as string,
      userRole === 'admin' ? undefined : userId,
      start_date as string,
      end_date as string
    );

    res.json({
      success: true,
      data: breakdown
    });
  } catch (error) {
    logger.error('Error fetching revenue breakdown:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
};

/**
 * Get property performance ranking
 * GET /api/analytics/property-performance
 */
export const getPropertyPerformance = async (req: Request, res: Response) => {
  try {
    const userId = (req as AuthenticatedRequest).user.id;
    const userRole = (req as AuthenticatedRequest).user.role;
    const { start_date, end_date, limit = '10' } = req.query;

    if (userRole === 'farmer') {
      return res.status(403).json({
        success: false,
        message: 'Access denied'
      });
    }

    const performance = await AnalyticsService.getPropertyPerformanceRanking(
      userRole === 'admin' ? undefined : userId,
      start_date as string,
      end_date as string,
      parseInt(limit as string)
    );

    res.json({
      success: true,
      data: performance
    });
  } catch (error) {
    logger.error('Error fetching property performance:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
};

/**
 * Get monthly trends
 * GET /api/analytics/monthly-trends
 */
export const getMonthlyTrends = async (req: Request, res: Response) => {
  try {
    const userId = (req as AuthenticatedRequest).user.id;
    const userRole = (req as AuthenticatedRequest).user.role;
    const { property_id, months = '12' } = req.query;

    if (userRole === 'farmer') {
      return res.status(403).json({
        success: false,
        message: 'Access denied'
      });
    }

    // Verify property ownership if property_id is provided
    if (property_id && userRole !== 'admin') {
      const { data: property, error } = await supabase
        .from('properties')
        .select('owner_id')
        .eq('id', property_id as string)
        .single();

      if (error || !property || property.owner_id !== userId) {
        return res.status(403).json({
          success: false,
          message: 'Access denied'
        });
      }
    }

    const trends = await AnalyticsService.getMonthlyTrends(
      userRole === 'admin' ? undefined : userId,
      property_id as string,
      parseInt(months as string)
    );

    res.json({
      success: true,
      data: trends
    });
  } catch (error) {
    logger.error('Error fetching monthly trends:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
};

/**
 * Get occupancy rate for a property
 * GET /api/analytics/occupancy-rate/:propertyId
 */
export const getOccupancyRate = async (req: Request, res: Response) => {
  try {
    const { propertyId } = req.params;
    const { start_date, end_date } = req.query;
    const userId = (req as AuthenticatedRequest).user.id;
    const userRole = (req as AuthenticatedRequest).user.role;

    if (!start_date || !end_date) {
      return res.status(400).json({
        success: false,
        message: 'start_date and end_date are required'
      });
    }

    // Verify property ownership (unless admin)
    if (userRole !== 'admin') {
      const { data: property, error } = await supabase
        .from('properties')
        .select('owner_id')
        .eq('id', propertyId)
        .single();

      if (error || !property) {
        return res.status(404).json({
          success: false,
          message: 'Property not found'
        });
      }

      if (property.owner_id !== userId) {
        return res.status(403).json({
          success: false,
          message: 'Access denied'
        });
      }
    }

    const occupancyRate = await AnalyticsService.calculateOccupancyRate(
      propertyId,
      start_date as string,
      end_date as string
    );

    res.json({
      success: true,
      data: {
        property_id: propertyId,
        start_date,
        end_date,
        occupancy_rate: occupancyRate
      }
    });
  } catch (error) {
    logger.error('Error calculating occupancy rate:', error);
    res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
};