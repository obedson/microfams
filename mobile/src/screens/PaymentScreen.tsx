import React from 'react';
import { View, StyleSheet, ActivityIndicator } from 'react-native';
import { WebView } from 'react-native-webview';

export default function PaymentScreen({ route, navigation }: any) {
  const { paymentUrl, reference } = route.params;

  const handleNavigationStateChange = (navState: any) => {
    const { url } = navState;
    
    // Check if payment callback URL
    if (url.includes('/payment/callback') || url.includes('success')) {
      navigation.replace('PaymentSuccess', { reference });
    }
  };

  return (
    <View style={styles.container}>
      <WebView
        source={{ uri: paymentUrl }}
        onNavigationStateChange={handleNavigationStateChange}
        startInLoadingState={true}
        renderLoading={() => (
          <View style={styles.loading}>
            <ActivityIndicator size="large" color="#10b981" />
          </View>
        )}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  loading: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#fff',
  },
});
