import { Course, UserProgress } from '../types/course';
import { getActiveOrganizationId, getTenantHeaders } from './tenantHeaders';

const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

const getToken = () => {
  // Try localStorage first (direct token storage)
  let token = localStorage.getItem('token');
  
  // If not found, try Zustand auth storage
  if (!token) {
    const authStorage = localStorage.getItem('auth-storage');
    if (authStorage) {
      const parsed = JSON.parse(authStorage);
      token = parsed.state?.token;
    }
  }
  
  return token;
};

export const courseApi = {
  getCourses: async (): Promise<Course[]> => {
    const token = getToken();
    const tenantPath = token && getActiveOrganizationId() ? '/courses/organization' : '/courses';
    const response = await fetch(`${API_BASE}${tenantPath}`, {
      headers: getTenantHeaders(token),
    });
    return response.json();
  },

  getCourse: async (id: string): Promise<Course> => {
    const token = getToken();
    const tenantPath = token && getActiveOrganizationId()
      ? `/courses/organization/${id}`
      : `/courses/${id}`;
    const response = await fetch(`${API_BASE}${tenantPath}`, {
      headers: getTenantHeaders(token),
    });
    return response.json();
  },

  createCourse: async (courseData: Omit<Course, 'id' | 'created_at'>): Promise<Course> => {
    const token = getToken();
    if (!token) {
      throw new Error('Please log in to create a course');
    }
    
    const response = await fetch(`${API_BASE}/courses`, {
      method: 'POST',
      headers: getTenantHeaders(token, true),
      body: JSON.stringify(courseData)
    });
    
    const data = await response.json();
    
    if (!response.ok) {
      throw new Error(data.error || 'Failed to create course');
    }
    
    return data;
  },

  updateCourse: async (id: string, courseData: Partial<Course>): Promise<Course> => {
    const token = getToken();
    if (!token) {
      throw new Error('Please log in to update a course');
    }
    
    const response = await fetch(`${API_BASE}/courses/${id}`, {
      method: 'PUT',
      headers: getTenantHeaders(token, true),
      body: JSON.stringify(courseData)
    });
    
    const data = await response.json();
    
    if (!response.ok) {
      throw new Error(data.error || 'Failed to update course');
    }
    
    return data;
  },

  deleteCourse: async (id: string): Promise<void> => {
    const token = getToken();
    if (!token) {
      throw new Error('Please log in to delete a course');
    }
    
    const response = await fetch(`${API_BASE}/courses/${id}`, {
      method: 'DELETE',
      headers: getTenantHeaders(token)
    });
    
    if (!response.ok) {
      const data = await response.json();
      throw new Error(data.error || 'Failed to delete course');
    }
  },

  updateProgress: async (courseId: string, progress: number, completed: boolean, watchTime?: number): Promise<void> => {
    const token = getToken();
    await fetch(`${API_BASE}/courses/${courseId}/progress`, {
      method: 'POST',
      headers: getTenantHeaders(token, true),
      body: JSON.stringify({ progress, completed, watch_time_seconds: watchTime })
    });
  },

  getUserProgress: async (): Promise<UserProgress[]> => {
    const token = getToken();
    const response = await fetch(`${API_BASE}/courses/user/progress`, {
      headers: getTenantHeaders(token)
    });
    return response.json();
  }
};
