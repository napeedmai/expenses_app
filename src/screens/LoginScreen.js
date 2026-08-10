// Login screen — real login using APEX workspace credentials.
//
// Replaces the earlier email-OTP flow. Now:
//   1. Type your company email + your APEX password (the same one you use
//      to log into APEX apps).
//   2. The backend checks that against the APEX workspace's own user store
//      (POST /expenses/auth/login — reachable only because no ORDS
//      privilege pattern matches it; see client.js) and, if
//      correct, confirms that account maps to an active/resigned Trinamix
//      employee — returning the reviewer role flags in the same response.
//
// VISUAL: restyled per design_combined.html — a dark hero banner with the
// "T" mark and wordmark (structure borrowed from design_4), a card
// floating up into it holding the actual fields, in the app's blue/slate
// palette (design_2). Functionality (email + password + show/hide) is
// unchanged from before.
//
// No navigation prop needed — logging in calls the session context's
// login(), and App.js swaps to the main app automatically once a session
// exists (see src/SessionContext.js).

import React, { useState, useMemo } from 'react';
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  KeyboardAvoidingView,
  ScrollView,
  Platform,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useSession } from '../SessionContext';
import { useTheme } from '../ThemeContext';
import { login as loginRequest } from '../api/client';
import { radius, shadow } from '../theme';

export default function LoginScreen() {
  const { login, expiredMessage, clearExpiredMessage } = useSession();
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  async function handleLogin() {
    const trimmedUser = username.trim();
    if (!trimmedUser || !password) {
      setError('Enter both your email and password.');
      return;
    }
    setLoading(true);
    setError(null);
    clearExpiredMessage();
    try {
      const me = await loginRequest(trimmedUser, password);
      await login({
        empId: String(me.empid),
        displayName: me.display_name,
        isReportingManager: me.is_reporting_manager === 'Y',
        isFinanceManager: me.is_finance_manager === 'Y',
        // Signed proof that this device really did just log in as this
        // exact employee (see 43_secure_session_tokens.sql) — every API
        // call from here on sends this alongside X-Emp-Id so the backend
        // can verify the header isn't just a self-reported claim.
        sessionToken: me.session_token,
        // OAuth access token, fetched server-side on our behalf right
        // after this login was verified (see get_oauth_access_token in
        // PROD_3_business_logic.sql) — this app never holds the OAuth
        // client secret itself anymore. Stored as an ABSOLUTE expiry
        // timestamp (computed here, once, from the server's expires_in
        // seconds-from-now value) rather than the raw seconds — that way,
        // restoring this saved session after an app restart reflects the
        // real original expiry instead of looking freshly-issued again.
        accessToken: me.access_token,
        accessTokenExpiresAt: Date.now() + (me.expires_in || 3600) * 1000,
      });
    } catch (e) {
      if (e.status === 401) {
        setError('Invalid email or password.');
      } else if (e.status === 403) {
        setError('This account is not linked to an active employee record.');
      } else {
        setError(e.message || 'Failed to log in.');
      }
    } finally {
      setLoading(false);
    }
  }

  return (
    <KeyboardAvoidingView
      style={styles.flex}
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
    >
      <ScrollView contentContainerStyle={styles.scroll} keyboardShouldPersistTaps="handled">
        <View style={styles.hero}>
          <View style={styles.mark}>
            <Text style={styles.markText}>T</Text>
          </View>
          <Text style={styles.title}>Trinamix Expense</Text>
          <Text style={styles.subtitle}>Internal Finance &amp; Expense Portal</Text>
        </View>

        <View style={styles.cardWrap}>
          <View style={[styles.card, shadow.raised]}>
            {expiredMessage && !error ? (
              <Text style={styles.expiredNotice}>{expiredMessage}</Text>
            ) : null}
            <Text style={styles.label}>Email</Text>
            <TextInput
              style={styles.input}
              autoCapitalize="none"
              keyboardType="email-address"
              value={username}
              onChangeText={setUsername}
              placeholder="you@trinamix.com"
              placeholderTextColor={colors.textFaint}
            />

            <Text style={[styles.label, { marginTop: 14 }]}>Password</Text>
            <View style={styles.passwordRow}>
              <TextInput
                style={styles.passwordInput}
                secureTextEntry={!showPassword}
                value={password}
                onChangeText={setPassword}
                placeholder="Your APEX password"
                placeholderTextColor={colors.textFaint}
              />
              <TouchableOpacity style={styles.eyeButton} onPress={() => setShowPassword((v) => !v)}>
                <Ionicons name={showPassword ? 'eye-off' : 'eye'} size={20} color={colors.textMuted} />
              </TouchableOpacity>
            </View>

            {error ? <Text style={styles.error}>{error}</Text> : null}

            <TouchableOpacity style={styles.button} onPress={handleLogin} disabled={loading}>
              {loading ? (
                <ActivityIndicator color="#fff" />
              ) : (
                <View style={styles.buttonRow}>
                  <Text style={styles.buttonText}>Continue</Text>
                  <Ionicons name="arrow-forward" size={16} color="#fff" style={{ marginLeft: 6 }} />
                </View>
              )}
            </TouchableOpacity>
          </View>
        </View>

        <Text style={styles.footer}>v2.4.0 (Expo Client) &bull; Trinamix IT</Text>
      </ScrollView>
    </KeyboardAvoidingView>
  );
}

