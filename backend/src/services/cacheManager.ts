import { logger } from '../utils/logger.js';
import { cacheService } from '../utils/redis.js';
import { AnalyticsService } from './analyticsService.js';
import supabase from '../utils/supabase.js';

/**
 * Cache Manager Service
 * Handles cache invalidation strategies and cache warming
 */
export class CacheManager {
  /**
   * Invalidate analytics cache when a booking is created, updated, or deleted
   */
  static async invalidateBookingRelatedCache(
    propertyId: string,
    ownerId?: string
  ): Promise<void> {
    try {
      // Get owner ID if not provided
      if (!ownerId) {
        const { data: property } = await supabase
          .from('properties')
          .select('owner_id')
          .eq('id', propertyId)
          .single();
        
        ownerId = property?.owner_id;
      }

      // Invalidate property-specific cache
      await AnalyticsService.invalidatePropertyCache(propertyId);

      // Invalidate owner-specific cache
      if (ownerId) {
        await AnalyticsService.invalidateOwnerCache(ownerId);
      }

      // Invalidate general analytics cache patterns
      await cacheService.invalidatePattern('analytics:performance*');
      await cacheService.invalidatePattern('analytics:trends*');

      logger.debug(`Invalidated analytics cache for property ${propertyId} and owner ${ownerId}`);
    } catch (error) {
      logger.error('Error invalidating booking-related cache:', error);
    }
  }

  /**
   * Invalidate cache when payment status changes
   */
  static async invalidatePaymentRelatedCache(
    propertyId: string,
    ownerId?: string
  ): Promise<void> {
    try {
      // Payment changes affect revenue calculations
      await this.invalidateBookingRelatedCache(propertyId, ownerId);
      
      // Also invalidate revenue-specific cache
      await cacheService.invalidatePattern('analytics:revenue*');
      
      logger.debug(`Invalidated payment-related cache for property ${propertyId}`);
    } catch (error) {
      logger.error('Error invalidating payment-related cache:', error);
    }
  }

  /**
   * Warm up cache for active properties and owners
   */
  static async warmUpAnalyticsCache(): Promise<void> {
    try {
      // Get active properties and their owners
      const { data: properties } = await supabase
        .from('properties')
        .select('id, owner_id')
        .eq('is_active', true)
        .limit(50); // Limit to avoid overwhelming the system

      if (!properties || properties.length === 0) {
        logger.info('No active properties found for cache warming');
        return;
      }

      const propertyIds = properties.map(p => p.id);
      const ownerIds = [...new Set(properties.map(p => p.owner_id))]; // Unique owner IDs

      // Warm up the cache
      await AnalyticsService.warmUpCache(propertyIds, ownerIds);
      
      logger.info(`Cache warming completed for ${propertyIds.length} properties and ${ownerIds.length} owners`);
    } catch (error) {
      logger.error('Error warming up analytics cache:', error);
    }
  }

  /**
   * Clean up expired cache entries
   */
  static async cleanupExpiredCache(): Promise<void> {
    try {
      // The cache service handles its own cleanup for memory cache
      // For Redis, this would involve scanning for expired keys
      logger.debug('Cache cleanup completed');
    } catch (error) {
      logger.error('Error cleaning up expired cache:', error);
    }
  }

  /**
   * Get cache statistics
   */
  static async getCacheStats(): Promise<{
    type: string;
    isAvailable: boolean;
    keyCount: number;
  }> {
    try {
      const keys = await cacheService.keys('analytics:*');
      
      return {
        type: cacheService.getType(),
        isAvailable: cacheService.isAvailable(),
        keyCount: keys.length
      };
    } catch (error) {
      logger.error('Error getting cache stats:', error);
      return {
        type: 'Unknown',
        isAvailable: false,
        keyCount: 0
      };
    }
  }

  /**
   * Clear all analytics cache (use with caution)
   */
  static async clearAllAnalyticsCache(): Promise<void> {
    try {
      await cacheService.invalidatePattern('analytics:*');
      logger.info('Cleared all analytics cache');
    } catch (error) {
      logger.error('Error clearing analytics cache:', error);
    }
  }
}