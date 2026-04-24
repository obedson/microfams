-- Add video_url column to courses table
ALTER TABLE courses ADD COLUMN IF NOT EXISTS video_url TEXT;
ALTER TABLE courses ADD COLUMN IF NOT EXISTS video_platform VARCHAR(20) CHECK (video_platform IN ('youtube', 'facebook', 'instagram', 'tiktok'));

-- Add video lessons table for multiple videos per course
CREATE TABLE IF NOT EXISTS course_videos (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  course_id UUID REFERENCES courses(id) ON DELETE CASCADE,
  title VARCHAR(255) NOT NULL,
  video_url TEXT NOT NULL,
  video_platform VARCHAR(20) CHECK (video_platform IN ('youtube', 'facebook', 'instagram', 'tiktok')),
  duration INTEGER, -- in seconds
  order_index INTEGER DEFAULT 0,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_course_videos_course_id ON course_videos(course_id);
CREATE INDEX idx_course_videos_order ON course_videos(course_id, order_index);