function createStyles(colors) {
  return StyleSheet.create({
  flex: { flex: 1, backgroundColor: colors.bg },
  scroll: { flexGrow: 1, paddingBottom: 32 },
  hero: {
    backgroundColor: colors.slate900,
    paddingTop: 64,
    paddingBottom: 44,
    paddingHorizontal: 24,
    alignItems: 'center',
    borderBottomLeftRadius: 36,
    borderBottomRightRadius: 36,
  },
  mark: {
    width: 56,
    height: 56,
    borderRadius: 18,
    backgroundColor: colors.primary,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 14,
  },
  markText: { color: '#fff', fontSize: 22, fontWeight: '800' },
  title: { color: '#fff', fontSize: 20, fontWeight: '800' },
  subtitle: { color: '#bfdbfe', fontSize: 12, marginTop: 4, fontWeight: '600' },
  cardWrap: { paddingHorizontal: 24, marginTop: -24 },
  card: {
    backgroundColor: colors.surface,
    borderRadius: radius.lg,
    padding: 20,
    borderWidth: 1,
    borderColor: colors.border,
  },
  label: { fontSize: 12, fontWeight: '700', color: colors.textMuted, marginBottom: 6 },
  input: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 12,
    padding: 12,
    fontSize: 15,
    fontWeight: '600',
    color: colors.text,
    backgroundColor: colors.bg,
  },
  passwordRow: {
    flexDirection: 'row',
    alignItems: 'center',
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: 12,
    backgroundColor: colors.bg,
  },
  passwordInput: { flex: 1, padding: 12, fontSize: 15, fontWeight: '600', color: colors.text },
  eyeButton: { paddingHorizontal: 12, paddingVertical: 12 },
  error: { color: colors.red, marginTop: 12, fontSize: 13, fontWeight: '600' },
  expiredNotice: {
    color: colors.textMuted,
    backgroundColor: colors.bg,
    borderRadius: 10,
    padding: 10,
    marginBottom: 14,
    fontSize: 12.5,
    fontWeight: '600',
    textAlign: 'center',
  },
  button: {
    backgroundColor: colors.primary,
    borderRadius: 12,
    paddingVertical: 14,
    alignItems: 'center',
    marginTop: 18,
  },
  buttonRow: { flexDirection: 'row', alignItems: 'center' },
  buttonText: { color: '#fff', fontSize: 15, fontWeight: '700' },
  footer: { textAlign: 'center', color: colors.textFaint, fontSize: 11, marginTop: 20 },
  });
}