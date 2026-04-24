import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TextInput,
  TouchableOpacity,
  Alert,
  ActivityIndicator,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import apiClient from '../api/client';

export default function CreateBookingScreen({ route, navigation }: any) {
  const { propertyId, property } = route.params;
  const [loading, setLoading] = useState(false);
  const [bookingId, setBookingId] = useState<string | null>(null);
  const [formData, setFormData] = useState({
    start_date: '',
    end_date: '',
  });

  const calculateTotal = () => {
    if (!formData.start_date || !formData.end_date || !property) return 0;
    const start = new Date(formData.start_date);
    const end = new Date(formData.end_date);
    const days = Math.ceil((end.getTime() - start.getTime()) / (1000 * 60 * 60 * 24));
    const months = Math.ceil(days / 30);
    return months * property.price_per_month;
  };

  const handleSubmit = async () => {
    if (!formData.start_date || !formData.end_date) {
      Alert.alert('Error', 'Please select start and end dates');
      return;
    }

    const total = calculateTotal();
    if (total <= 0) {
      Alert.alert('Error', 'Invalid date range');
      return;
    }

    setLoading(true);
    try {
      const response = await apiClient.post('/bookings', {
        property_id: propertyId,
        start_date: formData.start_date,
        end_date: formData.end_date,
        total_amount: total,
      });

      const booking = response.data.data || response.data;
      setBookingId(booking.id);
      Alert.alert('Success', 'Booking created! Proceed to payment.');
    } catch (error: any) {
      Alert.alert('Error', error.response?.data?.message || 'Failed to create booking');
    } finally {
      setLoading(false);
    }
  };

  const handlePayment = async () => {
    if (!bookingId) return;

    setLoading(true);
    try {
      const response = await apiClient.post('/payments/initialize', {
        booking_id: bookingId
      });
      const { authorization_url } = response.data.data;
      
      Alert.alert(
        'Payment',
        'You will be redirected to Paystack for payment',
        [
          { text: 'Cancel', style: 'cancel' },
          { 
            text: 'Continue', 
            onPress: () => {
              // In a real app, open browser or WebView with authorization_url
              Alert.alert('Info', 'Payment integration coming soon');
              navigation.navigate('MyBookings');
            }
          }
        ]
      );
    } catch (error: any) {
      Alert.alert('Error', error.response?.data?.message || 'Payment initialization failed');
    } finally {
      setLoading(false);
    }
  };

  const total = calculateTotal();
  const getTodayDate = () => new Date().toISOString().split('T')[0];

  if (bookingId) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity onPress={() => navigation.goBack()}>
            <Ionicons name="close" size={24} color="#111" />
          </TouchableOpacity>
          <Text style={styles.headerTitle}>Complete Payment</Text>
          <View style={{ width: 24 }} />
        </View>

        <View style={styles.successContainer}>
          <View style={styles.successIcon}>
            <Ionicons name="checkmark-circle" size={64} color="#10b981" />
          </View>
          <Text style={styles.successTitle}>Booking Created!</Text>
          <Text style={styles.successText}>Complete payment to confirm your booking</Text>

          <View style={styles.totalCard}>
            <Text style={styles.totalLabel}>Total Amount</Text>
            <Text style={styles.totalAmount}>₦{total.toLocaleString()}</Text>
          </View>

          <TouchableOpacity
            style={[styles.payButton, loading && styles.buttonDisabled]}
            onPress={handlePayment}
            disabled={loading}
          >
            {loading ? (
              <ActivityIndicator color="#fff" />
            ) : (
              <>
                <Ionicons name="card" size={20} color="#fff" />
                <Text style={styles.payButtonText}>Pay with Paystack</Text>
              </>
            )}
          </TouchableOpacity>

          <TouchableOpacity
            style={styles.laterButton}
            onPress={() => navigation.navigate('MyBookings')}
          >
            <Text style={styles.laterButtonText}>Pay Later</Text>
          </TouchableOpacity>
        </View>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity onPress={() => navigation.goBack()}>
          <Ionicons name="arrow-back" size={24} color="#111" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>Book Property</Text>
        <View style={{ width: 24 }} />
      </View>

      <ScrollView style={styles.content}>
        {property && (
          <View style={styles.priceCard}>
            <Text style={styles.priceLabel}>Price</Text>
            <View style={styles.priceRow}>
              <Text style={styles.price}>₦{property.price_per_month?.toLocaleString()}</Text>
              <Text style={styles.priceUnit}>/month</Text>
            </View>
          </View>
        )}

        <Text style={styles.label}>Start Date *</Text>
        <View style={styles.inputContainer}>
          <Ionicons name="calendar-outline" size={20} color="#666" style={styles.inputIcon} />
          <TextInput
            style={styles.input}
            placeholder="YYYY-MM-DD"
            value={formData.start_date}
            onChangeText={(text) => setFormData({ ...formData, start_date: text })}
          />
        </View>
        <Text style={styles.hint}>Format: {getTodayDate()}</Text>

        <Text style={styles.label}>End Date *</Text>
        <View style={styles.inputContainer}>
          <Ionicons name="calendar-outline" size={20} color="#666" style={styles.inputIcon} />
          <TextInput
            style={styles.input}
            placeholder="YYYY-MM-DD"
            value={formData.end_date}
            onChangeText={(text) => setFormData({ ...formData, end_date: text })}
          />
        </View>
        <Text style={styles.hint}>Must be after start date</Text>

        {total > 0 && (
          <View style={styles.summaryCard}>
            <View style={styles.summaryRow}>
              <Text style={styles.summaryLabel}>Total:</Text>
              <Text style={styles.summaryAmount}>₦{total.toLocaleString()}</Text>
            </View>
          </View>
        )}

        <Text style={styles.note}>
          You'll be redirected to secure payment after booking
        </Text>
      </ScrollView>

      <View style={styles.footer}>
        <TouchableOpacity
          style={[styles.submitButton, loading && styles.buttonDisabled]}
          onPress={handleSubmit}
          disabled={loading}
        >
          {loading ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <>
              <Ionicons name="card-outline" size={20} color="#fff" />
              <Text style={styles.submitButtonText}>Book Now</Text>
            </>
          )}
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#fff',
  },
  header: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    padding: 20,
    paddingTop: 60,
    borderBottomWidth: 1,
    borderBottomColor: '#e5e7eb',
  },
  headerTitle: {
    fontSize: 18,
    fontWeight: '600',
  },
  content: {
    flex: 1,
    padding: 20,
  },
  priceCard: {
    backgroundColor: '#f9fafb',
    padding: 16,
    borderRadius: 12,
    marginBottom: 24,
  },
  priceLabel: {
    fontSize: 14,
    color: '#666',
    marginBottom: 4,
  },
  priceRow: {
    flexDirection: 'row',
    alignItems: 'baseline',
  },
  price: {
    fontSize: 28,
    fontWeight: 'bold',
    color: '#10b981',
  },
  priceUnit: {
    fontSize: 16,
    color: '#666',
    marginLeft: 4,
  },
  label: {
    fontSize: 14,
    fontWeight: '600',
    marginBottom: 8,
    color: '#374151',
  },
  inputContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    borderWidth: 1,
    borderColor: '#d1d5db',
    borderRadius: 8,
    marginBottom: 4,
  },
  inputIcon: {
    marginLeft: 12,
  },
  input: {
    flex: 1,
    padding: 12,
    fontSize: 16,
  },
  hint: {
    fontSize: 12,
    color: '#9ca3af',
    marginBottom: 16,
  },
  summaryCard: {
    backgroundColor: '#f9fafb',
    padding: 16,
    borderRadius: 12,
    marginTop: 8,
    marginBottom: 16,
  },
  summaryRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  summaryLabel: {
    fontSize: 16,
    fontWeight: '600',
  },
  summaryAmount: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#10b981',
  },
  note: {
    fontSize: 12,
    color: '#9ca3af',
    textAlign: 'center',
    marginTop: 8,
  },
  footer: {
    padding: 16,
    borderTopWidth: 1,
    borderTopColor: '#e5e7eb',
  },
  submitButton: {
    backgroundColor: '#10b981',
    padding: 16,
    borderRadius: 8,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  buttonDisabled: {
    opacity: 0.6,
  },
  submitButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
  successContainer: {
    flex: 1,
    padding: 20,
    justifyContent: 'center',
    alignItems: 'center',
  },
  successIcon: {
    marginBottom: 24,
  },
  successTitle: {
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 8,
  },
  successText: {
    fontSize: 16,
    color: '#666',
    marginBottom: 32,
    textAlign: 'center',
  },
  totalCard: {
    width: '100%',
    backgroundColor: '#f9fafb',
    padding: 24,
    borderRadius: 12,
    alignItems: 'center',
    marginBottom: 24,
  },
  totalLabel: {
    fontSize: 14,
    color: '#666',
    marginBottom: 8,
  },
  totalAmount: {
    fontSize: 32,
    fontWeight: 'bold',
    color: '#10b981',
  },
  payButton: {
    width: '100%',
    backgroundColor: '#10b981',
    padding: 16,
    borderRadius: 8,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
    marginBottom: 12,
  },
  payButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
  laterButton: {
    padding: 12,
  },
  laterButtonText: {
    color: '#666',
    fontSize: 14,
  },
});
