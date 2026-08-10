// Settings screen — shows who you're logged in as, and Logout. Logout
// just calls the session context's logout(), which clears AsyncStorage and
// flips the app back to the Login screen (see src/SessionContext.js and
// App.js) — no manual navigation.reset() needed anymore now that Login vs.
// Main is decided by whether a session exists at all.
//
// VISUAL: restyled per design_combined.html — profile card with an avatar
// circle and role pills, in the app's blue/slate palette. Extra bottom
// padding clears the floating capsule tab bar (this is a tab landing
// screen, so the tab bar stays visible here).

import React, { useState, useMemo, useCallback } from 'react';
import { View, Text, TouchableOpacity, StyleSheet, Alert, ScrollView, Switch } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useFocusEffect } from '@react-navigation/native';
import { Ionicons } from '@expo/vector-icons';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { useSession } from '../SessionContext';
import { useTheme } from '../ThemeContext';
import { radius, shadow } from '../theme';

export default function SettingsScreen() {
  const { session, logout } = useSession();
  const { colors, scheme, toggleTheme } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const initial = (session?.displayName || '?').trim().charAt(0).toUpperCase() || '?';
  const [notifsMuted, setNotifsMuted] = useState(false);

  // Re-read on every focus too, in case it was changed elsewhere (there's
  // no elsewhere today, but this keeps it consistent with how HomeScreen
  // reads the same key).
  useFocusEffect(
    useCallback(() => {
      AsyncStorage.getItem('notifsMuted').then((v) => setNotifsMuted(v === 'true'));
    }, [])
  );

  async function handleToggleMute(value) {
    setNotifsMuted(value);
    try {
      await AsyncStorage.setItem('notifsMuted', value ? 'true' : 'false');
    } catch (e) {
      // Non-fatal — worst case the choice doesn't persist across restarts.
    }
  }

  function handleLogout() {
    Alert.alert('Log out?', 'You can log back in with your email and password any time.', [
      { text: 'Cancel', style: 'cancel' },
      { text: 'Log out', style: 'destructive', onPress: logout },
    ]);
  }

  return (
    <SafeAreaView edges={['top']} style={styles.container}>
    <ScrollView contentContainerStyle={{ padding: 16, paddingBottom: 140 }}>
      <Text style={styles.title}>Settings</Text>

      <View style={styles.card}>
        <View style={styles.avatar}>
          <Text style={styles.avatarText}>{initial}</Text>
        </View>
        <View style={{ flex: 1 }}>
          <Text style={styles.name}>{session?.displayName}</Text>
          <Text style={styles.sub}>EMPID {session?.empId}</Text>
          <View style={styles.roleRow}>
            {session?.isReportingManager ? (
              <View style={styles.rolePill}>
                {/* Field name is still isReportingManager under the hood
                    (see 44_project_manager_approval.sql) — it now actually
                    means "is a Project Manager on some project." */}
                <Text style={styles.rolePillText}>Project Manager</Text>
              </View>
            ) : null}
            {session?.isFinanceManager ? (
              <View style={[styles.rolePill, styles.rolePillAmber]}>
                <Text style={[styles.rolePillText, styles.rolePillAmberText]}>Finance Manager</Text>
              </View>
            ) : null}
          </View>
        </View>
      </View>

      <Text style={styles.sectionLabel}>Preferences</Text>
      <View style={styles.listGroup}>
        <View style={styles.listItem}>
          <View style={{ flex: 1, flexDirection: 'row', alignItems: 'center', gap: 10 }}>
            <Ionicons name="notifications-outline" size={18} color={colors.textMuted} />
            <View style={{ flex: 1 }}>
              <Text style={styles.listItemLabel}>Notifications</Text>
              <Text style={styles.listItemHint}>
                {notifsMuted ? 'Muted — the bell dot is hidden' : 'Get alerted to approvals and status updates'}
              </Text>
            </View>
          </View>
          <Switch
            value={!notifsMuted}
            onValueChange={(v) => handleToggleMute(!v)}
            trackColor={{ false: colors.border, true: colors.primary }}
            thumbColor="#fff"
          />
        </View>
        <View style={[styles.listItem, styles.listItemBorder]}>
          <View style={{ flex: 1, flexDirection: 'row', alignItems: 'center', gap: 10 }}>
            <Ionicons name={scheme === 'dark' ? 'moon' : 'sunny-outline'} size={18} color={colors.textMuted} />
            <View style={{ flex: 1 }}>
              <Text style={styles.listItemLabel}>Dark Mode</Text>
              <Text style={styles.listItemHint}>{scheme === 'dark' ? 'On' : 'Off'}</Text>
            </View>
          </View>
          <Switch
            value={scheme === 'dark'}
            onValueChange={toggleTheme}
            trackColor={{ false: colors.border, true: colors.primary }}
            thumbColor="#fff"
          />
        </View>
      </View>

      <View style={styles.listGroup}>
        <View style={styles.listItem}>
          <Text style={styles.listItemLabel}>App version</Text>
          <Text style={styles.listItemValue}>2.1.0</Text>
        </View>
      </View>

      <TouchableOpacity style={styles.logoutButton} onPress={handleLogout}>
        <Ionicons name="log-out-outline" size={17} color={colors.red} style={{ marginRight: 6 }} />
        <Text style={styles.logoutText}>Log Out</Text>
      </TouchableOpacity>
    </ScrollView>
    </SafeAreaView>
  );
}

function createStyles(colors) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg },
  title: { fontSize: 20, fontWeight: '800', color: colors.text, marginBottom: 16 },
  sectionLabel: {
    fontSize: 11,
    fontWeight: '800',
    color: colors.textFaint,
    textTransform: 'uppercase',
    letterSpacing: 0.4,
    marginBottom: 8,
    marginLeft: 2,
  },
  card: {
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.lg,
    padding: 16,
    marginBottom: 16,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
    ...shadow.card,
  },
  avatar: {
    width: 52,
    height: 52,
    borderRadius: 18,
    backgroundColor: colors.primary,
    alignItems: 'center',
    justifyContent: 'center',
  },
  avatarText: { color: '#fff', fontSize: 20, fontWeight: '800' },
  name: { fontSize: 16, fontWeight: '800', color: colors.text },
  sub: { fontSize: 12.5, color: colors.textMuted, marginTop: 2 },
  roleRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginTop: 8 },
  rolePill: { backgroundColor: colors.primaryTint, paddingHorizontal: 9, paddingVertical: 3, borderRadius: 999 },
  rolePillText: { fontSize: 10.5, fontWeight: '800', color: colors.primary },
  rolePillAmber: { backgroundColor: colors.amberTint },
  rolePillAmberText: { color: colors.status.REVISION_REQUESTED.text },
  listGroup: {
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.md,
    marginBottom: 20,
    overflow: 'hidden',
  },
  listItem: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 14,
    paddingVertical: 14,
  },
  listItemBorder: { borderTopWidth: 1, borderTopColor: colors.bg },
  listItemLabel: { fontSize: 13.5, fontWeight: '600', color: colors.text },
  listItemHint: { fontSize: 11.5, color: colors.textFaint, marginTop: 2 },
  listItemValue: { fontSize: 13, color: colors.textMuted, fontWeight: '600' },
  logoutButton: {
    flexDirection: 'row',
    backgroundColor: colors.redTint,
    borderRadius: radius.sm,
    padding: 14,
    alignItems: 'center',
    justifyContent: 'center',
  },
  logoutText: { color: colors.red, fontWeight: '700', fontSize: 15 },
  });
}