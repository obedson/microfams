import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  ActivityIndicator,
  Alert,
  Linking,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import apiClient from '../api/client';
import BookingStatusTimeline from '../components/BookingStatusTimeline';

export default function BookingDetailScreen({ route, navigation }: any) {
  const { id } = route.params;
  const [booking, setBooking] = useState<any>(null);
  const [loading, setLoading] = useState(true);

  const fetchBookingDetail = async () => {
    try {
      const response = await apiClient.get(`/bookings/${id}`);
      setBooking(response.data.data || response.data);
    } catch (error) {
      console.error('Error fetching booking detail:', error);
      Alert.alert('Error', 'Failed to fetch booking details');
      navigation.goBack();
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    fetchBookingDetail();
  }, [id]);

  const handleDownloadReceipt = async () => {
    try {
      const apiUrl = 'http://10.148.47.234:3001/api'; // Use same IP as client.ts
      const downloadUrl = `${apiUrl}/receipts/${id}/download`;
      // In a real mobile app, we might use expo-file-system and expo-sharing
      // For now, we'll open in browser
      Linking.openURL(downloadUrl);
    } catch (error) {
      console.error('Error downloading receipt:', error);
      Alert.alert('Error', 'Failed to download receipt');
    }
  };

  const handleContact = (type: 'email' | 'phone') => {
    const owner = booking.properties?.users;
    if (!owner) return;

    if (type === 'email' && owner.email) {
      const subject = `Booking #${booking.id?.slice(-8).toUpperCase()} - ${booking.properties.title}`;
      Linking.openURL(`mailto:${owner.email}?subject=${encodeURIComponent(subject)}`);
    } else if (type === 'phone' && owner.phone) {
      Linking.openURL(`tel:${owner.phone}`);
    }
  };

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color="#10b981" />
      </View>
    );
  }

  if (!booking) return null;

  const reference = booking.id?.slice(-8)?.toUpperCase();

  return (
    <ScrollView style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.propertyTitle}>{booking.properties?.title}</Text>
        <Text style={styles.reference}>Reference: #{reference}</Text>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Status Progress</Text>
        <View style={styles.timelineWrapper}>
          <BookingStatusTimeline status={booking.status} paymentStatus={booking.payment_status} />
        </View>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Booking Details</Text>
        <View style={styles.infoRow}>
          <View style={styles.infoItem}>
            <Text style={styles.infoLabel}>Check-in</Text>
            <Text style={styles.infoValue}>{new Date(booking.start_date).toLocaleDateString()}</Text>
          </View>
          <View style={styles.infoItem}>
            <Text style={styles.infoLabel}>Check-out</Text>
            <Text style={styles.infoValue}>{new Date(booking.end_date).toLocaleDateString()}</Text>
          </View>
        </View>
        <View style={styles.infoItem}>
          <Text style={styles.infoLabel}>Total Amount</Text>
          <Text style={styles.amountValue}>₦{booking.total_amount?.toLocaleString()}</Text>
        </View>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Location</Text>
        <View style={styles.detailRow}>
          <Ionicons name="location-outline" size={20} color="#10b981" />
          <Text style={styles.detailText}>
            {booking.properties?.address}, {booking.properties?.city}, {booking.properties?.lga}, {booking.properties?.state}
          </Text>
        </View>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Property Owner</Text>
        <View style={styles.ownerCard}>
          <View style={styles.ownerInfo}>
            <Ionicons name="person-circle-outline" size={40} color="#10b981" />
            <View>
              <Text style={styles.ownerName}>{booking.properties?.users?.name}</Text>
              <Text style={styles.ownerRole}>Host</Text>
            </View>
          </View>
          <View style={styles.contactActions}>
            <TouchableOpacity style={styles.contactButton} onPress={() => handleContact('email')}>
              <Ionicons name="mail-outline" size={20} color="#10b981" />
              <Text style={styles.contactButtonText}>Email</Text>
            </TouchableOpacity>
            <TouchableOpacity style={styles.contactButton} onPress={() => handleContact('phone')}>
              <Ionicons name="call-outline" size={20} color="#10b981" />
              <Text style={styles.contactButtonText}>Call</Text>
            </TouchableOpacity>
          </View>
        </View>
      </View>

      {booking.payment_status === 'paid' && (
        <TouchableOpacity style={styles.receiptButton} onPress={handleDownloadReceipt}>
          <Ionicons name="document-text-outline" size={24} color="#fff" />
          <Text style={styles.receiptButtonText}>Download Payment Receipt</Text>
        </TouchableOpacity>
      )}

      {booking.status === 'pending_payment' && (
        <TouchableOpacity 
          style={styles.payButton}
          onPress={() => navigation.navigate('Payment', { bookingId: booking.id })}
        >
          <Text style={styles.payButtonText}>Complete Payment</Text>
        </TouchableOpacity>
      )}

      <View style={{ height: 40 }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f9fafb',
  },
  center: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  header: {
    backgroundColor: '#fff',
    padding: 20,
    borderBottomWidth: 1,
    borderBottomColor: '#e5e7eb',
  },
  propertyTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#111827',
  },
  reference: {
    fontSize: 14,
    color: '#6b7280',
    marginTop: 4,
    fontFamily: 'monospace',
  },
  section: {
    backgroundColor: '#fff',
    marginTop: 12,
    padding: 20,
    borderTopWidth: 1,
    borderBottomWidth: 1,
    borderColor: '#e5e7eb',
  },
  sectionTitle: {
    fontSize: 16,
    fontWeight: '600',
    color: '#374151',
    marginBottom: 16,
  },
  timelineWrapper: {
    paddingBottom: 30,
  },
  infoRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 16,
  },
  infoItem: {
    flex: 1,
  },
  infoLabel: {
    fontSize: 12,
    color: '#6b7280',
    marginBottom: 4,
  },
  infoValue: {
    fontSize: 15,
    fontWeight: '500',
    color: '#111827',
  },
  amountValue: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#10b981',
  },
  detailRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 12,
  },
  detailText: {
    fontSize: 14,
    color: '#4b5563',
    lineHeight: 20,
    flex: 1,
  },
  ownerCard: {
    backgroundColor: '#f3f4f6',
    borderRadius: 12,
    padding: 16,
  },
  ownerInfo: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    marginBottom: 16,
  },
  ownerName: {
    fontSize: 16,
    fontWeight: '600',
    color: '#111827',
  },
  ownerRole: {
    fontSize: 12,
    color: '#6b7280',
  },
  contactActions: {
    flexDirection: 'row',
    gap: 12,
  },
  contactButton: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: '#fff',
    paddingVertical: 10,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: '#e5e7eb',
  },
  contactButtonText: {
    fontSize: 14,
    fontWeight: '600',
    color: '#374151',
  },
  receiptButton: {
    backgroundColor: '#3b82f6',
    margin: 20,
    padding: 16,
    borderRadius: 12,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 12,
  },
  receiptButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: 'bold',
  },
  payButton: {
    backgroundColor: '#10b981',
    margin: 20,
    marginTop: 0,
    padding: 16,
    borderRadius: 12,
    alignItems: 'center',
  },
  payButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: 'bold',
  },
});
