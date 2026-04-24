import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

export class FarmRecordService {
  /**
   * Link a farm record to a specific booking
   */
  static async linkToBooking(recordId: string, bookingId: string) {
    try {
      const { data, error } = await supabase
        .from('farm_records')
        .update({ booking_id: bookingId })
        .eq('id', recordId)
        .select()
        .single();

      if (error) throw error;
      return data;
    } catch (error) {
      logger.error('Error linking record to booking:', error);
      throw error;
    }
  }

  /**
   * Get productivity report for a property (for owners)
   */
  static async getPropertyProductivityReport(propertyId: string) {
    try {
      const { data: records, error } = await supabase
        .from('farm_records')
        .select('*')
        .eq('property_id', propertyId);

      if (error) throw error;

      if (!records || records.length === 0) {
        return {
          total_records: 0,
          avg_mortality_rate: 0,
          total_livestock_handled: 0,
          top_livestock_types: []
        };
      }

      const totalLivestock = records.reduce((sum, r) => sum + (r.livestock_count || 0), 0);
      const totalMortality = records.reduce((sum, r) => sum + (r.mortality_count || 0), 0);
      
      const livestockTypes: any = {};
      records.forEach(r => {
        livestockTypes[r.livestock_type] = (livestockTypes[r.livestock_type] || 0) + 1;
      });

      return {
        total_records: records.length,
        avg_mortality_rate: totalLivestock > 0 ? (totalMortality / totalLivestock) * 100 : 0,
        total_livestock_handled: totalLivestock,
        top_livestock_types: Object.entries(livestockTypes)
          .sort((a: any, b: any) => b[1] - a[1])
          .slice(0, 3)
          .map(e => e[0])
      };
    } catch (error) {
      logger.error('Error getting property productivity report:', error);
      throw error;
    }
  }

  /**
   * Get recommendations based on farm records
   */
  static async getRecommendations(farmerId: string) {
    try {
      const { data: records, error } = await supabase
        .from('farm_records')
        .select('*')
        .eq('farmer_id', farmerId)
        .order('record_date', { ascending: false })
        .limit(20);

      if (error) throw error;

      const recommendations = [];

      if (!records || records.length === 0) {
        recommendations.push({
          type: 'onboarding',
          title: 'Start Tracking',
          message: 'Begin logging your livestock activities to receive data-driven insights.'
        });
        return recommendations;
      }

      // Check mortality rates
      const totalLivestock = records.reduce((sum, r) => sum + (r.livestock_count || 0), 0);
      const totalMortality = records.reduce((sum, r) => sum + (r.mortality_count || 0), 0);
      const mortalityRate = totalLivestock > 0 ? (totalMortality / totalLivestock) * 100 : 0;

      if (mortalityRate > 5) {
        recommendations.push({
          type: 'warning',
          title: 'High Mortality Rate Detected',
          message: `Your current mortality rate is ${mortalityRate.toFixed(1)}%. We recommend checking your health protocols or consulting a specialist.`
        });
      }

      // Check expenses
      const totalExpenses = records.reduce((sum, r) => sum + (r.expenses || 0), 0);
      if (totalExpenses > 100000) { // Arbitrary threshold
        recommendations.push({
          type: 'info',
          title: 'Expense Optimization',
          message: 'Your farm expenses are growing. Check the marketplace for bulk feed discounts to reduce costs.'
        });
      }

      return recommendations;
    } catch (error) {
      logger.error('Error getting farm recommendations:', error);
      return [];
    }
  }
}
