// Home screen — the app's landing page.
//
// VISUAL: header now shows the Trinamix logo + your name/Employee ID
// instead of a "Good morning" greeting. The hero card is now a month
// picker: tap any bar to jump to that month, and the amount, category
// breakdown, approved-bills list, and the stat grid all recompute for
// whichever month is selected.
//
// DATA NOTE: "month" here is bucketed by each expense's own From Date
// (from_date) — the API doesn't return a separate "approved on" timestamp,
// so this is the closest real, non-invented signal available. The bell
// opens a notifications panel built from the same real data (your own
// status changes + a reviewer's pending count) — there's no backend
// notification log, so nothing here has a fake timestamp like "2 hours
// ago"; it just lists what's true right now.

import React, { useState, useCallback, useMemo } from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ScrollView,
  RefreshControl,
  ActivityIndicator,
  Image,
  Modal,
} from 'react-native';
import { useFocusEffect } from '@react-navigation/native';
import { SafeAreaView } from 'react-native-safe-area-context';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { Ionicons } from '@expo/vector-icons';
import { useSession } from '../SessionContext';
import { useTheme } from '../ThemeContext';
import { listMine, listPending } from '../api/client';
import { radius, shadow, iconForType } from '../theme';

const MONTH_LABELS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const MONTHS_SHOWN = 6;

function monthKey(year, month) {
  return `${year}-${String(month + 1).padStart(2, '0')}`;
}

function lastMonths(count) {
  const now = new Date();
  const out = [];
  for (let i = count - 1; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    out.push({ key: monthKey(d.getFullYear(), d.getMonth()), label: MONTH_LABELS[d.getMonth()], year: d.getFullYear() });
  }
  return out;
}

// Both bill_date and from_date come from the API as "MM/DD/YYYY" (see
// 23_date_format_mmddyyyy.sql and src/components/DateField.js). Plain
// `new Date("MM/DD/YYYY")` string parsing is NOT guaranteed by the JS spec —
// it works in V8 (Chrome/Node) but Hermes (the engine Expo uses on-device)
// can fail to parse that slash format and silently return an Invalid Date.
// Parsing the parts by hand avoids relying on the engine's string parser.
function parseMDY(str) {
  if (!str) return null;
  const parts = String(str).split('/');
  if (parts.length !== 3) return null;
  const [mm, dd, yyyy] = parts.map(Number);
  if (!mm || !dd || !yyyy) return null;
  return monthKey(yyyy, mm - 1);
}

// Which month an expense counts toward: Bill Date when it's filled in (the
// most accurate "when did I actually spend this"), falling back to From
// Date when Bill Date is blank — bill_date is an optional field, so a
// strict bill_date-only rule would make expenses without one disappear
// from every month, the same way the earlier date-parsing bug did.
function expenseMonthKey(e) {
  return parseMDY(e.bill_date) || parseMDY(e.from_date);
}

// Every total on this screen is in USD, via amount_usd.
//
// Summing the raw `amount` column would be meaningless once expenses exist
// in more than one currency — it would add ₹1000 to $50 to €200 and report
// 1250, a number in no currency at all. amount_usd is stamped at save time
// from the rate for the expense's own period month, so these totals stay
// stable even if a rate row is corrected later.
//
// Falls back to `amount` only for rows predating the currency columns, which
// the backfill in 45_currency_conversion.sql should have already handled.
function usdAmount(e) {
  const usd = Number(e.amount_usd);
  if (Number.isFinite(usd)) return usd;
  return Number(e.amount) || 0;
}

function categoryBreakdown(expenses) {
  const sums = {};
  expenses.forEach((e) => {
    const key = e.type || 'Other';
    sums[key] = (sums[key] || 0) + usdAmount(e);
  });
  const entries = Object.entries(sums).sort((a, b) => b[1] - a[1]).slice(0, 3);
  const max = entries.length ? entries[0][1] : 1;
  return entries.map(([type, total]) => ({ type, total, pct: Math.max(0.08, total / max) }));
}

function statusPhrase(status) {
  if (status === 'APPROVED') return 'was approved';
  if (status === 'REVISION_REQUESTED') return 'needs revision';
  if (status === 'REJECTED') return 'was rejected';
  return 'was updated';
}

