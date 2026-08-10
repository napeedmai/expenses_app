// My Expenses list. Logout and the Pending Approvals entry point have
// moved to the bottom tab bar (see src/navigation/MainTabs.js and
// src/screens/SettingsScreen.js) — this screen is just the list + FAB now.
// empId comes from the session context, not route.params.
//
// VISUAL: restyled per design_combined.html — rounded ticket-style rows,
// tinted status badges, in the app's blue/slate palette. The FAB is
// pushed up (bottom: 110) to clear the floating capsule tab bar.

import React, { useState, useCallback, useMemo } from 'react';
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
  RefreshControl,
  ActivityIndicator,
} from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { useSession } from '../SessionContext';
import { useTheme } from '../ThemeContext';
import { listMine } from '../api/client';
import { radius, shadow, iconForType, stageLabelShort } from '../theme';
import DateField from '../components/DateField';

const FILTERS = [
  { key: 'ALL', label: 'All' },
  { key: 'DRAFT', label: 'Draft' },
  { key: 'SUBMITTED', label: 'Submitted' },
  { key: 'REVISION_REQUESTED', label: 'Needs Revision' },
  { key: 'APPROVED', label: 'Approved' },
  { key: 'REJECTED', label: 'Rejected' },
];

// Dates come from the API as "MM/DD/YYYY" (see 23_date_format_mmddyyyy.sql).
// Converting to a plain sortable integer (20260724) for range comparisons
// avoids relying on `new Date("MM/DD/YYYY")` string parsing, which Hermes
// (the engine Expo uses on-device) doesn't reliably support — the same bug
// that made the Home dashboard look empty earlier.
function mdyToComparable(str) {
  if (!str) return null;
  const parts = String(str).split('/');
  if (parts.length !== 3) return null;
  const [mm, dd, yyyy] = parts.map(Number);
  if (!mm || !dd || !yyyy) return null;
  return yyyy * 10000 + mm * 100 + dd;
}

