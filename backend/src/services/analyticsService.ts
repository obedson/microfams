import supabase from '../utils/supabase.js';
import { logger } from '../utils/logger.js';
import { cacheService, CacheKeys, CacheTTL } from '../utils/redis.js';

export interface PropertyAnalytics {
  property_id: string;
  property_title: string;
  owner_id: string;
  total_bookings: number;
  confirmed_bookings: number;
  cancelled_bookings: number;
  pending_payment_bookings: number;
  pending_bookings: number;
  completed_bookings: number;
  total_revenue: number;
  pending_revenue: number;
  pending_payment_revenue: number;
  avg_booking_duration: number;
  cancellation_rate: number;
  occupancy_rate: number;
}

export interface RevenueBreakdown {
  confirmed: number;
  pending: number;
  pending_payment: number;
  total: number;
}

export interface BookingTrend {
  date: string;
  bookings_count: number;
  revenue: number;
  occupancy_rate: number;
}

export interface PropertyPerformance {
  property_id: string;
  property_title: string;
  booking_frequency: number;
  total_revenue: number;
  occupancy_rate: number;
  performance_score?: number;
  rank: number;
}

export interface DashboardAnalytics {
  total_properties: number;
  total_bookings: number;
  total_revenue: number;
  pending_revenue: number;
  average_occupancy_rate: number;
  average_cancellation_rate: number;
  revenue_breakdown: RevenueBreakdown;
  monthly_trends: BookingTrend[];
  top_properties: PropertyPerformance[];
}

export class AnalyticsService {
  /**
   * Calculate occupancy rate for a property over a date range
   * Occupancy rate = (Total booked days / Total available days) * 100
   */
  static async calculateOccupancyRate(
    propertyId: string, 
    startDate: string, 
    endDate: string
  ): Promise<number> {
    const cacheKey = CacheKeys.occupancyRate(propertyId, startDate, endDate);
    
    // Try to get from cache first
    const cached = await cacheService.get(cacheKey);
    if (cached !== null) {
      return cached;
    }

    try {
      // Get all confirmed and completed bookings for the property in the date range
      const { data: bookings, error } = await supabase
        .from('bookings')
        .select('start_date, end_date')
        .eq('property_id', propertyId)
        .in('status', ['confirmed', 'completed'])
        .or(`and(start_date.lte.${endDate},end_date.gte.${startDate})`);

      if (error) throw error;

      if (!bookings || bookings.length === 0) {
        await cacheService.set(cacheKey, 0, CacheTTL.MEDIUM);
        return 0;
      }

      // Calculate total booked days with overlap handling
      let totalBookedDays = 0;
      const start = new Date(startDate);
      const end = new Date(endDate);

      // Sort bookings by start date to handle overlaps
      const sortedBookings = bookings.sort((a, b) => 
        new Date(a.start_date).getTime() - new Date(b.start_date).getTime()
      );

      // Merge overlapping bookings to avoid double counting
      const mergedBookings: Array<{start_date: string, end_date: string}> = [];
      
      for (const booking of sortedBookings) {
        const bookingStart = new Date(Math.max(new Date(booking.start_date).getTime(), start.getTime()));
        const bookingEnd = new Date(Math.min(new Date(booking.end_date).getTime(), end.getTime()));
        
        if (bookingStart <= bookingEnd) {
          const lastMerged = mergedBookings[mergedBookings.length - 1];
          
          if (lastMerged && new Date(lastMerged.end_date) >= bookingStart) {
            // Overlapping booking - extend the end date
            lastMerged.end_date = new Date(Math.max(
              new Date(lastMerged.end_date).getTime(),
              bookingEnd.getTime()
            )).toISOString().split('T')[0];
          } else {
            // Non-overlapping booking - add new entry
            mergedBookings.push({
              start_date: bookingStart.toISOString().split('T')[0],
              end_date: bookingEnd.toISOString().split('T')[0]
            });
          }
        }
      }

      // Calculate total days from merged bookings
      for (const booking of mergedBookings) {
        const bookingStart = new Date(booking.start_date);
        const bookingEnd = new Date(booking.end_date);
        const days = Math.ceil((bookingEnd.getTime() - bookingStart.getTime()) / (1000 * 60 * 60 * 24)) + 1;
        totalBookedDays += days;
      }

      // Calculate total available days
      const totalAvailableDays = Math.ceil((end.getTime() - start.getTime()) / (1000 * 60 * 60 * 24)) + 1;

      // Calculate occupancy rate
      const occupancyRate = Math.min((totalBookedDays / totalAvailableDays) * 100, 100);
      
      // Cache the result
      await cacheService.set(cacheKey, occupancyRate, CacheTTL.MEDIUM);
      
      return occupancyRate;
    } catch (error) {
      logger.error('Error calculating occupancy rate:', error);
      return 0;
    }
  }

