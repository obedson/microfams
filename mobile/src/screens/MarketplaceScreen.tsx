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

export default function MarketplaceScreen({ navigation }: any) {
  const [products, setProducts] = useState([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchProducts = async () => {
    try {
      const response = await apiClient.get('/products');
      setProducts(response.data.data || response.data);
    } catch (error) {
      console.error('Error fetching products:', error);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  useEffect(() => {
    fetchProducts();
  }, []);

  const onRefresh = () => {
    setRefreshing(true);
    fetchProducts();
  };

  const renderProduct = ({ item }: any) => (
    <TouchableOpacity
      style={styles.card}
      onPress={() => navigation.navigate('ProductDetail', { id: item.id })}
    >
      <Image
        source={{ uri: (item.images && item.images[0]) || 'https://via.placeholder.com/150' }}
        style={styles.image}
      />
      <View style={styles.cardContent}>
        <Text style={styles.title} numberOfLines={2}>{item.name}</Text>
        <Text style={styles.category}>{item.category}</Text>
        <View style={styles.priceRow}>
          <Text style={styles.price}>₦{item.price}</Text>
          <View style={styles.stockBadge}>
            <Text style={styles.stockText}>{item.stock_quantity} in stock</Text>
          </View>
        </View>
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
        <Text style={styles.headerTitle}>Marketplace</Text>
      </View>
      <FlatList
        data={products}
        renderItem={renderProduct}
        keyExtractor={(item: any) => item.id}
        numColumns={2}
        contentContainerStyle={styles.list}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
        }
        ListEmptyComponent={
          <Text style={styles.empty}>No products available</Text>
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
    padding: 12,
  },
  card: {
    flex: 1,
    backgroundColor: '#fff',
    borderRadius: 12,
    margin: 4,
    overflow: 'hidden',
    elevation: 2,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 4,
  },
  image: {
    width: '100%',
    height: 150,
    backgroundColor: '#e5e7eb',
  },
  cardContent: {
    padding: 12,
  },
  title: {
    fontSize: 14,
    fontWeight: '600',
    marginBottom: 4,
    height: 36,
  },
  category: {
    fontSize: 12,
    color: '#10b981',
    marginBottom: 8,
    textTransform: 'capitalize',
  },
  priceRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  price: {
    fontSize: 16,
    fontWeight: 'bold',
    color: '#111',
  },
  stockBadge: {
    backgroundColor: '#f0fdf4',
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 8,
  },
  stockText: {
    fontSize: 10,
    color: '#10b981',
  },
  empty: {
    textAlign: 'center',
    color: '#666',
    marginTop: 40,
  },
});
