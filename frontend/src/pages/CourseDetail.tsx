import React, { useState, useEffect } from 'react';
import { useParams } from 'react-router-dom';
import axios from 'axios';
import toast from 'react-hot-toast';
import { VideoPlayer } from '../components/VideoPlayer';
import { LoadingSpinner } from '../components/Loading';

const API_URL = process.env.REACT_APP_API_URL || 'http://localhost:3001/api';

export default function CourseDetail() {
  const [course, setCourse] = useState<any>(null);
  const [videos, setVideos] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const { id } = useParams();

  useEffect(() => {
    fetchCourse();
    fetchVideos();
  }, [id]);

  const fetchCourse = async () => {
    try {
      const { data } = await axios.get(`${API_URL}/courses/${id}`);
      setCourse(data);
    } catch (error) {
      toast.error('Failed to load course');
    } finally {
      setLoading(false);
    }
  };

  const fetchVideos = async () => {
    try {
      const { data } = await axios.get(`${API_URL}/courses/${id}/videos`);
      setVideos(data);
    } catch (error) {
      console.error('Failed to load videos');
    }
  };

  if (loading) {
    return (
      <div className="flex justify-center items-center min-h-screen">
        <LoadingSpinner size="lg" />
      </div>
    );
  }

  if (!course) return <div>Course not found</div>;

  return (
    <div className="max-w-4xl mx-auto px-4 py-8">
      <h1 className="text-3xl font-bold mb-4">{course.title}</h1>
      <p className="text-gray-600 mb-8">{course.description}</p>

      {course.video_url && (
        <div className="mb-8">
          <h2 className="text-xl font-semibold mb-4">Course Introduction</h2>
          <VideoPlayer url={course.video_url} platform={course.video_platform || 'youtube'} />
        </div>
      )}

      {videos.length > 0 && (
        <div>
          <h2 className="text-xl font-semibold mb-4">Course Lessons</h2>
          <div className="space-y-6">
            {videos.map((video, index) => (
              <div key={video.id} className="bg-white rounded-lg shadow p-4">
                <h3 className="font-semibold mb-2">
                  Lesson {index + 1}: {video.title}
                </h3>
                <VideoPlayer url={video.video_url} platform={video.video_platform} />
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
