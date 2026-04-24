import React, { useEffect } from 'react';
import { StatusBar } from 'expo-status-bar';
import AppNavigator from './src/navigation/AppNavigator';
import { useAuthStore } from './src/store/authStore';

export default function App() {
  const loadUser = useAuthStore((state) => state.loadUser);

  useEffect(() => {
    loadUser();
  }, []);

  return (
    <>
      <StatusBar style="auto" />
      <AppNavigator />
    </>
  );
}
