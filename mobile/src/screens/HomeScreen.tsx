import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  Image,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useAuthStore } from '../store/authStore';
import apiClient from '../api/client';

export default function HomeScreen({ navigation }: any) {
  const user = useAuthStore((state) => state.user);
  const [stats, setStats] = useState({ properties: 0, bookings: 0 });

  useEffect(() => {
    fetchStats();
  }, []);

  const fetchStats = async () => {
    try {
      const [propertiesRes, bookingsRes] = await Promise.all([
        apiClient.get('/properties'),
        apiClient.get('/bookings/my-bookings'),
      ]);
      setStats({
        properties: propertiesRes.data.data?.length || 0,
        bookings: bookingsRes.data.data?.length || 0,
      });
    } catch (error) {
      console.error('Error fetching stats:', error);
    }
  };

  const features = [
    {
      icon: 'search',
      title: 'Browse Properties',
      description: 'Find the perfect space for your livestock',
      onPress: () => navigation.navigate('Properties'),
    },
    {
      icon: 'cart',
      title: 'Marketplace',
      description: 'Buy farming supplies and equipment',
      onPress: () => navigation.navigate('Marketplace'),
    },
    {
      icon: 'book',
      title: 'Courses',
      description: 'Learn new farming techniques',
      onPress: () => navigation.navigate('Courses'),
    },
    {
      icon: 'document-text',
      title: 'Farm Records',
      description: 'Track your farming activities',
      onPress: () => navigation.navigate('FarmRecords'),
    },
  ];

  return (
    <ScrollView style={styles.container}>
      <View style={styles.header}>
        <View>
          <Text style={styles.greeting}>Welcome back,</Text>
          <Text style={styles.name}>{user?.name}!</Text>
        </View>
        <View style={styles.logo}>
          <Text style={styles.logoText}>MF</Text>
        </View>
      </View>

      <View style={styles.statsContainer}>
        <View style={styles.statCard}>
          <Ionicons name="home" size={32} color="#10b981" />
          <Text style={styles.statNumber}>{stats.properties}</Text>
          <Text style={styles.statLabel}>Properties</Text>
        </View>
        <View style={styles.statCard}>
          <Ionicons name="calendar" size={32} color="#10b981" />
          <Text style={styles.statNumber}>{stats.bookings}</Text>
          <Text style={styles.statLabel}>My Bookings</Text>
        </View>
      </View>

      <View style={styles.section}>
        <Text style={styles.sectionTitle}>Quick Actions</Text>
        {features.map((feature, index) => (
          <TouchableOpacity
            key={index}
            style={styles.featureCard}
            onPress={feature.onPress}
          >
            <View style={styles.featureIcon}>
              <Ionicons name={feature.icon as any} size={24} color="#10b981" />
            </View>
            <View style={styles.featureContent}>
              <Text style={styles.featureTitle}>{feature.title}</Text>
              <Text style={styles.featureDescription}>{feature.description}</Text>
            </View>
            <Ionicons name="chevron-forward" size={20} color="#9ca3af" />
          </TouchableOpacity>
        ))}
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f9fafb',
  },
  header: {
    backgroundColor: '#10b981',
    padding: 20,
    paddingTop: 60,
    paddingBottom: 30,
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  greeting: {
    fontSize: 16,
    color: '#fff',
    opacity: 0.9,
  },
  name: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#fff',
    marginTop: 4,
  },
  logo: {
    width: 50,
    height: 50,
    backgroundColor: '#fff',
    borderRadius: 25,
    justifyContent: 'center',
    alignItems: 'center',
  },
  logoText: {
    fontSize: 20,
    fontWeight: 'bold',
    color: '#10b981',
  },
  statsContainer: {
    flexDirection: 'row',
    padding: 16,
    gap: 16,
  },
  statCard: {
    flex: 1,
    backgroundColor: '#fff',
    padding: 20,
    borderRadius: 12,
    alignItems: 'center',
    elevation: 2,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 4,
  },
  statNumber: {
    fontSize: 28,
    fontWeight: 'bold',
    marginTop: 8,
  },
  statLabel: {
    fontSize: 14,
    color: '#666',
    marginTop: 4,
  },
  section: {
    padding: 16,
  },
  sectionTitle: {
    fontSize: 20,
    fontWeight: 'bold',
    marginBottom: 16,
  },
  featureCard: {
    backgroundColor: '#fff',
    padding: 16,
    borderRadius: 12,
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 12,
    elevation: 2,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 4,
  },
  featureIcon: {
    width: 48,
    height: 48,
    backgroundColor: '#f0fdf4',
    borderRadius: 24,
    justifyContent: 'center',
    alignItems: 'center',
    marginRight: 16,
  },
  featureContent: {
    flex: 1,
  },
  featureTitle: {
    fontSize: 16,
    fontWeight: '600',
    marginBottom: 4,
  },
  featureDescription: {
    fontSize: 14,
    color: '#666',
  },
});