  /**
   * Get revenue breakdown by booking status with enhanced categorization
   */
  static async getRevenueBreakdown(
    propertyId?: string, 
    ownerId?: string,
    startDate?: string,
    endDate?: string
  ): Promise<RevenueBreakdown> {
    const cacheKey = CacheKeys.revenueBreakdown(propertyId, ownerId, startDate, endDate);
    
    // Try to get from cache first
    const cached = await cacheService.get(cacheKey);
    if (cached !== null) {
      return cached;
    }

    try {
      let bookings: any[] | null = null;
      let error: any = null;

      if (ownerId) {
        // Handle owner-specific query with join
        let ownerQuery = supabase
          .from('bookings')
          .select('status, payment_status, total_amount, properties!inner(owner_id)')
          .eq('properties.owner_id', ownerId);

        if (propertyId) {
          ownerQuery = ownerQuery.eq('property_id', propertyId);
        }

        if (startDate) {
          ownerQuery = ownerQuery.gte('start_date', startDate);
        }

        if (endDate) {
          ownerQuery = ownerQuery.lte('end_date', endDate);
        }

        const result = await ownerQuery;
        bookings = result.data;
        error = result.error;
      } else {
        // Handle property-specific or general query
        let query = supabase
          .from('bookings')
          .select('status, payment_status, total_amount');

        if (propertyId) {
          query = query.eq('property_id', propertyId);
        }

        if (startDate) {
          query = query.gte('start_date', startDate);
        }

        if (endDate) {
          query = query.lte('end_date', endDate);
        }

        const result = await query;
        bookings = result.data;
        error = result.error;
      }

      if (error) throw error;

      const breakdown: RevenueBreakdown = {
        confirmed: 0,
        pending: 0,
        pending_payment: 0,
        total: 0
      };

      if (bookings) {
        for (const booking of bookings) {
          const amount = parseFloat(booking.total_amount.toString());
          
          // Enhanced revenue categorization logic
          if (booking.payment_status === 'paid') {
            if (booking.status === 'confirmed' || booking.status === 'completed') {
              breakdown.confirmed += amount;
            } else if (booking.status === 'pending') {
              breakdown.pending += amount;
            }
          } else if (booking.status === 'pending_payment') {
            breakdown.pending_payment += amount;
          }
        }
      }

      breakdown.total = breakdown.confirmed + breakdown.pending + breakdown.pending_payment;
      
      // Cache the result
      await cacheService.set(cacheKey, breakdown, CacheTTL.MEDIUM);
      
      return breakdown;
    } catch (error) {
      logger.error('Error calculating revenue breakdown:', error);
      const fallback = { confirmed: 0, pending: 0, pending_payment: 0, total: 0 };
      await cacheService.set(cacheKey, fallback, CacheTTL.SHORT);
      return fallback;
    }
  }

