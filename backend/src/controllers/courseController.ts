import { Request, Response } from 'express';
import { supabase } from '../utils/supabase.js';
import { TenantRequest } from '../middleware/tenant.js';
import { CourseService } from '../services/courseService.js';

const courseFields = ['title', 'description', 'content', 'video_url', 'duration', 'level', 'category', 'thumbnail_url'] as const;

const selectCourseUpdates = (body: Record<string, unknown>) => Object.fromEntries(
  courseFields.filter((field) => Object.prototype.hasOwnProperty.call(body, field)).map((field) => [field, body[field]]),
);

export const getCourses = async (_req: Request, res: Response) => {
  try {
    const { data, error } = await supabase
      .from('courses').select('*').is('organization_id', null)
      .order('created_at', { ascending: false });
    if (error) throw error;
    return res.json(data || []);
  } catch {
    return res.status(500).json({ error: 'Failed to fetch courses' });
  }
};

export const getCourse = async (req: Request, res: Response) => {
  const { data, error } = await supabase
    .from('courses').select('*').eq('id', req.params.id).is('organization_id', null).maybeSingle();
  if (error || !data) return res.status(404).json({ error: 'Course not found' });
  return res.json(data);
};

export const getOrganizationCourses = async (req: TenantRequest, res: Response) => {
  const { data, error } = await supabase
    .from('courses').select('*')
    .or(`organization_id.is.null,organization_id.eq.${req.tenant!.id}`)
    .order('created_at', { ascending: false });
  if (error) return res.status(500).json({ error: 'Failed to fetch organization courses' });
  return res.json(data || []);
};

export const getOrganizationCourse = async (req: TenantRequest, res: Response) => {
  const { data, error } = await supabase
    .from('courses').select('*').eq('id', req.params.id)
    .or(`organization_id.is.null,organization_id.eq.${req.tenant!.id}`).maybeSingle();
  if (error || !data) return res.status(404).json({ error: 'Course not found' });
  return res.json(data);
};

export const updateProgress = async (req: TenantRequest, res: Response) => {
  const progress = Number(req.body.progress);
  const watchTime = Number(req.body.watch_time_seconds || 0);
  if (!Number.isFinite(progress) || progress < 0 || progress > 100 || !Number.isFinite(watchTime) || watchTime < 0) {
    return res.status(400).json({ error: 'Progress must be between 0 and 100 and watch time cannot be negative' });
  }

  const { data: course } = await supabase.from('courses').select('id').eq('id', req.params.courseId)
    .or(`organization_id.is.null,organization_id.eq.${req.tenant!.id}`).maybeSingle();
  if (!course) return res.status(404).json({ error: 'Course not found' });

  const completed = Boolean(req.body.completed) && progress >= 100;
  const { data, error } = await supabase.from('user_progress').upsert({
    organization_id: req.tenant!.id,
    user_id: req.user!.id,
    course_id: req.params.courseId,
    progress,
    completed,
    completed_at: completed ? new Date().toISOString() : null,
    watch_time_seconds: watchTime,
    last_watched_at: new Date().toISOString(),
  }, { onConflict: 'organization_id,user_id,course_id' }).select().single();

  if (error) return res.status(500).json({ error: 'Failed to update progress' });
  return res.json(data);
};

export const getRecommendations = async (req: TenantRequest, res: Response) => {
  const recommendations = await CourseService.getRecommendedCourses(req.user!.id, req.tenant!.id);
  return res.json(recommendations);
};

export const generateCertificate = async (req: TenantRequest, res: Response) => {
  try {
    return res.json(await CourseService.generateCertificate(req.user!.id, req.params.courseId, req.tenant!.id));
  } catch (error) {
    return res.status(400).json({ error: error instanceof Error ? error.message : 'Failed to generate certificate' });
  }
};

export const createCourse = async (req: TenantRequest, res: Response) => {
  const values = selectCourseUpdates(req.body);
  if (typeof values.title !== 'string' || !values.title.trim()) {
    return res.status(400).json({ error: 'Course title is required' });
  }
  const { data, error } = await supabase.from('courses')
    .insert({ ...values, organization_id: req.tenant!.id }).select().single();
  if (error) return res.status(500).json({ error: 'Failed to create course' });
  return res.status(201).json(data);
};

export const updateCourse = async (req: TenantRequest, res: Response) => {
  const updates = selectCourseUpdates(req.body);
  if (Object.keys(updates).length === 0) return res.status(400).json({ error: 'No supported course fields supplied' });
  const { data, error } = await supabase.from('courses').update(updates)
    .eq('id', req.params.id).eq('organization_id', req.tenant!.id).select().maybeSingle();
  if (error || !data) return res.status(404).json({ error: 'Course not found in the active organization' });
  return res.json(data);
};

export const deleteCourse = async (req: TenantRequest, res: Response) => {
  const { data, error } = await supabase.from('courses').delete()
    .eq('id', req.params.id).eq('organization_id', req.tenant!.id).select('id').maybeSingle();
  if (error || !data) return res.status(404).json({ error: 'Course not found in the active organization' });
  return res.json({ message: 'Course deleted successfully' });
};

export const getUserProgress = async (req: TenantRequest, res: Response) => {
  const { data, error } = await supabase.from('user_progress').select('*, courses(*)')
    .eq('user_id', req.user!.id).eq('organization_id', req.tenant!.id);
  if (error) return res.status(500).json({ error: 'Failed to fetch progress' });
  return res.json(data || []);
};
