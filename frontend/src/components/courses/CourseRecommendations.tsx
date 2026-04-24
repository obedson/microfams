import React, { useState, useEffect } from 'react';
import { Link } from 'react-router-dom';
import { courseAPI, Course } from '../../services/courseAPI';
import { BookOpen, Clock, BarChart, ChevronRight } from 'lucide-react';

const CourseRecommendations: React.FC = () => {
  const [recommendations, setRecommendations] = useState<Course[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetchRecommendations = async () => {
      try {
        const data = await courseAPI.getRecommendations();
        setRecommendations(data);
      } catch (error) {
        console.error('Error fetching recommended courses:', error);
      } finally {
        setLoading(false);
      }
    };

    fetchRecommendations();
  }, []);

  if (loading) {
    return (
      <div className="animate-pulse flex space-x-4 p-4 bg-white rounded-xl">
        <div className="flex-1 space-y-4 py-1">
          <div className="h-4 bg-gray-200 rounded w-3/4"></div>
          <div className="space-y-2">
            <div className="h-4 bg-gray-200 rounded"></div>
            <div className="h-4 bg-gray-200 rounded w-5/6"></div>
          </div>
        </div>
      </div>
    );
  }

  if (recommendations.length === 0) {
    return null;
  }

  return (
    <div className="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
      <div className="flex items-center justify-between mb-6">
        <div>
          <h3 className="text-lg font-bold text-gray-900">Recommended for You</h3>
          <p className="text-sm text-gray-500">Based on your booking interests</p>
        </div>
        <Link 
          to="/courses" 
          className="text-primary-600 hover:text-primary-700 text-sm font-semibold flex items-center gap-1"
        >
          View all <ChevronRight size={16} />
        </Link>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
        {recommendations.slice(0, 2).map((course) => (
          <div key={course.id} className="flex gap-4 p-4 rounded-lg border border-gray-100 hover:border-primary-200 hover:bg-primary-50/30 transition-all group">
            <div className="w-20 h-20 bg-primary-100 rounded-lg flex items-center justify-center text-primary-600 flex-shrink-0">
              <BookOpen size={32} />
            </div>
            <div className="flex-1 min-w-0">
              <h4 className="font-semibold text-gray-900 truncate group-hover:text-primary-700">
                {course.title}
              </h4>
              <div className="flex items-center gap-3 mt-2 text-xs text-gray-500">
                <span className="flex items-center gap-1">
                  <Clock size={12} /> {course.duration}
                </span>
                <span className="flex items-center gap-1">
                  <BarChart size={12} /> {course.level}
                </span>
              </div>
              <Link 
                to={`/courses/${course.id}`}
                className="inline-block mt-3 text-sm font-medium text-primary-600 hover:underline"
              >
                Start Learning
              </Link>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
};

export default CourseRecommendations;
