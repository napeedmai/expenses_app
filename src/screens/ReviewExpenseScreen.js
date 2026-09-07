// Review screen for a Reporting Manager or the Finance Manager to
// accept / request revision / reject a submitted expense.
//
// A comment is required for Revise and Reject (so the employee knows what
// to fix or why it was turned down), optional for Accept.
//
// emp_name and attachment_filename come from GET /expenses/pending — see
// 36_pending_endpoint_with_employee_name.sql, which adds both (neither was
// returned before, so this screen used to only ever show "Employee #3680"
// with a permanently-blank attachment section). Falls back gracefully if
// that SQL hasn't been run yet.

import React, { useState, useMemo, useEffect } from 'react';
import {
  ActivityIndicator,
  Alert,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import * as FileSystem from 'expo-file-system/legacy';
import * as Sharing from 'expo-sharing';
import { useSession } from '../SessionContext';
import { useTheme } from '../ThemeContext';
import {
  acceptExpense,
  reviseExpense,
  rejectExpense,
  listItems,
} from '../api/client';
import { radius, shadow, fileBadgeForName, stageLabelShort } from '../theme';
import { showAlert } from '../utils/alert';
import BillDetailSheet from '../components/BillDetailSheet';

export default function ReviewExpenseScreen({ route, navigation }) {
  const { session } = useSession();
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const empId = session.empId;
  const { expense } = route.params;
  const [comment, setComment] = useState('');
  const [submitting, setSubmitting] = useState(null); // 'accept' | 'revise' | 'reject' | null
  const [error, setError] = useState(null);
  // The reviewer gets the same bill detail the submitter does. They are the
  // person with the strongest reason to read a bill closely -- they are deciding
  // whether to pay it -- and until now they could open the receipt but never see
  // the bill's own fields: no bill date, no period, no conversion rate.
  const [detailBill, setDetailBill] = useState(null);
  const [bills, setBills] = useState([]);
  const [billsLoading, setBillsLoading] = useState(true);

  // A claim can hold up to 20 bills. The pending list only carries the claim
  // header, so fetch them here -- a reviewer approving a large claim has to see
  // every line, not just the first.
  useEffect(() => {
    let cancelled = false;
    listItems(empId, expense.id)
      .then((d) => {
        if (!cancelled) setBills(Array.isArray(d.items) ? d.items : []);
      })
      .catch((e) => {
        if (!cancelled) setError(e.message || 'Could not load the bills on this claim.');
      })
      .finally(() => {
        if (!cancelled) setBillsLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [empId, expense.id]);

  async function handleAction(action) {
    if ((action === 'revise' || action === 'reject') && !comment.trim()) {
      showAlert('Comment required', `Please add a comment explaining why you're choosing to ${action} this.`);
      return;
    }
    setSubmitting(action);
    setError(null);
    try {
      const fn = action === 'accept' ? acceptExpense : action === 'revise' ? reviseExpense : rejectExpense;
      await fn(empId, expense.id, comment.trim() || null);
      showAlert('Done', `Expense ${action === 'accept' ? 'accepted' : action + 'd'}.`, [
        { text: 'OK', onPress: () => navigation.goBack() },
      ]);
    } catch (e) {
      setError(e.message || `Failed to ${action} this expense.`);
    } finally {
      setSubmitting(null);
    }
  }

  // The pending list only ever contains SUBMITTED items (that's what
  // GET /expenses/pending filters on), and it doesn't return a status
  // field at all — so this is a safe, always-correct fallback rather than
  // a guess.
  const displayStatus = expense.status || 'SUBMITTED';
  const st = colors.status[displayStatus] || colors.status.SUBMITTED;
  const submitterName = expense.emp_name || `Employee #${expense.emp_id}`;
  const initial = submitterName.trim().charAt(0).toUpperCase() || '#';

  return (
    <ScrollView style={styles.container} contentContainerStyle={{ padding: 16 }}>
      <View style={styles.submitterPill}>
        <View style={styles.submitterAvatar}>
          <Text style={styles.submitterAvatarText}>{initial}</Text>
        </View>
        <View>
          <Text style={styles.submitterName}>{submitterName}</Text>
          <Text style={styles.submitterSub}>Employee #{expense.emp_id}</Text>
          <View style={[styles.statusBadge, { backgroundColor: st.bg }]}>
            <Text style={[styles.statusBadgeText, { color: st.text }]}>
              {stageLabelShort(displayStatus, expense.current_stage)}
            </Text>
          </View>
        </View>
      </View>

      {/* The CLAIM. Its total is the sum of the bills, computed server-side --
          the reviewer is approving one figure, itemised below. */}
      <View style={styles.card}>
        {expense.project_name || expense.project_id ? (
          <Row
            styles={styles}
            label="Project"
            value={expense.project_name || `Project ID ${expense.project_id}`}
          />
        ) : null}
        {expense.claim_for ? <Row styles={styles} label="Claim For" value={expense.claim_for} /> : null}
        <Row styles={styles} label="Period" value={`${expense.from_date} to ${expense.to_date}`} />
        <Row
          styles={styles}
          label="Total"
          value={`$${expense.amount_usd} USD`}
          last={!expense.description}
        />
        {expense.description ? <Row styles={styles} label="Note" value={expense.description} last /> : null}
      </View>

      {/* THE BILLS. Each with its own receipt, because approving a claim means
          approving every line in it. */}
      <View style={styles.billsHeader}>
        <Text style={styles.label}>
          {billsLoading ? 'Bills' : bills.length === 1 ? '1 Bill' : `${bills.length} Bills`}
        </Text>
      </View>

      {billsLoading ? (
        <ActivityIndicator color={colors.primary} style={{ marginVertical: 14 }} />
      ) : (
        bills.map((b) => {
          const bBadge = b.attachment_filename ? fileBadgeForName(b.attachment_filename) : null;
          return (
            <TouchableOpacity
              key={b.id}
              style={styles.attachedRow}
              onPress={() => setDetailBill(b)}
              activeOpacity={0.7}
            >
              {b.has_receipt === 'Y' && bBadge ? (
                <View style={[styles.fileBadge, { backgroundColor: bBadge.bg }]}>
                  <Text style={[styles.fileBadgeText, { color: bBadge.text }]}>{bBadge.label}</Text>
                </View>
              ) : (
                <View style={[styles.fileBadge, { backgroundColor: colors.bg }]}>
                  <Text style={[styles.fileBadgeText, { color: colors.textFaint }]}>{b.item_no}</Text>
                </View>
              )}
              <View style={{ flex: 1 }}>
                <Text style={styles.attachmentName} numberOfLines={1}>
                  {b.type}
                  {b.bill_no ? ` · ${b.bill_no}` : ''}
                </Text>
                <Text style={styles.attachmentSub} numberOfLines={1}>
                  {b.amount} {b.currency}
                  {b.amount_usd != null ? `  ·  $${b.amount_usd}` : ''}
                  {'  ·  '}
                  {b.from_date}
                </Text>
                {b.description ? (
                  <Text style={styles.attachmentSub} numberOfLines={2}>
                    {b.description}
                  </Text>
                ) : null}
              </View>
              <Ionicons name="chevron-forward" size={16} color={colors.textFaint} />
            </TouchableOpacity>
          );
        })
      )}

      {error ? <Text style={styles.error}>{error}</Text> : null}

      <Text style={styles.label}>Comment {`(required for Revise / Reject)`}</Text>
      <TextInput
        style={styles.input}
        value={comment}
        onChangeText={setComment}
        placeholder="Add a note for the employee..."
        multiline
      />

      <View style={styles.decisionRow}>
        <TouchableOpacity
          style={[styles.decisionButton, styles.rejectButton]}
          onPress={() => handleAction('reject')}
          disabled={!!submitting}
        >
          {submitting === 'reject' ? (
            <ActivityIndicator color={colors.status.REJECTED.text} />
          ) : (
            <Text style={[styles.decisionButtonText, styles.rejectButtonText]}>Reject</Text>
          )}
        </TouchableOpacity>

        <TouchableOpacity
          style={[styles.decisionButton, styles.reviseButton]}
          onPress={() => handleAction('revise')}
          disabled={!!submitting}
        >
          {submitting === 'revise' ? (
            <ActivityIndicator color={colors.status.REVISION_REQUESTED.text} />
          ) : (
            <Text style={[styles.decisionButtonText, styles.reviseButtonText]}>Revise</Text>
          )}
        </TouchableOpacity>

        <TouchableOpacity
          style={[styles.decisionButton, styles.acceptButton]}
          onPress={() => handleAction('accept')}
          disabled={!!submitting}
        >
          {submitting === 'accept' ? (
            <ActivityIndicator color="#fff" />
          ) : (
            <Text style={[styles.decisionButtonText, styles.acceptButtonText]}>Accept</Text>
          )}
        </TouchableOpacity>
      </View>

      {/* canEdit is false: a reviewer reads a bill, never changes one. */}
      <BillDetailSheet
        visible={!!detailBill}
        empId={empId}
        expenseId={expense.id}
        bill={detailBill}
        canEdit={false}
        onClose={() => setDetailBill(null)}
      />
    </ScrollView>
  );
}

// Module scope, not nested inside the screen component — same reasoning
// as Field in AddEditExpenseScreen.js: a component defined inside another
// component's body is a new function identity every render, which makes
// React remount it (and anything inside it) on every re-render instead of
// updating it in place.
function Row({ label, value, last, styles }) {
  return (
    <View style={[styles.row, last && styles.rowLast]}>
      <Text style={styles.rowLabel}>{label}</Text>
      <Text style={styles.rowValue}>{value}</Text>
    </View>
  );
}

function createStyles(colors) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg },

  submitterPill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    padding: 12,
    marginBottom: 14,
  },
  submitterAvatar: {
    width: 34,
    height: 34,
    borderRadius: 17,
    backgroundColor: colors.slate900,
    alignItems: 'center',
    justifyContent: 'center',
  },
  submitterAvatarText: { color: '#fff', fontWeight: '800', fontSize: 13 },
  submitterName: { fontSize: 13.5, fontWeight: '800', color: colors.text },
  submitterSub: { fontSize: 11, color: colors.textMuted, marginTop: 1 },
  statusBadge: { alignSelf: 'flex-start', paddingHorizontal: 8, paddingVertical: 3, borderRadius: 999, marginTop: 5 },
  statusBadgeText: { fontSize: 10, fontWeight: '800' },

  card: {
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.md,
    padding: 16,
    marginBottom: 14,
  },
  row: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    paddingVertical: 8,
    borderBottomWidth: 1,
    borderBottomColor: colors.bg,
  },
  rowLast: { borderBottomWidth: 0 },
  rowLabel: { color: colors.textMuted, fontSize: 12 },
  rowValue: { color: colors.text, fontSize: 12.5, fontWeight: '700', flexShrink: 1, textAlign: 'right', marginLeft: 12 },

  attachedRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    padding: 12,
    marginBottom: 14,
  },
  fileBadge: { width: 38, height: 38, borderRadius: 10, alignItems: 'center', justifyContent: 'center' },
  fileBadgeText: { fontSize: 9.5, fontWeight: '800' },
  attachmentName: { fontSize: 13.5, fontWeight: '700', color: colors.text },
  attachmentSub: { fontSize: 11, color: colors.textFaint, marginTop: 1 },
  billsHeader: { marginTop: 18 },

  error: { color: colors.red, marginBottom: 12, fontWeight: '600' },
  label: { fontSize: 12, color: colors.textMuted, marginBottom: 6, fontWeight: '700' },
  input: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    padding: 12,
    fontSize: 14,
    height: 80,
    marginBottom: 16,
    textAlignVertical: 'top',
    backgroundColor: colors.surface,
  },

  decisionRow: { flexDirection: 'row', gap: 8 },
  decisionButton: { flex: 1, borderRadius: radius.sm, paddingVertical: 13, alignItems: 'center' },
  acceptButton: { backgroundColor: colors.emerald, ...shadow.card },
  reviseButton: { backgroundColor: colors.amberTint },
  rejectButton: { backgroundColor: colors.redTint },
  decisionButtonText: { fontSize: 13.5, fontWeight: '700' },
  acceptButtonText: { color: '#fff' },
  reviseButtonText: { color: colors.status.REVISION_REQUESTED.text },
  rejectButtonText: { color: colors.status.REJECTED.text },

  });
}