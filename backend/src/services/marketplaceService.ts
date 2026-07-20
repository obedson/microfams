import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

export class MarketplaceService {
  /**
   * Get recommended products based on upcoming bookings
   */
  static async getRecommendedProducts(userId: string, organizationId: string = userId) {
    try {
      // Get user's upcoming bookings
      const { data: bookings, error: bookingsError } = await supabase
        .from('bookings')
        .select(`
          property_id,
          start_date,
          properties (
            livestock_type,
            city
          )
        `)
        .eq('farmer_id', userId)
        .eq('organization_id', organizationId)
        .gte('end_date', new Date().toISOString())
        .order('start_date', { ascending: true })
        .limit(3);

      if (bookingsError) throw bookingsError;

      if (!bookings || bookings.length === 0) {
        // Fallback to popular products if no upcoming bookings
        const { data: popular } = await supabase
          .from('marketplace_products')
          .select('*')
          .limit(10)
          .order('created_at', { ascending: false });
        return popular || [];
      }

      const locations = [...new Set(bookings.map((b: any) => b.properties?.city).filter(Boolean))];
      const categories = [...new Set(bookings.map((b: any) => b.properties?.livestock_type).filter(Boolean))];

      let query = supabase.from('marketplace_products').select('*');

      // Filter by location or category matching the booking
      if (locations.length > 0 && categories.length > 0) {
        query = query.or(`location.in.(${locations.join(',')}),category.in.(${categories.join(',')})`);
      } else if (locations.length > 0) {
        query = query.in('location', locations);
      } else if (categories.length > 0) {
        query = query.in('category', categories);
      }

      const { data: recommendations, error: productsError } = await query.limit(10);
      if (productsError) throw productsError;

      return recommendations;
    } catch (error) {
      logger.error('Error getting recommended products:', error);
      return [];
    }
  }

  /**
   * Calculate bulk discount for an order
   */
  static async calculateBulkDiscount(productId: string, quantity: number) {
    try {
      const { data: product, error } = await supabase
        .from('marketplace_products')
        .select('price, bulk_discount_rate, minimum_bulk_quantity')
        .eq('id', productId)
        .single();

      if (error || !product) throw new Error('Product not found');

      const price = parseFloat(product.price);
      const discountRate = parseFloat(product.bulk_discount_rate || '0');
      const minQuantity = parseInt(product.minimum_bulk_quantity || '10');

      if (quantity >= minQuantity && discountRate > 0) {
        const discountAmount = price * (discountRate / 100);
        const discountedPrice = price - discountAmount;
        return {
          original_price: price,
          discounted_price: discountedPrice,
          total_saving: discountAmount * quantity,
          applied_discount: discountRate
        };
      }

      return {
        original_price: price,
        discounted_price: price,
        total_saving: 0,
        applied_discount: 0
      };
    } catch (error) {
      logger.error('Error calculating bulk discount:', error);
      throw error;
    }
  }
}
