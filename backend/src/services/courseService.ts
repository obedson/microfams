import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

export class CourseService {
  /**
   * Get recommended courses based on user's booking history
   */
  static async getRecommendedCourses(userId: string) {
    try {
      // Get user's recent bookings to understand their interests
      const { data: bookings, error: bookingsError } = await supabase
        .from('bookings')
        .select(`
          property_id,
          properties (
            livestock_type,
            title
          )
        `)
        .eq('farmer_id', userId)
        .limit(5);

      if (bookingsError) throw bookingsError;

      const categories = [...new Set(bookings?.map((b: any) => b.properties?.livestock_type).filter(Boolean))];
      
      let query = supabase.from('courses').select('*');

      if (categories.length > 0) {
        // Recommend courses in same categories as booked properties
        query = query.in('category', categories);
      } else {
        // Default to popular/new courses if no booking history
        query = query.limit(5).order('created_at', { ascending: false });
      }

      const { data: recommendations, error: coursesError } = await query.limit(10);
      if (coursesError) throw coursesError;

      return recommendations;
    } catch (error) {
      logger.error('Error getting recommended courses:', error);
      return [];
    }
  }

  /**
   * Generate a completion certificate for a course
   */
  static async generateCertificate(userId: string, courseId: string) {
    try {
      // Verify course completion
      const { data: progress, error: progressError } = await supabase
        .from('user_progress')
        .select(`
          *,
          courses (title),
          users (name)
        `)
        .eq('user_id', userId)
        .eq('course_id', courseId)
        .single();

      if (progressError || !progress || !progress.completed) {
        throw new Error('Course not completed');
      }

      // In a real app, we would generate a PDF and upload to S3
      // For this implementation, we'll generate a signed verification URL
      const certificateId = `${userId.slice(0, 8)}-${courseId.slice(0, 8)}`;
      const certificateUrl = `https://microfams.vercel.app/verify/certificate/${certificateId}`;

      // Update progress with certificate info
      await supabase
        .from('user_progress')
        .update({ certificate_url: certificateUrl })
        .eq('user_id', userId)
        .eq('course_id', courseId);

      return {
        certificate_id: certificateId,
        certificate_url: certificateUrl,
        course_title: (progress.courses as any).title,
        user_name: (progress.users as any).name,
        completed_at: progress.completed_at
      };
    } catch (error) {
      logger.error('Error generating certificate:', error);
      throw error;
    }
  }
}
