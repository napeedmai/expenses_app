// This import MUST be the very first line in the file — react-navigation's
// gesture handling breaks on Android otherwise. This is a documented
// react-navigation/react-native-gesture-handler requirement, not optional
// boilerplate. (Kept even after moving from a drawer to bottom tabs —
// still required by react-navigation in general.)
import 'react-native-gesture-handler';

import React from 'react';
import { View, ActivityIndicator } from 'react-native';
import { NavigationContainer } from '@react-navigation/native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { SessionProvider, useSession } from './src/SessionContext';
import { ThemeProvider, useTheme } from './src/ThemeContext';
import { usePushNotifications } from './src/pushNotifications';
import LoginScreen from './src/screens/LoginScreen';
import MainTabs from './src/navigation/MainTabs';

export default function App() {
  return (
    // Needed for useSafeAreaInsets()/SafeAreaView (bottom tab bar, and the
    // top-spacing fix on Home/My Expenses/Approvals/Settings) to get real
    // device inset values instead of zeros.
    <SafeAreaProvider>
      <ThemeProvider>
        <SessionProvider>
          <Root />
        </SessionProvider>
      </ThemeProvider>
    </SafeAreaProvider>
  );
}

function Root() {
  const { session, loading } = useSession();
  const { colors } = useTheme();

  // Registers this device for real push notifications once a session
  // exists — see src/pushNotifications.js. Runs on every login/app-open;
  // it's a quick no-op if this device is already registered.
  usePushNotifications(session ? session.empId : null);

  if (loading) {
    return (
      <View style={{ flex: 1, justifyContent: 'center', alignItems: 'center', backgroundColor: colors.bg }}>
        <ActivityIndicator size="large" color={colors.primary} />
      </View>
    );
  }

  // No session → plain Login screen, no navigator needed at all.
  // Session exists → the whole tabbed app experience, inside its own
  // NavigationContainer. Logging in/out just flips which of these renders
  // (see src/SessionContext.js) — no manual navigation.reset() needed.
  if (!session) {
    return <LoginScreen />;
  }

  return (
    <NavigationContainer>
      <MainTabs />
    </NavigationContainer>
  );
}