export default function ExpenseListScreen({ navigation }) {
  const { session } = useSession();
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const empId = session.empId;
  const [expenses, setExpenses] = useState([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState(null);
  const [filter, setFilter] = useState('ALL');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');

  const load = useCallback(async () => {
    try {
      const data = await listMine(empId);
      // /expenses/mine returns a standard ORDS collection_feed shape:
      // { items: [...] }
      setExpenses(Array.isArray(data.items) ? data.items : []);
      setError(null);
    } catch (e) {
      setError(e.message || 'Failed to load expenses.');
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [empId]);

  // Refresh every time this screen comes back into focus (e.g. after
  // returning from Add/Edit), not just on first mount.
  useFocusEffect(
    useCallback(() => {
      setLoading(true);
      load();
    }, [load])
  );

  function onRefresh() {
    setRefreshing(true);
    load();
  }

  function renderItem({ item }) {
    const st = colors.status[item.status] || colors.status.DRAFT;
    return (
      <TouchableOpacity
        style={styles.row}
        onPress={() => navigation.navigate('AddEditExpense', { expenseId: item.id })}
      >
        <View style={[styles.stub, { backgroundColor: st.text }]} />
        <View style={styles.rowIcon}>
          <Ionicons name={iconForType(item.type)} size={16} color={colors.textMuted} />
        </View>
        <View style={{ flex: 1 }}>
          <Text style={styles.rowTitle}>
            {item.type || 'Expense'} &mdash; &#8377;{item.amount}
          </Text>
          <Text style={styles.rowSubtitle}>
            {item.from_date} to {item.to_date}
          </Text>
        </View>
        <View style={[styles.badge, { backgroundColor: st.bg }]}>
          <Text style={[styles.badgeText, { color: st.text }]}>
            {stageLabelShort(item.status, item.current_stage)}
          </Text>
        </View>
      </TouchableOpacity>
    );
  }

  if (loading) {
    return (
      <SafeAreaView edges={['top']} style={styles.center}>
        <ActivityIndicator size="large" color={colors.primary} />
      </SafeAreaView>
    );
  }

  const dateFromC = mdyToComparable(dateFrom);
  const dateToC = mdyToComparable(dateTo);
  const hasDateFilter = !!(dateFromC || dateToC);

  const filtered = expenses.filter((e) => {
    if (filter !== 'ALL' && e.status !== filter) return false;
    if (hasDateFilter) {
      const c = mdyToComparable(e.from_date);
      if (c === null) return false;
      if (dateFromC && c < dateFromC) return false;
      if (dateToC && c > dateToC) return false;
    }
    return true;
  });

  return (
    <SafeAreaView edges={['top']} style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.headerTitle}>My Expenses</Text>
      </View>

      <View style={styles.filterRow}>
        {FILTERS.map((f) => {
          const count = f.key === 'ALL' ? expenses.length : expenses.filter((e) => e.status === f.key).length;
          const active = filter === f.key;
          return (
            <TouchableOpacity
              key={f.key}
              style={[styles.filterChip, active && styles.filterChipActive]}
              onPress={() => setFilter(f.key)}
            >
              <Text style={[styles.filterChipText, active && styles.filterChipTextActive]}>
                {f.label}{f.key !== 'ALL' ? ` (${count})` : ''}
              </Text>
            </TouchableOpacity>
          );
        })}
      </View>

      <View style={styles.dateFilterRow}>
        <View style={styles.dateFilterField}>
          <Text style={styles.dateFilterLabel}>From</Text>
          <DateField value={dateFrom} onChange={setDateFrom} placeholder="Any" fieldStyle={styles.dateFilterInput} />
        </View>
        <View style={styles.dateFilterField}>
          <Text style={styles.dateFilterLabel}>To</Text>
          <DateField value={dateTo} onChange={setDateTo} placeholder="Any" fieldStyle={styles.dateFilterInput} />
        </View>
        {hasDateFilter ? (
          <TouchableOpacity
            style={styles.dateFilterClear}
            onPress={() => {
              setDateFrom('');
              setDateTo('');
            }}
          >
            <Ionicons name="close-circle" size={22} color={colors.textFaint} />
          </TouchableOpacity>
        ) : null}
      </View>

      {error ? <Text style={styles.error}>{error}</Text> : null}
      <FlatList
        data={filtered}
        keyExtractor={(item) => String(item.id)}
        renderItem={renderItem}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        ListEmptyComponent={
          <Text style={styles.empty}>
            {expenses.length === 0
              ? 'No expenses yet. Tap + to add one.'
              : 'Nothing matches these filters.'}
          </Text>
        }
        contentContainerStyle={
          filtered.length === 0
            ? { flex: 1, justifyContent: 'center' }
            : { paddingHorizontal: 16, paddingTop: 4, paddingBottom: 140 }
        }
      />
      <TouchableOpacity
        style={styles.fab}
        onPress={() => navigation.navigate('AddEditExpense', { expenseId: null })}
      >
        <Ionicons name="add" size={28} color="#fff" />
      </TouchableOpacity>
    </SafeAreaView>
  );
}

function createStyles(colors) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center', backgroundColor: colors.bg },
  header: { paddingHorizontal: 16, paddingTop: 16, paddingBottom: 8 },
  headerTitle: { fontSize: 20, fontWeight: '800', color: colors.text },
  filterRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, paddingHorizontal: 16, paddingBottom: 12 },
  filterChip: {
    borderWidth: 1,
    borderColor: colors.border,
    backgroundColor: colors.surface,
    paddingHorizontal: 12,
    paddingVertical: 7,
    borderRadius: 999,
  },
  filterChipActive: { backgroundColor: colors.slate900, borderColor: colors.slate900 },
  filterChipText: { fontSize: 12, fontWeight: '700', color: colors.textMuted },
  filterChipTextActive: { color: '#fff' },
  dateFilterRow: {
    flexDirection: 'row',
    alignItems: 'flex-end',
    gap: 10,
    paddingHorizontal: 16,
    paddingBottom: 12,
  },
  dateFilterField: { flex: 1 },
  dateFilterLabel: {
    fontSize: 10.5,
    color: colors.textMuted,
    fontWeight: '800',
    textTransform: 'uppercase',
    letterSpacing: 0.3,
    marginBottom: 4,
  },
  dateFilterInput: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    paddingHorizontal: 10,
    paddingVertical: 9,
    fontSize: 13,
    fontWeight: '600',
    color: colors.text,
    backgroundColor: colors.surface,
  },
  dateFilterClear: { paddingBottom: 9 },
  error: { color: colors.red, padding: 12, textAlign: 'center', fontWeight: '600' },
  row: {
    flexDirection: 'row',
    alignItems: 'stretch',
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    marginBottom: 10,
    overflow: 'hidden',
  },
  stub: { width: 5 },
  rowIcon: {
    width: 40,
    height: 40,
    borderRadius: 12,
    backgroundColor: colors.bg,
    alignItems: 'center',
    justifyContent: 'center',
    marginVertical: 12,
    marginLeft: 12,
  },
  rowTitle: { fontSize: 14.5, fontWeight: '700', color: colors.text, marginLeft: 12 },
  rowSubtitle: { fontSize: 12, color: colors.textMuted, marginTop: 2, marginLeft: 12 },
  badge: { paddingHorizontal: 9, paddingVertical: 4, borderRadius: 999, marginVertical: 14, marginRight: 12, alignSelf: 'center' },
  badgeText: { fontSize: 10, fontWeight: '800' },
  empty: { textAlign: 'center', color: colors.textFaint, fontSize: 15 },
  fab: {
    position: 'absolute',
    right: 20,
    bottom: 110,
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: colors.primary,
    justifyContent: 'center',
    alignItems: 'center',
    ...shadow.raised,
  },
  });
}