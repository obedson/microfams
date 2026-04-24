import { logger } from './logger.js';

// Simple in-memory cache implementation as fallback when Redis is not available
class MemoryCache {
  private cache = new Map<string, { data: any; expires: number }>();
  private cleanupInterval: NodeJS.Timeout;

  constructor() {
    // Clean up expired entries every 5 minutes
    this.cleanupInterval = setInterval(() => {
      this.cleanup();
    }, 5 * 60 * 1000);
  }

  async get(key: string): Promise<any> {
    const entry = this.cache.get(key);
    if (!entry) return null;
    
    if (Date.now() > entry.expires) {
      this.cache.delete(key);
      return null;
    }
    
    return entry.data;
  }

  async set(key: string, value: any, ttlSeconds: number = 3600): Promise<void> {
    const expires = Date.now() + (ttlSeconds * 1000);
    this.cache.set(key, { data: value, expires });
  }

  async del(key: string): Promise<void> {
    this.cache.delete(key);
  }

  async exists(key: string): Promise<boolean> {
    const entry = this.cache.get(key);
    if (!entry) return false;
    
    if (Date.now() > entry.expires) {
      this.cache.delete(key);
      return false;
    }
    
    return true;
  }

  async keys(pattern: string): Promise<string[]> {
    const regex = new RegExp(pattern.replace(/\*/g, '.*'));
    const matchingKeys: string[] = [];
    
    for (const [key, entry] of this.cache.entries()) {
      if (Date.now() > entry.expires) {
        this.cache.delete(key);
        continue;
      }
      
      if (regex.test(key)) {
        matchingKeys.push(key);
      }
    }
    
    return matchingKeys;
  }

  private cleanup(): void {
    const now = Date.now();
    for (const [key, entry] of this.cache.entries()) {
      if (now > entry.expires) {
        this.cache.delete(key);
      }
    }
  }

  destroy(): void {
    if (this.cleanupInterval) {
      clearInterval(this.cleanupInterval);
    }
    this.cache.clear();
  }
}

// Cache interface for consistent API
export interface CacheInterface {
  get(key: string): Promise<any>;
  set(key: string, value: any, ttlSeconds?: number): Promise<void>;
  del(key: string): Promise<void>;
  exists(key: string): Promise<boolean>;
  keys(pattern: string): Promise<string[]>;
}

class CacheService implements CacheInterface {
  private cache: MemoryCache;
  private isRedisAvailable = false;

  constructor() {
    this.cache = new MemoryCache();
    logger.info('Cache service initialized with in-memory fallback');
  }

  async get(key: string): Promise<any> {
    try {
      const result = await this.cache.get(key);
      if (result) {
        logger.debug(`Cache hit for key: ${key}`);
      } else {
        logger.debug(`Cache miss for key: ${key}`);
      }
      return result;
    } catch (error) {
      logger.error('Cache get error:', error);
      return null;
    }
  }

  async set(key: string, value: any, ttlSeconds: number = 3600): Promise<void> {
    try {
      await this.cache.set(key, value, ttlSeconds);
      logger.debug(`Cache set for key: ${key}, TTL: ${ttlSeconds}s`);
    } catch (error) {
      logger.error('Cache set error:', error);
    }
  }

  async del(key: string): Promise<void> {
    try {
      await this.cache.del(key);
      logger.debug(`Cache deleted for key: ${key}`);
    } catch (error) {
      logger.error('Cache delete error:', error);
    }
  }

  async exists(key: string): Promise<boolean> {
    try {
      return await this.cache.exists(key);
    } catch (error) {
      logger.error('Cache exists error:', error);
      return false;
    }
  }

  async keys(pattern: string): Promise<string[]> {
    try {
      return await this.cache.keys(pattern);
    } catch (error) {
      logger.error('Cache keys error:', error);
      return [];
    }
  }

  async invalidatePattern(pattern: string): Promise<void> {
    try {
      const keys = await this.keys(pattern);
      for (const key of keys) {
        await this.del(key);
      }
      logger.debug(`Invalidated ${keys.length} keys matching pattern: ${pattern}`);
    } catch (error) {
      logger.error('Cache pattern invalidation error:', error);
    }
  }

  isAvailable(): boolean {
    return true; // Memory cache is always available
  }

  getType(): string {
    return this.isRedisAvailable ? 'Redis' : 'Memory';
  }
}

// Export singleton instance
export const cacheService = new CacheService();

// Cache key generators for analytics
export const CacheKeys = {
  propertyAnalytics: (propertyId: string, startDate?: string, endDate?: string) => {
    const dateKey = startDate && endDate ? `_${startDate}_${endDate}` : '';
    return `analytics:property:${propertyId}${dateKey}`;
  },
  
  dashboardAnalytics: (ownerId: string, startDate?: string, endDate?: string) => {
    const dateKey = startDate && endDate ? `_${startDate}_${endDate}` : '';
    return `analytics:dashboard:${ownerId}${dateKey}`;
  },
  
  revenueBreakdown: (propertyId?: string, ownerId?: string, startDate?: string, endDate?: string) => {
    const propKey = propertyId ? `_prop_${propertyId}` : '';
    const ownerKey = ownerId ? `_owner_${ownerId}` : '';
    const dateKey = startDate && endDate ? `_${startDate}_${endDate}` : '';
    return `analytics:revenue${propKey}${ownerKey}${dateKey}`;
  },
  
  occupancyRate: (propertyId: string, startDate: string, endDate: string) => {
    return `analytics:occupancy:${propertyId}_${startDate}_${endDate}`;
  },
  
  propertyPerformance: (ownerId?: string, startDate?: string, endDate?: string, limit?: number) => {
    const ownerKey = ownerId ? `_owner_${ownerId}` : '';
    const dateKey = startDate && endDate ? `_${startDate}_${endDate}` : '';
    const limitKey = limit ? `_limit_${limit}` : '';
    return `analytics:performance${ownerKey}${dateKey}${limitKey}`;
  },
  
  monthlyTrends: (ownerId?: string, propertyId?: string, months?: number) => {
    const ownerKey = ownerId ? `_owner_${ownerId}` : '';
    const propKey = propertyId ? `_prop_${propertyId}` : '';
    const monthsKey = months ? `_months_${months}` : '';
    return `analytics:trends${ownerKey}${propKey}${monthsKey}`;
  }
};

// Cache TTL constants (in seconds)
export const CacheTTL = {
  SHORT: 5 * 60,        // 5 minutes
  MEDIUM: 30 * 60,      // 30 minutes  
  LONG: 2 * 60 * 60,    // 2 hours
  DAILY: 24 * 60 * 60   // 24 hours
};