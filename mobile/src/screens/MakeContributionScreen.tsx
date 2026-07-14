import React, { useState } from 'react';
import { View, Text, TouchableOpacity, StyleSheet, Alert, ActivityIndicator } from 'react-native';
import { RouteProp, useRoute, useNavigation } from '@react-navigation/native';
import { WebView, WebViewNavigation } from 'react-native-webview';
import axios, { AxiosError } from 'axios';
import { API_URL } from '../api/client';
import { useAuthStore } from '../store/authStore';
import { RootStackParamList } from '../navigation/types';

interface ApiError {
  error?: string;
}

export default function MakeContributionScreen() {
  const [paymentUrl, setPaymentUrl] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const route = useRoute<RouteProp<RootStackParamList, 'MakeContribution'>>();
  const navigation = useNavigation();
  const { token } = useAuthStore();
  const { contributionId, amount } = route.params;

  const initiatePayment = async () => {
    setLoading(true);
    try {
      const { data } = await axios.post(
        `${API_URL}/contributions/${contributionId}/pay`,
        {},
        { headers: { Authorization: `Bearer ${token}` } }
      );
      setPaymentUrl(data.authorization_url);
    } catch (error) {
      const message = error instanceof AxiosError
        ? (error.response?.data as ApiError | undefined)?.error
        : undefined;
      Alert.alert('Error', message || 'Payment failed');
      setLoading(false);
    }
  };

  const handleNavigationStateChange = (navState: WebViewNavigation) => {
    if (navState.url.includes('/payment/callback')) {
      setPaymentUrl(null);
      Alert.alert('Success', 'Payment completed!', [
        { text: 'OK', onPress: () => navigation.goBack() }
      ]);
    }
  };

  if (paymentUrl) {
    return (
      <WebView
        source={{ uri: paymentUrl }}
        onNavigationStateChange={handleNavigationStateChange}
      />
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.card}>
        <Text style={styles.label}>Amount Due</Text>
        <Text style={styles.amount}>₦{amount?.toLocaleString()}</Text>
      </View>

      <TouchableOpacity
        style={styles.button}
        onPress={initiatePayment}
        disabled={loading}
      >
        {loading ? (
          <ActivityIndicator color="white" />
        ) : (
          <Text style={styles.buttonText}>Pay Now</Text>
        )}
      </TouchableOpacity>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#f5f5f5', padding: 20 },
  card: { backgroundColor: 'white', padding: 24, borderRadius: 12, alignItems: 'center', marginBottom: 24 },
  label: { fontSize: 14, color: '#666', marginBottom: 8 },
  amount: { fontSize: 36, fontWeight: 'bold', color: '#10b981' },
  button: { backgroundColor: '#10b981', padding: 16, borderRadius: 8, alignItems: 'center' },
  buttonText: { color: 'white', fontSize: 16, fontWeight: 'bold' },
});
