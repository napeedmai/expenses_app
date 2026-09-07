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

  // PUSH NOTIFICATIONS HAVE BEEN REMOVED, CLIENT AND SERVER.
  //
  // usePushNotifications() used to run here. Delivery never worked: sending
  // requires an outbound HTTPS call from Oracle to exp.host, which needs a TLS
  // wallet that has been an open DBA request since July (db/DBA_REQUEST_push_
  // wallet.md). Shipping a permission prompt for something that then delivers
  // nothing is a poor first impression, and app stores do query permissions an
  // app never uses.
  //
  // db/84_drop_push.sql finished the job on the database side: SEND_PUSH_
  // NOTIFICATION, TEST_PUSH_NOTIFICATION and EMP_PUSH_TOKENS are dropped,
  // process_expense_action and the submit handler no longer call them, and
  // POST /expenses/push-token answers 410 Gone. src/pushNotifications.js and
  // registerPushToken are deleted -- git history has them if push is ever
  // revived, and by then the SDK details worth keeping will be out of date
  // anyway. Email notifications are unaffected and still work.

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