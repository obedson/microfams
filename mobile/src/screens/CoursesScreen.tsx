import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  FlatList,
  TouchableOpacity,
  ActivityIndicator,
  RefreshControl,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import apiClient from '../api/client';

export default function CoursesScreen({ navigation }: any) {
  const [courses, setCourses] = useState([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);

  const fetchCourses = async () => {
    try {
      const response = await apiClient.get('/courses');
      setCourses(response.data.data || response.data);
    } catch (error) {
      console.error('Error fetching courses:', error);
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  };

  useEffect(() => {
    fetchCourses();
  }, []);

  const onRefresh = () => {
    setRefreshing(true);
    fetchCourses();
  };

  const renderCourse = ({ item }: any) => (
    <TouchableOpacity
      style={styles.card}
      onPress={() => navigation.navigate('CourseDetail', { id: item.id })}
    >
      <View style={styles.iconContainer}>
        <Ionicons name="book" size={32} color="#10b981" />
      </View>
      <View style={styles.cardContent}>
        <Text style={styles.title}>{item.title}</Text>
        <Text style={styles.description} numberOfLines={2}>
          {item.description}
        </Text>
        <View style={styles.footer}>
          <View style={styles.row}>
            <Ionicons name="time-outline" size={16} color="#666" />
            <Text style={styles.duration}>{item.duration}</Text>
          </View>
          <View style={styles.levelBadge}>
            <Text style={styles.levelText}>{item.level}</Text>
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
        <Text style={styles.headerTitle}>Courses</Text>
      </View>
      <FlatList
        data={courses}
        renderItem={renderCourse}
        keyExtractor={(item: any) => item.id}
        contentContainerStyle={styles.list}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={onRefresh} />
        }
        ListEmptyComponent={
          <View style={styles.empty}>
            <Ionicons name="book-outline" size={64} color="#d1d5db" />
            <Text style={styles.emptyText}>No courses available</Text>
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
    padding: 16,
    marginBottom: 12,
    flexDirection: 'row',
    elevation: 2,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 4,
  },
  iconContainer: {
    width: 64,
    height: 64,
    borderRadius: 32,
    backgroundColor: '#f0fdf4',
    justifyContent: 'center',
    alignItems: 'center',
    marginRight: 16,
  },
  cardContent: {
    flex: 1,
  },
  title: {
    fontSize: 16,
    fontWeight: '600',
    marginBottom: 8,
  },
  description: {
    fontSize: 14,
    color: '#666',
    marginBottom: 12,
  },
  footer: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  duration: {
    fontSize: 14,
    color: '#666',
    marginLeft: 4,
  },
  levelBadge: {
    backgroundColor: '#f0fdf4',
    paddingHorizontal: 12,
    paddingVertical: 4,
    borderRadius: 12,
  },
  levelText: {
    fontSize: 12,
    color: '#10b981',
    fontWeight: '600',
    textTransform: 'capitalize',
  },
  empty: {
    alignItems: 'center',
    marginTop: 60,
  },
  emptyText: {
    fontSize: 16,
    color: '#666',
    marginTop: 16,
  },
});