  /**
   * Calculate average booking duration using simple arithmetic mean
   */
  static async calculateAverageBookingDuration(
    propertyId: string,
    startDate?: string,
    endDate?: string
  ): Promise<number> {
    try {
      let query = supabase
        .from('bookings')
        .select('start_date, end_date')
        .eq('property_id', propertyId)
        .in('status', ['confirmed', 'completed']);

      if (startDate) {
        query = query.gte('start_date', startDate);
      }

      if (endDate) {
        query = query.lte('end_date', endDate);
      }

      const { data: bookings, error } = await query;

      if (error) throw error;

      if (!bookings || bookings.length === 0) {
        return 0;
      }

      let totalDuration = 0;

      for (const booking of bookings) {
        const start = new Date(booking.start_date);
        const end = new Date(booking.end_date);
        const duration = Math.ceil((end.getTime() - start.getTime()) / (1000 * 60 * 60 * 24)) + 1;
        totalDuration += duration;
      }

      return totalDuration / bookings.length;
    } catch (error) {
      logger.error('Error calculating average booking duration:', error);
      return 0;
    }
  }

  /**
   * Calculate cancellation rate with trend analysis
   */
  static async calculateCancellationRate(
    propertyId: string,
    startDate?: string,
    endDate?: string
  ): Promise<number> {
    try {
      let query = supabase
        .from('bookings')
        .select('status, created_at')
        .eq('property_id', propertyId);

      if (startDate) {
        query = query.gte('created_at', startDate);
      }

      if (endDate) {
        query = query.lte('created_at', endDate);
      }

      const { data: bookings, error } = await query;

      if (error) throw error;

      if (!bookings || bookings.length === 0) {
        return 0;
      }

      const cancelledBookings = bookings.filter(b => b.status === 'cancelled').length;
      return (cancelledBookings / bookings.length) * 100;
    } catch (error) {
      logger.error('Error calculating cancellation rate:', error);
      return 0;
    }
  }

  /**
   * Enhanced property performance ranking with multiple metrics
   */
  static async getPropertyPerformanceRanking(
    ownerId?: string,
    startDate?: string,
    endDate?: string,
    limit: number = 10
  ): Promise<PropertyPerformance[]> {
    const cacheKey = CacheKeys.propertyPerformance(ownerId, startDate, endDate, limit);
    
    // Try to get from cache first
    const cached = await cacheService.get(cacheKey);
    if (cached !== null) {
      return cached;
    }

    try {
      let query = supabase
        .from('booking_analytics')
        .select('*');

      if (ownerId) {
        query = query.eq('owner_id', ownerId);
      }

      const { data: analytics, error } = await query;

      if (error) throw error;

      if (!analytics || analytics.length === 0) {
        await cacheService.set(cacheKey, [], CacheTTL.MEDIUM);
        return [];
      }

      // Enhanced ranking algorithm with multiple factors
      const ranked = analytics
        .map((item) => {
          const totalBookings = item.total_bookings || 0;
          const totalRevenue = parseFloat(item.total_revenue?.toString() || '0');
          const occupancyRate = parseFloat(item.occupancy_rate?.toString() || '0');
          const cancellationRate = parseFloat(item.cancellation_rate?.toString() || '0');
          
          // Calculate composite performance score
          const revenueScore = Math.log(totalRevenue + 1) * 0.4; // Log scale for revenue
          const bookingScore = Math.log(totalBookings + 1) * 0.3; // Log scale for bookings
          const occupancyScore = occupancyRate * 0.2; // Direct occupancy rate
          const cancellationPenalty = (100 - cancellationRate) * 0.1; // Penalty for high cancellation
          
          const performanceScore = revenueScore + bookingScore + occupancyScore + cancellationPenalty;

          return {
            property_id: item.property_id,
            property_title: item.property_title,
            booking_frequency: totalBookings,
            total_revenue: totalRevenue,
            occupancy_rate: occupancyRate,
            performance_score: performanceScore,
            rank: 0 // Will be set below
          };
        })
        .sort((a, b) => b.performance_score - a.performance_score)
        .slice(0, limit)
        .map((item, index) => ({
          ...item,
          rank: index + 1
        }));

      // Cache the result
      await cacheService.set(cacheKey, ranked, CacheTTL.LONG);
      
      return ranked;
    } catch (error) {
      logger.error('Error getting property performance ranking:', error);
      const fallback: PropertyPerformance[] = [];
      await cacheService.set(cacheKey, fallback, CacheTTL.SHORT);
      return fallback;
    }
  }

