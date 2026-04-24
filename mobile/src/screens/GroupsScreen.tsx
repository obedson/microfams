import React, { useState, useEffect } from 'react';
import { View, Text, FlatList, TouchableOpacity, StyleSheet } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import apiClient from '../api/client';

export default function GroupsScreen() {
  const [groups, setGroups] = useState([]);
  const [loading, setLoading] = useState(true);
  const navigation = useNavigation();

  useEffect(() => {
    fetchGroups();
  }, []);

  const fetchGroups = async () => {
    try {
      const { data } = await apiClient.get('/groups/search');
      setGroups(data);
    } catch (error) {
      console.error('Error fetching groups:', error);
    } finally {
      setLoading(false);
    }
  };

  const renderGroup = ({ item }) => (
    <TouchableOpacity
      style={styles.card}
      onPress={() => navigation.navigate('GroupDetail', { id: item.id })}
    >
      <Text style={styles.name}>{item.name}</Text>
      <Text style={styles.description}>{item.description}</Text>
      <View style={styles.footer}>
        <Text style={styles.members}>{item.member_count} members</Text>
        <Text style={styles.fee}>₦{item.entry_fee?.toLocaleString()}</Text>
      </View>
    </TouchableOpacity>
  );

  if (loading) return <View style={styles.center}><Text>Loading...</Text></View>;

  return (
    <View style={styles.container}>
      <FlatList
        data={groups}
        renderItem={renderGroup}
        keyExtractor={(item) => item.id}
        contentContainerStyle={styles.list}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: '#f5f5f5' },
  list: { padding: 16 },
  card: { backgroundColor: 'white', padding: 16, borderRadius: 8, marginBottom: 12 },
  name: { fontSize: 18, fontWeight: 'bold', marginBottom: 8 },
  description: { color: '#666', marginBottom: 12 },
  footer: { flexDirection: 'row', justifyContent: 'space-between' },
  members: { color: '#666' },
  fee: { fontWeight: 'bold', color: '#10b981' },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center' },
});
