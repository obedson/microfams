import React, { useState, useEffect } from 'react';
import {
  View,
  Text,
  StyleSheet,
  ScrollView,
  TouchableOpacity,
  ActivityIndicator,
  Alert,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import apiClient from '../api/client';

export default function CourseDetailScreen({ route, navigation }: any) {
  const { id } = route.params;
  const [course, setCourse] = useState<any>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    fetchCourse();
  }, []);

  const fetchCourse = async () => {
    try {
      const response = await apiClient.get(`/courses/${id}`);
      setCourse(response.data.data || response.data);
    } catch (error) {
      console.error('Error fetching course:', error);
      Alert.alert('Error', 'Failed to load course details');
    } finally {
      setLoading(false);
    }
  };

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color="#10b981" />
      </View>
    );
  }

  if (!course) {
    return (
      <View style={styles.center}>
        <Text>Course not found</Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity onPress={() => navigation.goBack()} style={styles.backButton}>
          <Ionicons name="arrow-back" size={24} color="#111" />
        </TouchableOpacity>
        <Text style={styles.headerTitle}>Course Details</Text>
      </View>

      <ScrollView style={styles.content}>
        <View style={styles.iconContainer}>
          <Ionicons name="book" size={64} color="#10b981" />
        </View>

        <Text style={styles.title}>{course.title}</Text>

        <View style={styles.metaRow}>
          <View style={styles.metaItem}>
            <Ionicons name="time-outline" size={20} color="#666" />
            <Text style={styles.metaText}>{course.duration}</Text>
          </View>
          <View style={styles.levelBadge}>
            <Text style={styles.levelText}>{course.level}</Text>
          </View>
        </View>

        <View style={styles.section}>
          <Text style={styles.sectionTitle}>Description</Text>
          <Text style={styles.description}>{course.description}</Text>
        </View>

        {course.content && (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Course Content</Text>
            <Text style={styles.description}>{course.content}</Text>
          </View>
        )}
      </ScrollView>

      <View style={styles.footer}>
        <TouchableOpacity style={styles.enrollButton}>
          <Text style={styles.enrollButtonText}>Enroll Now</Text>
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
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: 20,
    paddingTop: 60,
    borderBottomWidth: 1,
    borderBottomColor: '#e5e7eb',
  },
  backButton: {
    marginRight: 16,
  },
  headerTitle: {
    fontSize: 18,
    fontWeight: '600',
  },
  content: {
    flex: 1,
    padding: 20,
  },
  iconContainer: {
    width: 120,
    height: 120,
    borderRadius: 60,
    backgroundColor: '#f0fdf4',
    justifyContent: 'center',
    alignItems: 'center',
    alignSelf: 'center',
    marginBottom: 24,
  },
  title: {
    fontSize: 24,
    fontWeight: 'bold',
    marginBottom: 16,
    textAlign: 'center',
  },
  metaRow: {
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    marginBottom: 24,
    gap: 16,
  },
  metaItem: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  metaText: {
    fontSize: 16,
    color: '#666',
  },
  levelBadge: {
    backgroundColor: '#f0fdf4',
    paddingHorizontal: 16,
    paddingVertical: 6,
    borderRadius: 16,
  },
  levelText: {
    fontSize: 14,
    color: '#10b981',
    fontWeight: '600',
    textTransform: 'capitalize',
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
  footer: {
    padding: 16,
    borderTopWidth: 1,
    borderTopColor: '#e5e7eb',
  },
  enrollButton: {
    backgroundColor: '#10b981',
    padding: 16,
    borderRadius: 8,
    alignItems: 'center',
  },
  enrollButtonText: {
    color: '#fff',
    fontSize: 16,
    fontWeight: '600',
  },
});
