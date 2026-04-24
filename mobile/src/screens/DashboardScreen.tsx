import React, { useState, useEffect } from 'react';
import { View, Text, StyleSheet, TouchableOpacity, ScrollView, RefreshControl, ActivityIndicator } from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useAuthStore } from '../store/authStore';
import apiClient from '../api/client';

export default function DashboardScreen({ navigation }: any) {
  const { user, logout } = useAuthStore();
  const [stats, setStats] = useState<any>(null);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchStats = async () => {
    try {
      const response = await apiClient.get('/analytics/dashboard');
      setStats(response.data.data || response.data);
    } catch (error) {
      console.error('Error fetching stats:', error);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  useEffect(() => {
    fetchStats();
  }, []);

  const onRefresh = () => {
    setRefreshing(true);
    fetchStats();
  };

  const menuItems = [
    {
      icon: 'calendar',
      title: 'My Bookings',
      description: 'View and manage your bookings',
      onPress: () => navigation.navigate('MyBookings'),
    },
    {
      icon: 'document-text',
      title: 'Farm Records',
      description: 'Track your farming activities',
      onPress: () => navigation.navigate('FarmRecords'),
    },
    {
      icon: 'school',
      title: 'My Courses',
      description: 'Access your learning materials',
      onPress: () => navigation.navigate('Courses'),
    },
    {
      icon: 'add-circle',
      title: 'Sell Products',
      description: 'Add products to marketplace',
      onPress: () => navigation.navigate('AddProduct'),
    },
  ];

  return (
    <ScrollView 
      style={styles.container}
      refreshControl={
        <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor="#10b981" />
      }
    >
      <View style={styles.header}>
        <View style={styles.avatar}>
          <Text style={styles.avatarText}>{user?.name?.charAt(0)}</Text>
        </View>
        <Text style={styles.name}>{user?.name}</Text>
        <Text style={styles.email}>{user?.email}</Text>
        <View style={styles.roleBadge}>
          <Text style={styles.roleText}>{user?.role}</Text>
        </View>
      </View>

      <View style={styles.statsContainer}>
        <Text style={styles.sectionTitle}>Overview</Text>
        {loading && !refreshing ? (
          <ActivityIndicator color="#10b981" style={{ marginVertical: 20 }} />
        ) : (
          <View style={styles.statsGrid}>
            <View style={styles.statCard}>
              <Text style={styles.statValue}>{stats?.total_bookings || 0}</Text>
              <Text style={styles.statLabel}>Total Bookings</Text>
            </View>
            <View style={styles.statCard}>
              <Text style={styles.statValue}>{stats?.confirmed_bookings || 0}</Text>
              <Text style={styles.statLabel}>Confirmed</Text>
            </View>
            <View style={styles.statCard}>
              <Text style={styles.statValue}>₦{(stats?.total_spent || stats?.total_revenue || 0).toLocaleString()}</Text>
              <Text style={styles.statLabel}>{user?.role === 'owner' ? 'Revenue' : 'Total Spent'}</Text>
            </View>
            <View style={styles.statCard}>
              <Text style={[styles.statValue, { color: '#f97316' }]}>{stats?.pending_payment || 0}</Text>
              <Text style={styles.statLabel}>Pending Pay</Text>
            </View>
          </View>
        )}
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Quick Actions</Text>
        {menuItems.map((item, index) => (
          <TouchableOpacity
            key={index}
            style={styles.menuItem}
            onPress={item.onPress}
          >
            <View style={styles.menuIcon}>
              <Ionicons name={item.icon as any} size={24} color="#10b981" />
            </View>
            <View style={styles.menuContent}>
              <Text style={styles.menuTitle}>{item.title}</Text>
              <Text style={styles.menuDescription}>{item.description}</Text>
            </View>
            <Ionicons name="chevron-forward" size={20} color="#9ca3af" />
          </TouchableOpacity>
        ))}
      </View>

      <TouchableOpacity style={styles.logoutButton} onPress={logout}>
        <Ionicons name="log-out-outline" size={20} color="#fff" />
        <Text style={styles.logoutText}>Logout</Text>
      </TouchableOpacity>
      
      <View style={{ height: 40 }} />
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f9fafb',
  },
  header: {
    backgroundColor: '#fff',
    padding: 20,
    paddingTop: 60,
    alignItems: 'center',
    borderBottomWidth: 1,
    borderBottomColor: '#e5e7eb',
  },
  avatar: {
    width: 80,
    height: 80,
    borderRadius: 40,
    backgroundColor: '#10b981',
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 16,
  },
  avatarText: {
    fontSize: 32,
    fontWeight: 'bold',
    color: '#fff',
  },
  name: {
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 4,
    color: '#111827',
  },
  email: {
    fontSize: 14,
    color: '#6b7280',
    marginBottom: 12,
  },
  roleBadge: {
    backgroundColor: '#f0fdf4',
    paddingHorizontal: 16,
    paddingVertical: 6,
    borderRadius: 16,
  },
  roleText: {
    color: '#10b981',
    fontSize: 14,
    fontWeight: '600',
    textTransform: 'capitalize',
  },
  statsContainer: {
    padding: 16,
    paddingBottom: 0,
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#374151',
    marginBottom: 12,
  },
  statsGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 12,
  },
  statCard: {
    backgroundColor: '#fff',
    width: '48%',
    padding: 16,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: '#e5e7eb',
    alignItems: 'center',
  },
  statValue: {
    fontSize: 18,
    fontWeight: 'bold',
    color: '#111827',
    marginBottom: 4,
  },
  statLabel: {
    fontSize: 12,
    color: '#6b7280',
  },
  section: {
    padding: 16,
  },
  menuItem: {
    backgroundColor: '#fff',
    padding: 16,
    borderRadius: 12,
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 12,
    borderWidth: 1,
    borderColor: '#e5e7eb',
  },
  menuIcon: {
    width: 44,
    height: 44,
    backgroundColor: '#f0fdf4',
    borderRadius: 22,
    justifyContent: 'center',
    alignItems: 'center',
    marginRight: 16,
  },
  menuContent: {
    flex: 1,
  },
  menuTitle: {
    fontSize: 16,
    fontWeight: '600',
    color: '#111827',
    marginBottom: 2,
  },
  menuDescription: {
    fontSize: 13,
    color: '#6b7280',
  },
  logoutButton: {
    backgroundColor: '#ef4444',
    margin: 16,
    padding: 16,
    borderRadius: 12,
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 8,
  },
  logoutText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});
