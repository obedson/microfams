import React from 'react';

interface VideoPlayerProps {
  url: string;
  platform: 'youtube' | 'facebook' | 'instagram' | 'tiktok';
}

export const VideoPlayer: React.FC<VideoPlayerProps> = ({ url, platform }) => {
  const getEmbedUrl = () => {
    switch (platform) {
      case 'youtube':
        const youtubeId = url.match(/(?:youtube\.com\/watch\?v=|youtu\.be\/)([^&]+)/)?.[1];
        return `https://www.youtube.com/embed/${youtubeId}`;
      
      case 'facebook':
        return `https://www.facebook.com/plugins/video.php?href=${encodeURIComponent(url)}`;
      
      case 'instagram':
        return `${url}embed/`;
      
      case 'tiktok':
        return url.replace('/video/', '/embed/');
      
      default:
        return url;
    }
  };

  return (
    <div className="relative w-full" style={{ paddingBottom: '56.25%' }}>
      <iframe
        src={getEmbedUrl()}
        className="absolute top-0 left-0 w-full h-full rounded-lg"
        frameBorder="0"
        allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
        allowFullScreen
      />
    </div>
  );
};
