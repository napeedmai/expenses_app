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

  // PUSH NOTIFICATIONS ARE DISABLED IN THIS RELEASE.
  //
  // usePushNotifications() used to run here. Delivery has never worked: sending
  // requires an outbound HTTPS call from Oracle to exp.host, which needs a TLS
  // wallet that has been an open DBA request since July (db/DBA_REQUEST_push_
  // wallet.md). Shipping the permission prompt for something that then delivers
  // nothing is a poor first impression, and app stores do query permissions an
  // app never uses.
  //
  // src/pushNotifications.js is kept, unimported. It holds the parts that were
  // genuinely hard to get right -- the SDK 53 shouldShowBanner/shouldShowList
  // rename, and the fact that an Android channel's importance is frozen at
  // creation -- and none of that is worth rediscovering.
  //
  // To turn it back on: restore the import and this call, put back the
  // expo-notifications plugin and POST_NOTIFICATIONS in app.json, reinstall the
  // package, and rebuild. Email notifications are unaffected and still work.

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