  /**
   * Get monthly revenue trends with seasonal analysis
   */
  static async getMonthlyTrends(
    ownerId?: string,
    propertyId?: string,
    months: number = 12
  ): Promise<BookingTrend[]> {
    const cacheKey = CacheKeys.monthlyTrends(ownerId, propertyId, months);
    
    // Try to get from cache first
    const cached = await cacheService.get(cacheKey);
    if (cached !== null) {
      return cached;
    }

    try {
      const endDate = new Date();
      const startDate = new Date();
      startDate.setMonth(startDate.getMonth() - months);

      let bookings: any[] | null = null;
      let error: any = null;

      if (ownerId) {
        // Handle owner-specific query with join
        let ownerQuery = supabase
          .from('bookings')
          .select('created_at, total_amount, status, payment_status, property_id, start_date, end_date, properties!inner(owner_id)')
          .gte('created_at', startDate.toISOString())
          .lte('created_at', endDate.toISOString())
          .eq('properties.owner_id', ownerId);

        if (propertyId) {
          ownerQuery = ownerQuery.eq('property_id', propertyId);
        }

        const result = await ownerQuery;
        bookings = result.data;
        error = result.error;
      } else {
        // Handle property-specific or general query
        let query = supabase
          .from('bookings')
          .select('created_at, total_amount, status, payment_status, property_id, start_date, end_date')
          .gte('created_at', startDate.toISOString())
          .lte('created_at', endDate.toISOString());

        if (propertyId) {
          query = query.eq('property_id', propertyId);
        }

        const result = await query;
        bookings = result.data;
        error = result.error;
      }

      if (error) throw error;

      // Initialize monthly data structure
      const monthlyData: { [key: string]: BookingTrend } = {};

      for (let i = 0; i < months; i++) {
        const date = new Date();
        date.setMonth(date.getMonth() - i);
        const monthKey = date.toISOString().substring(0, 7); // YYYY-MM format
        
        monthlyData[monthKey] = {
          date: monthKey,
          bookings_count: 0,
          revenue: 0,
          occupancy_rate: 0
        };
      }

      if (bookings) {
        // Process bookings and calculate metrics
        for (const booking of bookings) {
          const monthKey = booking.created_at.substring(0, 7);
          
          if (monthlyData[monthKey]) {
            monthlyData[monthKey].bookings_count++;
            
            if (booking.payment_status === 'paid' && booking.status !== 'cancelled') {
              monthlyData[monthKey].revenue += parseFloat(booking.total_amount.toString());
            }
          }
        }

        // Calculate occupancy rates for each month if property-specific
        if (propertyId) {
          for (const monthKey of Object.keys(monthlyData)) {
            const monthStart = new Date(monthKey + '-01');
            const monthEnd = new Date(monthStart.getFullYear(), monthStart.getMonth() + 1, 0);
            
            const occupancyRate = await this.calculateOccupancyRate(
              propertyId,
              monthStart.toISOString().split('T')[0],
              monthEnd.toISOString().split('T')[0]
            );
            
            monthlyData[monthKey].occupancy_rate = occupancyRate;
          }
        }
      }

      // Convert to array and sort by date
      const trends = Object.values(monthlyData)
        .sort((a, b) => a.date.localeCompare(b.date));

      // Cache the result
      await cacheService.set(cacheKey, trends, CacheTTL.LONG);
      
      return trends;
    } catch (error) {
      logger.error('Error getting monthly trends:', error);
      const fallback: BookingTrend[] = [];
      await cacheService.set(cacheKey, fallback, CacheTTL.SHORT);
      return fallback;
    }
  }

