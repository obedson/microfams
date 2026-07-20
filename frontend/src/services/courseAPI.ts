import { getTenantHeaders } from '../api/tenantHeaders';

const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:3000/api';

interface Course {
  id: string;
  title: string;
  description: string;
  content: string;
  video_url: string;
  duration: string;
  level: string;
  category: string;
  thumbnail_url?: string;
}

interface UserProgress {
  course_id: string;
  progress: number;
  completed: boolean;
  completed_at?: string;
  certificate_url?: string;
  courses?: Course;
}

class CourseAPI {
  private getAuthHeaders() {
    const token = localStorage.getItem('token');
    return getTenantHeaders(token, true);
  }

  async getCourses(): Promise<Course[]> {
    const response = await fetch(`${API_BASE}/courses/organization`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch courses');
    return response.json();
  }

  async getRecommendations(): Promise<Course[]> {
    const response = await fetch(`${API_BASE}/courses/recommendations`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch recommendations');
    return response.json();
  }

  async getUserProgress(): Promise<UserProgress[]> {
    const response = await fetch(`${API_BASE}/courses/user/progress`, {
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to fetch progress');
    return response.json();
  }

  async updateProgress(courseId: string, data: { progress: number; completed: boolean; watch_time_seconds?: number }): Promise<any> {
    const response = await fetch(`${API_BASE}/courses/${courseId}/progress`, {
      method: 'POST',
      headers: this.getAuthHeaders(),
      body: JSON.stringify(data)
    });
    if (!response.ok) throw new Error('Failed to update progress');
    return response.json();
  }

  async generateCertificate(courseId: string): Promise<any> {
    const response = await fetch(`${API_BASE}/courses/${courseId}/certificate`, {
      method: 'POST',
      headers: this.getAuthHeaders()
    });
    if (!response.ok) throw new Error('Failed to generate certificate');
    return response.json();
  }
}

export const courseAPI = new CourseAPI();
export type { Course, UserProgress };