export default function HomeScreen({ navigation }) {
  const { session } = useSession();
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const { empId, displayName, isReportingManager, isFinanceManager } = session;
  const isReviewer = !!isReportingManager || !!isFinanceManager;

  const [expenses, setExpenses] = useState([]);
  const [pendingCount, setPendingCount] = useState(0);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState(null);
  const [notifOpen, setNotifOpen] = useState(false);
  const [notifsMuted, setNotifsMuted] = useState(false);

  const months = lastMonths(MONTHS_SHOWN);
  const [selectedMonthKey, setSelectedMonthKey] = useState(months[months.length - 1].key);

  const load = useCallback(async () => {
    try {
      const mine = await listMine(empId);
      setExpenses(Array.isArray(mine.items) ? mine.items : []);
      if (isReviewer) {
        const pending = await listPending(empId);
        setPendingCount(Array.isArray(pending.items) ? pending.items.length : 0);
      }
      setError(null);
    } catch (e) {
      setError(e.message || 'Failed to load your dashboard.');
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [empId, isReviewer]);

  useFocusEffect(
    useCallback(() => {
      setLoading(true);
      load();
      // Re-read every time Home regains focus, so flipping the mute switch
      // in Settings and coming back here takes effect immediately.
      AsyncStorage.getItem('notifsMuted')
        .then((v) => setNotifsMuted(v === 'true'))
        .catch(() => {});
    }, [load])
  );

  function onRefresh() {
    setRefreshing(true);
    load();
  }

  function countByStatusInMonth(statusKey) {
    return expenses.filter((e) => e.status === statusKey && expenseMonthKey(e) === selectedMonthKey).length;
  }

  const initial = (displayName || '?').trim().charAt(0).toUpperCase() || '?';

  if (loading) {
    return (
      <SafeAreaView edges={['top']} style={styles.center}>
        <ActivityIndicator size="large" color={colors.primary} />
      </SafeAreaView>
    );
  }

  const monthsWithTotals = months.map((m) => ({
    ...m,
    total: expenses
      .filter((e) => e.status === 'APPROVED' && expenseMonthKey(e) === m.key)
      .reduce((sum, e) => sum + usdAmount(e), 0),
  }));
  const barsMax = Math.max(1, ...monthsWithTotals.map((m) => m.total));
  const selectedMonth = monthsWithTotals.find((m) => m.key === selectedMonthKey) || monthsWithTotals[monthsWithTotals.length - 1];
  const isCurrentMonth = selectedMonthKey === months[months.length - 1].key;

  const approvedInMonth = expenses.filter(
    (e) => e.status === 'APPROVED' && expenseMonthKey(e) === selectedMonthKey
  );
  const categories = categoryBreakdown(approvedInMonth);

  const myRecentUpdates = expenses
    .filter((e) => ['APPROVED', 'REVISION_REQUESTED', 'REJECTED'].includes(e.status))
    .slice(0, 5);
  const hasNotifications = pendingCount > 0 || myRecentUpdates.length > 0;

  return (
    <SafeAreaView edges={['top']} style={styles.container}>
    <ScrollView
      contentContainerStyle={{ padding: 16, paddingBottom: 140 }}
      refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
    >
      <View style={styles.headerRow}>
        <View style={styles.headerLeft}>
          <Image source={require('../../assets/trinamix-logo.png')} style={styles.logo} resizeMode="contain" />
          <View>
            <Text style={styles.headerName}>{displayName || `Employee #${empId}`}</Text>
            <Text style={styles.headerEmpId}>Employee ID {empId}</Text>
          </View>
        </View>
        <TouchableOpacity style={styles.bellButton} onPress={() => setNotifOpen(true)}>
          <Ionicons name="notifications-outline" size={18} color={colors.textMuted} />
          {!notifsMuted && hasNotifications ? <View style={styles.bellDot} /> : null}
        </TouchableOpacity>
      </View>

      {error ? <Text style={styles.error}>{error}</Text> : null}

      <TouchableOpacity
        style={styles.newExpenseButton}
        onPress={() => navigation.navigate('AddEditExpense', { expenseId: null })}
      >
        <View style={styles.newExpenseIcon}>
          <Ionicons name="add" size={20} color="#fff" />
        </View>
        <View style={{ flex: 1 }}>
          <Text style={styles.newExpenseTitle}>New Expense Claim</Text>
          <Text style={styles.newExpenseSubtitle}>Tap to create and attach receipt</Text>
        </View>
        <Ionicons name="chevron-forward" size={16} color="#bfdbfe" />
      </TouchableOpacity>

      <View style={styles.heroCard}>
        <View style={styles.heroTop}>
          <View>
            <Text style={styles.heroLabel}>
              Approved {isCurrentMonth ? 'this month' : `in ${selectedMonth.label} ${selectedMonth.year}`}
            </Text>
            {/* Totals are USD — they sum amount_usd across expenses that may
                be in different currencies, so a rupee symbol here would be
                wrong for any non-INR claim. */}
            <Text style={styles.heroAmount}>${selectedMonth.total.toLocaleString('en-US', { maximumFractionDigits: 2 })}</Text>
          </View>
        </View>
        <View style={styles.barsRow}>
          {monthsWithTotals.map((m) => {
            const h = Math.max(0.08, m.total / barsMax);
            const selected = m.key === selectedMonthKey;
            return (
              <TouchableOpacity key={m.key} style={styles.barCol} onPress={() => setSelectedMonthKey(m.key)}>
                <View style={styles.barTrack}>
                  <View style={[styles.bar, { height: `${Math.round(h * 100)}%` }, selected ? styles.barSelected : null]} />
                </View>
                <Text style={[styles.barLabel, selected ? styles.barLabelSelected : null]}>{m.label}</Text>
              </TouchableOpacity>
            );
          })}
        </View>
      </View>

      <Text style={styles.sectionTitle}>Where it's going</Text>
      {categories.length > 0 ? (
        categories.map((c) => (
          <View key={c.type} style={styles.catRow}>
            <View style={styles.catIcon}>
              <Ionicons name={iconForType(c.type)} size={15} color={colors.primary} />
            </View>
            <View style={{ flex: 1 }}>
              <View style={styles.catTopLine}>
                <Text style={styles.catLabel}>{c.type}</Text>
                <Text style={styles.catAmount}>${c.total.toLocaleString('en-US', { maximumFractionDigits: 2 })}</Text>
              </View>
              <View style={styles.catTrack}>
                <View style={[styles.catFill, { width: `${Math.round(c.pct * 100)}%` }]} />
              </View>
            </View>
          </View>
        ))
      ) : (
        <Text style={styles.empty}>Nothing approved in {selectedMonth.label} {selectedMonth.year}.</Text>
      )}

      <Text style={styles.sectionTitle}>Your Expenses</Text>
      <View style={styles.statsGrid}>
        <StatTile styles={styles} label="Draft" count={countByStatusInMonth('DRAFT')} color={colors.textMuted} />
        <StatTile styles={styles} label="Submitted" count={countByStatusInMonth('SUBMITTED')} color={colors.status.SUBMITTED.text} />
        <StatTile styles={styles} label="Approved" count={countByStatusInMonth('APPROVED')} color={colors.status.APPROVED.text} />
        <StatTile
          styles={styles}
          label="Needs Revision"
          count={countByStatusInMonth('REVISION_REQUESTED')}
          color={colors.status.REVISION_REQUESTED.text}
        />
        <StatTile styles={styles} label="Rejected" count={countByStatusInMonth('REJECTED')} color={colors.status.REJECTED.text} />
      </View>

      {isReviewer ? (
        <TouchableOpacity style={styles.reviewerCard} onPress={() => navigation.navigate('ApprovalsTab')}>
          <View>
            <Text style={styles.reviewerCardTitle}>
              {pendingCount === 0 ? 'Nothing waiting on you' : `${pendingCount} approval${pendingCount === 1 ? '' : 's'} waiting`}
            </Text>
            <Text style={styles.reviewerCardSubtitle}>Tap to review</Text>
          </View>
          <View style={styles.reviewerGo}>
            <Ionicons name="arrow-forward" size={16} color="#fff" />
          </View>
        </TouchableOpacity>
      ) : null}

      <Text style={styles.sectionTitle}>
        Approved bills {isCurrentMonth ? 'this month' : `in ${selectedMonth.label} ${selectedMonth.year}`}
      </Text>
      {approvedInMonth.length === 0 ? (
        <Text style={styles.empty}>No approved expenses in {selectedMonth.label} {selectedMonth.year}.</Text>
      ) : (
        approvedInMonth.map((item) => {
          const st = colors.status[item.status] || colors.status.DRAFT;
          return (
            <TouchableOpacity
              key={item.id}
              style={styles.activityRow}
              onPress={() => navigation.navigate('AddEditExpense', { expenseId: item.id })}
            >
              <View style={[styles.activityIcon, { backgroundColor: st.bg }]}>
                <Ionicons name={iconForType(item.type)} size={14} color={st.text} />
              </View>
              <View style={{ flex: 1 }}>
                <Text style={styles.activityTitle}>
                  {item.type || 'Expense'} &mdash;{' '}
                  {item.currency ? `${item.amount} ${item.currency}` : `₹${item.amount}`}
                </Text>
                <Text style={styles.activitySubtitle}>
                  {item.from_date} to {item.to_date}
                </Text>
              </View>
              <View style={[styles.badge, { backgroundColor: st.bg }]}>
                <Text style={[styles.badgeText, { color: st.text }]}>
                  {colors.statusLabel[item.status] || item.status}
                </Text>
              </View>
            </TouchableOpacity>
          );
        })
      )}
    </ScrollView>
    {renderNotifications()}
    </SafeAreaView>
  );

  function renderNotifications() {
    return (
      <Modal visible={notifOpen} transparent animationType="slide" onRequestClose={() => setNotifOpen(false)}>
        <View style={styles.notifOverlay}>
          <View style={styles.notifCard}>
            <View style={styles.notifHeader}>
              <Text style={styles.notifTitle}>Notifications</Text>
              <TouchableOpacity onPress={() => setNotifOpen(false)}>
                <Ionicons name="close" size={20} color={colors.textMuted} />
              </TouchableOpacity>
            </View>

            {isReviewer && pendingCount > 0 ? (
              <TouchableOpacity
                style={styles.notifItem}
                onPress={() => {
                  setNotifOpen(false);
                  navigation.navigate('ApprovalsTab');
                }}
              >
                <View style={[styles.notifIcon, { backgroundColor: colors.amberTint }]}>
                  <Ionicons name="checkmark-done-outline" size={15} color="#b45309" />
                </View>
                <Text style={styles.notifText}>
                  {pendingCount} approval{pendingCount === 1 ? '' : 's'} waiting on you
                </Text>
              </TouchableOpacity>
            ) : null}

            {myRecentUpdates.length === 0 && !(isReviewer && pendingCount > 0) ? (
              <Text style={styles.empty}>Nothing new right now.</Text>
            ) : (
              myRecentUpdates.map((item) => {
                const st = colors.status[item.status] || colors.status.DRAFT;
                return (
                  <TouchableOpacity
                    key={item.id}
                    style={styles.notifItem}
                    onPress={() => {
                      setNotifOpen(false);
                      navigation.navigate('AddEditExpense', { expenseId: item.id });
                    }}
                  >
                    <View style={[styles.notifIcon, { backgroundColor: st.bg }]}>
                      <Ionicons name={iconForType(item.type)} size={15} color={st.text} />
                    </View>
                    <Text style={styles.notifText}>
                      Your {item.type || 'expense'} claim {statusPhrase(item.status)}
                    </Text>
                  </TouchableOpacity>
                );
              })
            )}
          </View>
        </View>
      </Modal>
    );
  }
}

function StatTile({ label, count, color, styles }) {
  return (
    <View style={styles.statTile}>
      <Text style={[styles.statCount, { color }]}>{count}</Text>
      <Text style={styles.statLabel}>{label}</Text>
    </View>
  );
}

function createStyles(colors) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center', backgroundColor: colors.bg },
  error: { color: colors.red, marginBottom: 12, fontWeight: '600' },

  headerRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', marginBottom: 16 },
  headerLeft: { flexDirection: 'row', alignItems: 'center', gap: 10, flex: 1 },
  logo: { width: 34, height: 34 },
  headerName: { fontSize: 14, fontWeight: '800', color: colors.text },
  headerEmpId: { fontSize: 11, color: colors.textMuted, marginTop: 1 },
  bellButton: {
    width: 36, height: 36, borderRadius: 12, backgroundColor: colors.surface,
    borderWidth: 1, borderColor: colors.border, alignItems: 'center', justifyContent: 'center', position: 'relative',
  },
  bellDot: { position: 'absolute', top: 7, right: 8, width: 6, height: 6, borderRadius: 3, backgroundColor: colors.amber },

  newExpenseButton: {
    backgroundColor: colors.primary,
    borderRadius: radius.md,
    padding: 14,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    marginBottom: 16,
    ...shadow.card,
  },
  newExpenseIcon: { width: 36, height: 36, borderRadius: 12, backgroundColor: 'rgba(255,255,255,0.2)', alignItems: 'center', justifyContent: 'center' },
  newExpenseTitle: { color: '#fff', fontSize: 14, fontWeight: '700' },
  newExpenseSubtitle: { color: '#bfdbfe', fontSize: 11, marginTop: 1 },

  heroCard: {
    backgroundColor: colors.slate900,
    borderRadius: radius.lg,
    padding: 16,
    marginBottom: 20,
  },
  heroTop: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start' },
  heroLabel: { color: '#93c5fd', fontSize: 10, fontWeight: '700', textTransform: 'uppercase', letterSpacing: 0.4 },
  heroAmount: { color: '#fff', fontSize: 24, fontWeight: '800', marginTop: 3 },
  barsRow: { flexDirection: 'row', alignItems: 'flex-end', gap: 6, height: 62, marginTop: 14 },
  barCol: { flex: 1, alignItems: 'center' },
  barTrack: { width: '100%', height: 40, justifyContent: 'flex-end' },
  bar: { width: '100%', backgroundColor: 'rgba(255,255,255,0.22)', borderRadius: 4, minHeight: 4 },
  barSelected: { backgroundColor: colors.primary },
  barLabel: { color: '#7c93c2', fontSize: 9.5, fontWeight: '700', marginTop: 5 },
  barLabelSelected: { color: '#fff' },

  sectionTitle: { fontSize: 13, fontWeight: '800', color: colors.text, marginBottom: 10, marginTop: 4 },

  catRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 12 },
  catIcon: { width: 30, height: 30, borderRadius: 10, backgroundColor: colors.primaryTint, alignItems: 'center', justifyContent: 'center' },
  catTopLine: { flexDirection: 'row', justifyContent: 'space-between' },
  catLabel: { fontSize: 12.5, fontWeight: '600', color: colors.text },
  catAmount: { fontSize: 12.5, fontWeight: '700', color: colors.text },
  catTrack: { height: 5, backgroundColor: colors.border, borderRadius: 999, marginTop: 5, overflow: 'hidden' },
  catFill: { height: '100%', backgroundColor: colors.primary, borderRadius: 999 },

  statsGrid: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-between', marginBottom: 4 },
  statTile: {
    width: '31%',
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    paddingVertical: 12,
    alignItems: 'center',
    marginBottom: 10,
  },
  statCount: { fontSize: 19, fontWeight: '800' },
  statLabel: { fontSize: 9.5, color: colors.textMuted, marginTop: 3, textAlign: 'center', fontWeight: '700', textTransform: 'uppercase' },

  reviewerCard: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    backgroundColor: colors.amberTint,
    borderWidth: 1,
    borderColor: '#fde68a',
    borderRadius: radius.md,
    padding: 16,
    marginBottom: 20,
  },
  reviewerCardTitle: { fontSize: 13.5, fontWeight: '800', color: '#92400e' },
  reviewerCardSubtitle: { fontSize: 11, color: '#a16207', marginTop: 2 },
  reviewerGo: { width: 30, height: 30, borderRadius: 15, backgroundColor: colors.amber, alignItems: 'center', justifyContent: 'center' },

  activityRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    padding: 12,
    marginBottom: 10,
  },
  activityIcon: { width: 32, height: 32, borderRadius: 11, alignItems: 'center', justifyContent: 'center' },
  activityTitle: { fontSize: 13.5, fontWeight: '700', color: colors.text },
  activitySubtitle: { fontSize: 11, color: colors.textMuted, marginTop: 2 },
  badge: { paddingHorizontal: 9, paddingVertical: 4, borderRadius: 999 },
  badgeText: { fontSize: 10, fontWeight: '800' },
  empty: { color: colors.textFaint, fontSize: 14, marginBottom: 16 },

  notifOverlay: { flex: 1, backgroundColor: 'rgba(15,23,42,0.5)', justifyContent: 'flex-end' },
  notifCard: { backgroundColor: colors.surface, borderTopLeftRadius: 20, borderTopRightRadius: 20, padding: 18, maxHeight: '70%' },
  notifHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 },
  notifTitle: { fontSize: 16, fontWeight: '800', color: colors.text },
  notifItem: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 10 },
  notifIcon: { width: 30, height: 30, borderRadius: 10, alignItems: 'center', justifyContent: 'center' },
  notifText: { fontSize: 13, fontWeight: '600', color: colors.text, flex: 1 },
  });
}