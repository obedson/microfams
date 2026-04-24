import React, { useState, useEffect } from 'react';
import { courseAPI, UserProgress } from '../../services/courseAPI';
import { Award, CheckCircle2, PlayCircle } from 'lucide-react';

const UserCourseProgress: React.FC = () => {
  const [progress, setProgress] = useState<UserProgress[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const fetchProgress = async () => {
      try {
        const data = await courseAPI.getUserProgress();
        setProgress(data);
      } catch (error) {
        console.error('Error fetching user progress:', error);
      } finally {
        setLoading(false);
      }
    };

    fetchProgress();
  }, []);

  const handleDownloadCertificate = async (courseId: string) => {
    try {
      const result = await courseAPI.generateCertificate(courseId);
      window.open(result.certificate_url, '_blank');
    } catch (error) {
      console.error('Error generating certificate:', error);
      alert('Failed to generate certificate. Please try again.');
    }
  };

  if (loading) return <div className="animate-pulse h-40 bg-gray-100 rounded-xl"></div>;
  if (progress.length === 0) return null;

  return (
    <div className="bg-white rounded-xl shadow-sm border border-gray-100 p-6">
      <h3 className="text-lg font-bold text-gray-900 mb-6">Learning Progress</h3>
      
      <div className="space-y-6">
        {progress.map((item) => (
          <div key={item.course_id} className="space-y-2">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                {item.completed ? (
                  <CheckCircle2 className="text-green-500" size={18} />
                ) : (
                  <PlayCircle className="text-primary-500" size={18} />
                )}
                <span className="font-medium text-gray-900">{item.courses?.title}</span>
              </div>
              <span className="text-sm font-semibold text-gray-700">{item.progress}%</span>
            </div>
            
            <div className="w-full bg-gray-100 rounded-full h-2">
              <div 
                className={`h-2 rounded-full transition-all duration-500 ${
                  item.completed ? 'bg-green-500' : 'bg-primary-600'
                }`}
                style={{ width: `${item.progress}%` }}
              ></div>
            </div>

            {item.completed && (
              <div className="flex justify-end">
                <button
                  onClick={() => handleDownloadCertificate(item.course_id)}
                  className="flex items-center gap-1.5 text-xs font-bold text-primary-600 hover:text-primary-700 bg-primary-50 px-3 py-1.5 rounded-lg transition-colors mt-1"
                >
                  <Award size={14} />
                  Download Certificate
                </button>
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  );
};

export default UserCourseProgress;
