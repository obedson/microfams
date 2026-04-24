import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  Image,
  TouchableOpacity,
  ActivityIndicator,
  Alert,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import apiClient from '../api/client';

export default function PropertyDetailScreen({ route, navigation }: any) {
  const { id } = route.params;
  const [property, setProperty] = useState<any>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetchProperty();
  }, []);

  const fetchProperty = async () => {
    try {
      const response = await apiClient.get(`/properties/${id}`);
      setProperty(response.data.data || response.data);
    } catch (error) {
      console.error('Error fetching property:', error);
      Alert.alert('Error', 'Failed to load property details');
    } finally {
      setLoading(false);
    }
  };

  const handleBooking = () => {
    navigation.navigate('CreateBooking', { propertyId: id, property });
  };

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color="#10b981" />
      </View>
    );
  }

  if (!property) {
    return (
      <View style={styles.center}>
        <Text>Property not found</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <ScrollView>
        <Image
          source={{ uri: property.images?.[0] || 'https://via.placeholder.com/400x300' }}
          style={styles.image}
        />
        <TouchableOpacity
          style={styles.backButton}
          onPress={() => navigation.goBack()}
        >
          <Ionicons name="arrow-back" size={24} color="#fff" />
        </TouchableOpacity>

        <View style={styles.content}>
          <Text style={styles.title}>{property.title}</Text>
          
          <View style={styles.row}>
            <Ionicons name="location" size={20} color="#10b981" />
            <Text style={styles.location}>{property.location}</Text>
          </View>

          <View style={styles.priceRow}>
            <Text style={styles.price}>₦{property.price_per_month}</Text>
            <Text style={styles.perMonth}>/month</Text>
          </View>

          <View style={styles.infoGrid}>
            <View style={styles.infoItem}>
              <Ionicons name="resize-outline" size={24} color="#10b981" />
              <Text style={styles.infoLabel}>Size</Text>
              <Text style={styles.infoValue}>{property.size_sqm} sqm</Text>
            </View>
            <View style={styles.infoItem}>
              <Ionicons name="home-outline" size={24} color="#10b981" />
              <Text style={styles.infoLabel}>Type</Text>
              <Text style={styles.infoValue}>{property.property_type}</Text>
            </View>
            <View style={styles.infoItem}>
              <Ionicons name="checkmark-circle-outline" size={24} color="#10b981" />
              <Text style={styles.infoLabel}>Status</Text>
              <Text style={styles.infoValue}>{property.status}</Text>
            </View>
          </View>

          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Description</Text>
            <Text style={styles.description}>{property.description}</Text>
          </View>

          {property.amenities && (
            <View style={styles.section}>
              <Text style={styles.sectionTitle}>Amenities</Text>
              <View style={styles.amenities}>
                {property.amenities.map((amenity: string, index: number) => (
                  <View key={index} style={styles.amenityTag}>
                    <Text style={styles.amenityText}>{amenity}</Text>
                  </View>
                ))}
              </View>
            </View>
          )}
        </View>
      </ScrollView>

      <View style={styles.footer}>
        <TouchableOpacity style={styles.bookButton} onPress={handleBooking}>
          <Text style={styles.bookButtonText}>Book Now</Text>
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
  center: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
  },
  image: {
    width: '100%',
    height: 300,
    backgroundColor: '#e5e7eb',
  },
  backButton: {
    position: 'absolute',
    top: 50,
    left: 16,
    width: 40,
    height: 40,
    borderRadius: 20,
    backgroundColor: 'rgba(0,0,0,0.5)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  content: {
    padding: 20,
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 12,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 16,
  },
  location: {
    fontSize: 16,
    color: '#666',
    marginLeft: 8,
  },
  priceRow: {
    flexDirection: 'row',
    alignItems: 'baseline',
    marginBottom: 24,
  },
  price: {
    fontSize: 32,
    fontWeight: 'bold',
    color: '#10b981',
  },
  perMonth: {
    fontSize: 16,
    color: '#666',
    marginLeft: 4,
  },
  infoGrid: {
    flexDirection: 'row',
    justifyContent: 'space-around',
    marginBottom: 24,
    paddingVertical: 16,
    backgroundColor: '#f9fafb',
    borderRadius: 12,
  },
  infoItem: {
    alignItems: 'center',
  },
  infoLabel: {
    fontSize: 12,
    color: '#666',
    marginTop: 4,
  },
  infoValue: {
    fontSize: 14,
    fontWeight: '600',
    marginTop: 2,
  },
  section: {
    marginBottom: 24,
  },
  sectionTitle: {
    fontSize: 18,
    fontWeight: '600',
    marginBottom: 12,
  },
  description: {
    fontSize: 16,
    color: '#666',
    lineHeight: 24,
  },
  amenities: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
  },
  amenityTag: {
    backgroundColor: '#e5e7eb',
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 16,
  },
  amenityText: {
    fontSize: 14,
    color: '#374151',
  },
  footer: {
    padding: 16,
    borderTopWidth: 1,
    borderTopColor: '#e5e7eb',
    backgroundColor: '#fff',
  },
  bookButton: {
    backgroundColor: '#10b981',
    padding: 16,
    borderRadius: 8,
    alignItems: 'center',
  },
  bookButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});
