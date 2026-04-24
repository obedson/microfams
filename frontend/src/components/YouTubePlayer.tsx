import React, { useEffect, useRef, useState } from 'react';

interface YouTubePlayerProps {
  videoId: string;
  onTimeUpdate: (seconds: number) => void;
}

declare global {
  interface Window {
    YT: any;
    onYouTubeIframeAPIReady: () => void;
  }
}

export const YouTubePlayer: React.FC<YouTubePlayerProps> = ({ videoId, onTimeUpdate }) => {
  const playerRef = useRef<any>(null);
  const [watchTime, setWatchTime] = useState(0);
  const intervalRef = useRef<NodeJS.Timeout>();

  useEffect(() => {
    // Load YouTube IFrame API
    if (!window.YT) {
      const tag = document.createElement('script');
      tag.src = 'https://www.youtube.com/iframe_api';
      document.body.appendChild(tag);
    }

    window.onYouTubeIframeAPIReady = () => {
      playerRef.current = new window.YT.Player('youtube-player', {
        videoId,
        events: {
          onStateChange: (event: any) => {
            if (event.data === window.YT.PlayerState.PLAYING) {
              startTracking();
            } else {
              stopTracking();
            }
          }
        }
      });
    };

    return () => {
      stopTracking();
      if (playerRef.current) {
        playerRef.current.destroy();
      }
    };
  }, [videoId]);

  const startTracking = () => {
    intervalRef.current = setInterval(() => {
      setWatchTime(prev => {
        const newTime = prev + 1;
        onTimeUpdate(newTime);
        return newTime;
      });
    }, 1000);
  };

  const stopTracking = () => {
    if (intervalRef.current) {
      clearInterval(intervalRef.current);
    }
  };

  return <div id="youtube-player" />;
};