  /**
   * Get comprehensive property analytics with caching
   */
  static async getPropertyAnalytics(
    propertyId: string,
    startDate?: string,
    endDate?: string
  ): Promise<PropertyAnalytics | null> {
    const cacheKey = CacheKeys.propertyAnalytics(propertyId, startDate, endDate);
    
    // Try to get from cache first
    const cached = await cacheService.get(cacheKey);
    if (cached !== null) {
      return cached;
    }

    try {
      // Get basic analytics from the view
      const { data: analytics, error } = await supabase
        .from('booking_analytics')
        .select('*')
        .eq('property_id', propertyId)
        .single();

      if (error) {
        logger.error('Error fetching property analytics:', error);
        return null;
      }

      if (!analytics) {
        return null;
      }

      // Calculate time-based metrics if date range is provided
      let occupancyRate = parseFloat(analytics.occupancy_rate?.toString() || '0');
      let avgDuration = parseFloat(analytics.avg_booking_duration?.toString() || '0');
      let cancellationRate = parseFloat(analytics.cancellation_rate?.toString() || '0');

      if (startDate && endDate) {
        occupancyRate = await this.calculateOccupancyRate(propertyId, startDate, endDate);
        avgDuration = await this.calculateAverageBookingDuration(propertyId, startDate, endDate);
        cancellationRate = await this.calculateCancellationRate(propertyId, startDate, endDate);
      }

      const result: PropertyAnalytics = {
        property_id: analytics.property_id,
        property_title: analytics.property_title,
        owner_id: analytics.owner_id,
        total_bookings: analytics.total_bookings || 0,
        confirmed_bookings: analytics.confirmed_bookings || 0,
        cancelled_bookings: analytics.cancelled_bookings || 0,
        pending_payment_bookings: analytics.pending_payment_bookings || 0,
        pending_bookings: analytics.pending_bookings || 0,
        completed_bookings: analytics.completed_bookings || 0,
        total_revenue: parseFloat(analytics.total_revenue?.toString() || '0'),
        pending_revenue: parseFloat(analytics.pending_revenue?.toString() || '0'),
        pending_payment_revenue: parseFloat(analytics.pending_payment_revenue?.toString() || '0'),
        avg_booking_duration: avgDuration,
        cancellation_rate: cancellationRate,
        occupancy_rate: occupancyRate
      };

      // Cache the result
      await cacheService.set(cacheKey, result, CacheTTL.MEDIUM);
      
      return result;
    } catch (error) {
      logger.error('Error getting property analytics:', error);
      return null;
    }
  }

  /**
   * Get dashboard analytics for an owner with caching
   */
  static async getDashboardAnalytics(
    ownerId: string,
    startDate?: string,
    endDate?: string
  ): Promise<DashboardAnalytics> {
    const cacheKey = CacheKeys.dashboardAnalytics(ownerId, startDate, endDate);
    
    // Try to get from cache first
    const cached = await cacheService.get(cacheKey);
    if (cached !== null) {
      return cached;
    }

    try {
      // Get all properties for the owner
      const { data: properties, error: propertiesError } = await supabase
        .from('properties')
        .select('id')
        .eq('owner_id', ownerId)
        .eq('is_active', true);

      if (propertiesError) throw propertiesError;

      const propertyIds = properties?.map(p => p.id) || [];

      // Get analytics from the view
      const { data: analytics, error: analyticsError } = await supabase
        .from('booking_analytics')
        .select('*')
        .eq('owner_id', ownerId);

      if (analyticsError) throw analyticsError;

      // Calculate aggregated metrics
      let totalBookings = 0;
      let totalRevenue = 0;
      let pendingRevenue = 0;
      let totalOccupancyRate = 0;
      let totalCancellationRate = 0;
      let propertiesWithData = 0;

      if (analytics) {
        for (const item of analytics) {
          totalBookings += item.total_bookings || 0;
          totalRevenue += parseFloat(item.total_revenue?.toString() || '0');
          pendingRevenue += parseFloat(item.pending_revenue?.toString() || '0');
          
          if (item.total_bookings > 0) {
            totalOccupancyRate += parseFloat(item.occupancy_rate?.toString() || '0');
            totalCancellationRate += parseFloat(item.cancellation_rate?.toString() || '0');
            propertiesWithData++;
          }
        }
      }

      const averageOccupancyRate = propertiesWithData > 0 ? totalOccupancyRate / propertiesWithData : 0;
      const averageCancellationRate = propertiesWithData > 0 ? totalCancellationRate / propertiesWithData : 0;

      // Get revenue breakdown
      const revenueBreakdown = await this.getRevenueBreakdown(undefined, ownerId, startDate, endDate);

      // Get monthly trends
      const monthlyTrends = await this.getMonthlyTrends(ownerId, undefined, 12);

      // Get top properties
      const topProperties = await this.getPropertyPerformanceRanking(ownerId, startDate, endDate, 5);

      const result: DashboardAnalytics = {
        total_properties: propertyIds.length,
        total_bookings: totalBookings,
        total_revenue: totalRevenue,
        pending_revenue: pendingRevenue,
        average_occupancy_rate: averageOccupancyRate,
        average_cancellation_rate: averageCancellationRate,
        revenue_breakdown: revenueBreakdown,
        monthly_trends: monthlyTrends,
        top_properties: topProperties
      };

      // Cache the result
      await cacheService.set(cacheKey, result, CacheTTL.MEDIUM);
      
      return result;
    } catch (error) {
      logger.error('Error getting dashboard analytics:', error);
      const fallback: DashboardAnalytics = {
        total_properties: 0,
        total_bookings: 0,
        total_revenue: 0,
        pending_revenue: 0,
        average_occupancy_rate: 0,
        average_cancellation_rate: 0,
        revenue_breakdown: { confirmed: 0, pending: 0, pending_payment: 0, total: 0 },
        monthly_trends: [],
        top_properties: []
      };
      await cacheService.set(cacheKey, fallback, CacheTTL.SHORT);
      return fallback;
    }
  }

