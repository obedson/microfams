import React, { useState, useEffect, useMemo } from 'react';
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  TouchableOpacity,
  ActivityIndicator,
  RefreshControl,
  Alert,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import apiClient from '../api/client';
import BookingCard from '../components/BookingCard';

type TabType = 'upcoming' | 'past' | 'cancelled';

export default function MyBookingsScreen({ navigation }: any) {
  const [bookings, setBookings] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [activeTab, setActiveTab] = useState<TabType>('upcoming');

  const fetchBookings = async () => {
    try {
      const response = await apiClient.get('/bookings/my-bookings');
      setBookings(response.data.data || response.data);
    } catch (error) {
      console.error('Error fetching bookings:', error);
      Alert.alert('Error', 'Failed to fetch bookings');
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  useEffect(() => {
    fetchBookings();
  }, []);

  const onRefresh = () => {
    setRefreshing(true);
    fetchBookings();
  };

  const handleCancel = (booking: any) => {
    Alert.alert(
      'Cancel Booking',
      'Are you sure you want to cancel this booking?',
      [
        { text: 'No', style: 'cancel' },
        { 
          text: 'Yes, Cancel', 
          style: 'destructive',
          onPress: async () => {
            try {
              setLoading(true);
              await apiClient.post(`/bookings/${booking.id}/cancel`);
              Alert.alert('Success', 'Booking cancelled successfully');
              fetchBookings();
            } catch (error: any) {
              const message = error.response?.data?.error || 'Failed to cancel booking';
              Alert.alert('Error', message);
            } finally {
              setLoading(false);
            }
          }
        }
      ]
    );
  };

  const handleRetryPayment = (booking: any) => {
    navigation.navigate('Payment', { bookingId: booking.id });
  };

  const filteredBookings = useMemo(() => {
    const now = new Date();
    return bookings.filter((booking: any) => {
      const endDate = new Date(booking.end_date);
      if (activeTab === 'cancelled') {
        return booking.status === 'cancelled';
      }
      if (activeTab === 'past') {
        return booking.status === 'completed' || (booking.status !== 'cancelled' && endDate < now);
      }
      if (activeTab === 'upcoming') {
        return booking.status !== 'cancelled' && booking.status !== 'completed' && endDate >= now;
      }
      return true;
    });
  }, [bookings, activeTab]);

  if (loading && !refreshing) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color="#10b981" />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.headerTitle}>My Bookings</Text>
      </View>

      <View style={styles.tabContainer}>
        {(['upcoming', 'past', 'cancelled'] as TabType[]).map((tab) => (
          <TouchableOpacity
            key={tab}
            style={[styles.tab, activeTab === tab && styles.activeTab]}
            onPress={() => setActiveTab(tab)}
          >
            <Text style={[styles.tabText, activeTab === tab && styles.activeTabText]}>
              {tab.charAt(0).toUpperCase() + tab.slice(1)}
            </Text>
          </TouchableOpacity>
        ))}
      </View>

      <FlatList
        data={filteredBookings}
        renderItem={({ item }) => (
          <BookingCard
            booking={item}
            onPress={() => navigation.navigate('BookingDetail', { id: item.id })}
            onCancel={
              (item.status === 'pending' || item.status === 'confirmed') 
                ? () => handleCancel(item) 
                : undefined
            }
            onRetryPayment={
              (item.status === 'pending_payment' && item.payment_status !== 'paid')
                ? () => handleRetryPayment(item)
                : undefined
            }
          />
        )}
        keyExtractor={(item: any) => item.id}
        contentContainerStyle={styles.list}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor="#10b981" />
        }
        ListEmptyComponent={
          <View style={styles.empty}>
            <Ionicons name="calendar-outline" size={64} color="#d1d5db" />
            <Text style={styles.emptyText}>No {activeTab} bookings found</Text>
            {activeTab === 'upcoming' && (
              <TouchableOpacity
                style={styles.browseButton}
                onPress={() => navigation.navigate('Properties')}
              >
                <Text style={styles.browseButtonText}>Browse Properties</Text>
              </TouchableOpacity>
            )}
          </View>
        }
      />
    </View>
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
    paddingTop: 60,
  },
  headerTitle: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#111827',
  },
  tabContainer: {
    flexDirection: 'row',
    backgroundColor: '#fff',
    borderBottomWidth: 1,
    borderBottomColor: '#e5e7eb',
    paddingHorizontal: 16,
  },
  tab: {
    flex: 1,
    paddingVertical: 12,
    alignItems: 'center',
    borderBottomWidth: 2,
    borderBottomColor: 'transparent',
  },
  activeTab: {
    borderBottomColor: '#10b981',
  },
  tabText: {
    fontSize: 14,
    fontWeight: '500',
    color: '#6b7280',
  },
  activeTabText: {
    color: '#10b981',
  },
  list: {
    padding: 16,
    paddingBottom: 32,
  },
  empty: {
    alignItems: 'center',
    marginTop: 60,
  },
  emptyText: {
    fontSize: 16,
    color: '#6b7280',
    marginTop: 16,
    marginBottom: 24,
  },
  browseButton: {
    backgroundColor: '#10b981',
    paddingHorizontal: 24,
    paddingVertical: 12,
    borderRadius: 8,
  },
  browseButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});
