import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  Image,
  TouchableOpacity,
  ActivityIndicator,
  RefreshControl,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import apiClient from '../api/client';

export default function PropertiesScreen({ navigation }: any) {
  const [properties, setProperties] = useState([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchProperties = async () => {
    try {
      const response = await apiClient.get('/properties');
      setProperties(response.data.data || response.data);
    } catch (error) {
      console.error('Error fetching properties:', error);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  useEffect(() => {
    fetchProperties();
  }, []);

  const onRefresh = () => {
    setRefreshing(true);
    fetchProperties();
  };

  const renderProperty = ({ item }: any) => (
    <TouchableOpacity
      style={styles.card}
      onPress={() => navigation.navigate('PropertyDetail', { id: item.id })}
    >
      <Image
        source={{ uri: item.images?.[0] || 'https://via.placeholder.com/300x200' }}
        style={styles.image}
      />
      <View style={styles.cardContent}>
        <Text style={styles.title} numberOfLines={1}>{item.title}</Text>
        <View style={styles.row}>
          <Ionicons name="location-outline" size={16} color="#666" />
          <Text style={styles.location}>{item.location}</Text>
        </View>
        <View style={styles.row}>
          <Text style={styles.type}>{item.property_type}</Text>
          <Text style={styles.price}>₦{item.price_per_month}/month</Text>
        </View>
        <Text style={styles.size}>{item.size_sqm} sqm</Text>
      </View>
    </TouchableOpacity>
  );

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color="#10b981" />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.headerTitle}>Properties</Text>
      </View>
      <FlatList
        data={properties}
        renderItem={renderProperty}
        keyExtractor={(item: any) => item.id}
        contentContainerStyle={styles.list}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
        }
        ListEmptyComponent={
          <Text style={styles.empty}>No properties available</Text>
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
    borderBottomWidth: 1,
    borderBottomColor: '#e5e7eb',
  },
  headerTitle: {
    fontSize: 24,
    fontWeight: 'bold',
  },
  list: {
    padding: 16,
  },
  card: {
    backgroundColor: '#fff',
    borderRadius: 12,
    marginBottom: 16,
    overflow: 'hidden',
    elevation: 2,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 4,
  },
  image: {
    width: '100%',
    height: 200,
    backgroundColor: '#e5e7eb',
  },
  cardContent: {
    padding: 16,
  },
  title: {
    fontSize: 18,
    fontWeight: '600',
    marginBottom: 8,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 4,
  },
  location: {
    fontSize: 14,
    color: '#666',
    marginLeft: 4,
  },
  type: {
    fontSize: 14,
    color: '#10b981',
    fontWeight: '500',
    flex: 1,
  },
  price: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#111',
  },
  size: {
    fontSize: 14,
    color: '#666',
    marginTop: 4,
  },
  empty: {
    textAlign: 'center',
    color: '#666',
    marginTop: 40,
  },
});