  /**
   * Get dashboard analytics for a farmer
   */
  static async getFarmerDashboardAnalytics(farmerId: string): Promise<any> {
    try {
      const { data: bookings, error } = await supabase
        .from('bookings')
        .select('status, payment_status, total_amount')
        .eq('farmer_id', farmerId);

      if (error) throw error;

      const stats = {
        total_bookings: bookings?.length || 0,
        confirmed_bookings: bookings?.filter(b => b.status === 'confirmed').length || 0,
        pending_payment: bookings?.filter(b => b.status === 'pending_payment').length || 0,
        total_spent: bookings?.filter(b => b.payment_status === 'paid').reduce((sum, b) => sum + parseFloat(b.total_amount), 0) || 0
      };

      return stats;
    } catch (error) {
      logger.error('Error getting farmer dashboard analytics:', error);
      return { total_bookings: 0, confirmed_bookings: 0, pending_payment: 0, total_spent: 0 };
    }
  }

  /**
   * Invalidate analytics cache for a property
   */
  static async invalidatePropertyCache(propertyId: string): Promise<void> {
    try {
      await cacheService.invalidatePattern(`analytics:*${propertyId}*`);
      logger.debug(`Invalidated analytics cache for property: ${propertyId}`);
    } catch (error) {
      logger.error('Error invalidating property cache:', error);
    }
  }

  /**
   * Invalidate analytics cache for an owner
   */
  static async invalidateOwnerCache(ownerId: string): Promise<void> {
    try {
      await cacheService.invalidatePattern(`analytics:*owner_${ownerId}*`);
      logger.debug(`Invalidated analytics cache for owner: ${ownerId}`);
    } catch (error) {
      logger.error('Error invalidating owner cache:', error);
    }
  }

  /**
   * Warm up cache for frequently accessed analytics
   */
  static async warmUpCache(propertyIds: string[], ownerIds: string[]): Promise<void> {
    try {
      const promises: Promise<any>[] = [];

      // Warm up property analytics
      for (const propertyId of propertyIds) {
        promises.push(this.getPropertyAnalytics(propertyId));
      }

      // Warm up owner dashboard analytics
      for (const ownerId of ownerIds) {
        promises.push(this.getDashboardAnalytics(ownerId));
      }

      await Promise.allSettled(promises);
      logger.info(`Warmed up analytics cache for ${propertyIds.length} properties and ${ownerIds.length} owners`);
    } catch (error) {
      logger.error('Error warming up analytics cache:', error);
    }
  }
}
