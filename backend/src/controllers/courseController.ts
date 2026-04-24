import { Request, Response } from 'express';
import { supabase } from '../utils/supabase.js';
import { AuthenticatedRequest } from '../types/index.js';
import { CourseService } from '../services/courseService.js';

export const getCourses = async (req: Request, res: Response) => {
  try {
    const { data, error } = await supabase
      .from('courses')
      .select('*')
      .order('created_at', { ascending: false });

    if (error) throw error;
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch courses' });
  }
};

export const getCourse = async (req: Request, res: Response) => {
  try {
    const { id } = req.params;
    const { data, error } = await supabase
      .from('courses')
      .select('*')
      .eq('id', id)
      .single();

    if (error) throw error;
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Course not found' });
  }
};

export const updateProgress = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { courseId } = req.params;
    const { progress, completed, watch_time_seconds } = req.body;
    const userId = req.user?.id;

    const { data, error } = await supabase
      .from('user_progress')
      .upsert({
        user_id: userId,
        course_id: courseId,
        progress,
        completed,
        completed_at: completed ? new Date().toISOString() : null,
        watch_time_seconds: watch_time_seconds || 0,
        last_watched_at: new Date().toISOString()
      }, {
        onConflict: 'user_id,course_id'
      });

    if (error) throw error;
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Failed to update progress' });
  }
};

export const getRecommendations = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user?.id;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });

    const recommendations = await CourseService.getRecommendedCourses(userId);
    res.json(recommendations);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch recommendations' });
  }
};

export const generateCertificate = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user?.id;
    const { courseId } = req.params;
    if (!userId) return res.status(401).json({ error: 'Unauthorized' });

    const certificate = await CourseService.generateCertificate(userId, courseId);
    res.json(certificate);
  } catch (error: any) {
    res.status(400).json({ error: error.message || 'Failed to generate certificate' });
  }
};

export const createCourse = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { title, description, content, video_url, duration, level, category } = req.body;
    
    const { data, error } = await supabase
      .from('courses')
      .insert({
        title,
        description,
        content,
        video_url,
        duration,
        level,
        category
      })
      .select()
      .single();

    if (error) throw error;
    res.status(201).json(data);
  } catch (error) {
    res.status(500).json({ error: 'Failed to create course' });
  }
};

export const updateCourse = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id } = req.params;
    const updates = req.body;
    
    const { data, error } = await supabase
      .from('courses')
      .update(updates)
      .eq('id', id)
      .select()
      .single();

    if (error) {
      console.error('Course update error:', error);
      throw error;
    }
    res.json(data);
  } catch (error: any) {
    console.error('Failed to update course:', error);
    res.status(500).json({ error: error.message || 'Failed to update course' });
  }
};

export const deleteCourse = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const { id } = req.params;
    
    const { error } = await supabase
      .from('courses')
      .delete()
      .eq('id', id);

    if (error) throw error;
    res.json({ message: 'Course deleted successfully' });
  } catch (error) {
    res.status(500).json({ error: 'Failed to delete course' });
  }
};

export const getUserProgress = async (req: AuthenticatedRequest, res: Response) => {
  try {
    const userId = req.user?.id;
    const { data, error } = await supabase
      .from('user_progress')
      .select('*, courses(*)')
      .eq('user_id', userId);

    if (error) throw error;
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch progress' });
  }
};
