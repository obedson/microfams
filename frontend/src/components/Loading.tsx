import React from 'react';

interface LoadingSpinnerProps {
  size?: 'sm' | 'md' | 'lg';
  color?: string;
}

export const LoadingSpinner: React.FC<LoadingSpinnerProps> = ({ 
  size = 'md',
  color = '#10b981' 
}) => {
  const sizeClasses = {
    sm: 'h-4 w-4',
    md: 'h-8 w-8',
    lg: 'h-12 w-12'
  };

  return (
    <div className="flex justify-center items-center">
      <div
        className={`${sizeClasses[size]} border-4 border-gray-200 border-t-[${color}] rounded-full animate-spin`}
      />
    </div>
  );
};

export const LoadingOverlay: React.FC<{ message?: string }> = ({ message }) => (
  <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
    <div className="bg-white rounded-lg p-6 flex flex-col items-center">
      <LoadingSpinner size="lg" />
      {message && <p className="mt-4 text-gray-700">{message}</p>}
    </div>
  </div>
);

export const SkeletonCard: React.FC = () => (
  <div className="bg-white rounded-lg p-6 animate-pulse">
    <div className="h-4 bg-gray-200 rounded w-3/4 mb-4"></div>
    <div className="h-4 bg-gray-200 rounded w-1/2 mb-2"></div>
    <div className="h-4 bg-gray-200 rounded w-5/6"></div>
  </div>
);
