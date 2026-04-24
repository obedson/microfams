import { Router } from 'express';
import { authenticateToken, requireRole, AuthRequest } from '../middleware/auth.js';
import { supabase } from '../utils/supabase.js';

const router = Router();

// Get all videos for a course
router.get('/courses/:courseId/videos', async (req, res) => {
  try {
    const { courseId } = req.params;
    
    const { data, error } = await supabase
      .from('course_videos')
      .select('*')
      .eq('course_id', courseId)
      .order('order_index', { ascending: true });

    if (error) throw error;
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch videos' });
  }
});

// Add video to course (admin only)
router.post('/courses/:courseId/videos', authenticateToken, requireRole(['admin']), async (req: AuthRequest, res) => {
  try {
    const { courseId } = req.params;
    const { title, video_url, video_platform, duration, order_index } = req.body;

    const { data, error } = await supabase
      .from('course_videos')
      .insert({
        course_id: courseId,
        title,
        video_url,
        video_platform,
        duration,
        order_index
      })
      .select()
      .single();

    if (error) throw error;
    res.status(201).json(data);
  } catch (error) {
    res.status(500).json({ error: 'Failed to add video' });
  }
});

// Delete video (admin only)
router.delete('/videos/:videoId', authenticateToken, requireRole(['admin']), async (req: AuthRequest, res) => {
  try {
    const { videoId } = req.params;

    const { error } = await supabase
      .from('course_videos')
      .delete()
      .eq('id', videoId);

    if (error) throw error;
    res.json({ success: true });
  } catch (error) {
    res.status(500).json({ error: 'Failed to delete video' });
  }
});

export default router;
