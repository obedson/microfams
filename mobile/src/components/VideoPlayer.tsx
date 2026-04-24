import React from 'react';
import { View, StyleSheet } from 'react-native';
import { WebView } from 'react-native-webview';

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
    <View style={styles.container}>
      <WebView
        source={{ uri: getEmbedUrl() }}
        style={styles.video}
        allowsFullscreenVideo
      />
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    width: '100%',
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
  },
  video: {
    flex: 1,
  },
});
