import { supabase } from '../utils/supabase.js';
import { logger } from '../utils/logger.js';

export class CourseService {
  static async getRecommendedCourses(userId: string, organizationId: string = userId) {
    try {
      const { data: bookings, error: bookingsError } = await supabase
        .from('bookings')
        .select('property_id, properties(livestock_type, title)')
        .eq('farmer_id', userId)
        .eq('organization_id', organizationId)
        .limit(5);
      if (bookingsError) throw bookingsError;

      const categories = [...new Set(bookings?.map((booking: any) => booking.properties?.livestock_type).filter(Boolean))];
      let query = supabase.from('courses').select('*')
        .or(`organization_id.is.null,organization_id.eq.${organizationId}`);
      if (categories.length > 0) query = query.in('category', categories);
      else query = query.order('created_at', { ascending: false });

      const { data, error } = await query.limit(10);
      if (error) throw error;
      return data || [];
    } catch (error) {
      logger.error('Error getting recommended courses:', error);
      return [];
    }
  }

  static async generateCertificate(userId: string, courseId: string, organizationId: string = userId) {
    const { data: progress, error } = await supabase
      .from('user_progress')
      .select('*, courses(title), users(name)')
      .eq('organization_id', organizationId)
      .eq('user_id', userId)
      .eq('course_id', courseId)
      .single();

    if (error || !progress?.completed) throw new Error('Course not completed in the active organization');

    const certificateId = `${organizationId.slice(0, 8)}-${userId.slice(0, 8)}-${courseId.slice(0, 8)}`;
    const certificateUrl = `${process.env.FRONTEND_URL || 'https://microfams.vercel.app'}/verify/certificate/${certificateId}`;
    const { error: updateError } = await supabase.from('user_progress')
      .update({ certificate_url: certificateUrl })
      .eq('organization_id', organizationId).eq('user_id', userId).eq('course_id', courseId);
    if (updateError) throw updateError;

    return {
      certificate_id: certificateId,
      certificate_url: certificateUrl,
      organization_id: organizationId,
      course_title: (progress.courses as any).title,
      user_name: (progress.users as any).name,
      completed_at: progress.completed_at,
    };
  }
}
