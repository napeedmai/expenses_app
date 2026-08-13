// Pending Approvals screen — reached from the "Approvals" tab, which only
// appears if the session says this EMPID is a reviewer (see
// src/navigation/MainTabs.js).
//
// GET /expenses/pending is role-aware: it already figures out whether this
// EMPID should see expenses waiting on them as a Reporting Manager, as the
// Finance Manager, or (for a plain employee) nothing at all.
//
// NOTE: we pass the whole expense object from this list straight into the
// Review screen via navigation params, rather than re-fetching it there.
// GET /expenses/{id} (the employee detail endpoint) is restricted to the
// expense's own owner, so a reviewer can't call it for someone else's
// expense — using the fields already returned by /expenses/pending avoids
// that entirely.
//
// Bulk actions: long-press a row to enter selection mode, tap more rows to
// add them, then Accept / Revise / Reject the whole batch from the bottom
// bar. One comment applies to the whole batch for Revise/Reject (required,
// same rule as the single-item Review screen). The backend processes each
// id independently, so we always show a per-item result summary rather
// than assuming all-or-nothing.
//
// NOTE: this screen renders its own in-content toolbar for selection mode
// instead of using navigation.setOptions — the native header for this
// screen is intentionally off (see MainTabs.js), since it's a tab landing
// screen.
//
// VISUAL: restyled per design_combined.html (ticket-style rows, tinted
// status/selection colors). The bulk-action bar sits above the floating
// capsule tab bar (bottom: 96) rather than flush at 0, so the two don't
// overlap — this screen doesn't hide the tab bar the way Add/Edit and
// Review do, since selection mode is a lot more common here.

import React, { useState, useCallback, useMemo } from 'react';
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
  RefreshControl,
  ActivityIndicator,
  Modal,
  TextInput,
  Alert,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useFocusEffect } from '@react-navigation/native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { useSession } from '../SessionContext';
import { useTheme } from '../ThemeContext';
import { listPending, bulkAccept, bulkRevise, bulkReject } from '../api/client';
import { radius, shadow, iconForType } from '../theme';
import { showAlert } from '../utils/alert';

export default function PendingApprovalsScreen({ navigation }) {
  const { session } = useSession();
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const empId = session.empId;
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState(null);

  const [selectionMode, setSelectionMode] = useState(false);
  const [selectedIds, setSelectedIds] = useState([]);
  const [submitting, setSubmitting] = useState(false);
  const [commentModal, setCommentModal] = useState(null); // 'revise' | 'reject' | null
  const [commentText, setCommentText] = useState('');

  const load = useCallback(async () => {
    try {
      const data = await listPending(empId);
      setItems(Array.isArray(data.items) ? data.items : []);
      setError(null);
    } catch (e) {
      setError(e.message || 'Failed to load pending approvals.');
    } finally {
      setLoading(false);
      setRefreshing(false);
    }
  }, [empId]);

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

  function exitSelectionMode() {
    setSelectionMode(false);
    setSelectedIds([]);
  }

  function toggleSelect(id) {
    setSelectedIds((prev) =>
      prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]
    );
  }

  function handleLongPress(item) {
    if (!selectionMode) {
      setSelectionMode(true);
      setSelectedIds([item.id]);
    }
  }

  function handlePress(item) {
    if (selectionMode) {
      toggleSelect(item.id);
    } else {
      navigation.navigate('ReviewExpense', { expense: item });
    }
  }

  // Summarizes a { results: [{ id, status_code, message }] } response into
  // a clear "X succeeded, Y failed" alert — the backend processes each id
  // independently, so a partial failure is the normal case to expect, not
  // an edge case.
  function showResultSummary(actionLabel, response) {
    const results = Array.isArray(response.results) ? response.results : [];
    const succeeded = results.filter((r) => r.status_code === 200);
    const failed = results.filter((r) => r.status_code !== 200);
    let message = `${succeeded.length} of ${results.length} ${actionLabel}.`;
    if (failed.length > 0) {
      message += '\n\nNot processed:\n' + failed.map((r) => `#${r.id}: ${r.message}`).join('\n');
    }
    showAlert(failed.length > 0 ? 'Done, with some issues' : 'Done', message);
  }

  async function handleBulkAccept() {
    showAlert(
      'Accept selected?',
      `Accept ${selectedIds.length} expense${selectedIds.length === 1 ? '' : 's'}?`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Accept',
          onPress: async () => {
            setSubmitting(true);
            try {
              const response = await bulkAccept(empId, selectedIds, null);
              showResultSummary('accepted', response);
              exitSelectionMode();
              load();
            } catch (e) {
              showAlert('Failed', e.message || 'Bulk accept failed.');
            } finally {
              setSubmitting(false);
            }
          },
        },
      ]
    );
  }

  function openCommentModal(action) {
    setCommentText('');
    setCommentModal(action);
  }

  async function submitCommentModal() {
    if (!commentText.trim()) {
      showAlert('Comment required', 'Please add a comment for the employee.');
      return;
    }
    const action = commentModal;
    setCommentModal(null);
    setSubmitting(true);
    try {
      const fn = action === 'revise' ? bulkRevise : bulkReject;
      const response = await fn(empId, selectedIds, commentText.trim());
      showResultSummary(action === 'revise' ? 'sent back for revision' : 'rejected', response);
      exitSelectionMode();
      load();
    } catch (e) {
      showAlert('Failed', e.message || 'Bulk action failed.');
    } finally {
      setSubmitting(false);
    }
  }

  function renderItem({ item }) {
    const selected = selectedIds.includes(item.id);
    return (
      <TouchableOpacity
        style={[styles.row, selected && styles.rowSelected]}
        onPress={() => handlePress(item)}
        onLongPress={() => handleLongPress(item)}
      >
        {selectionMode ? (
          <View style={[styles.checkbox, selected && styles.checkboxChecked]}>
            {selected ? <Text style={styles.checkmark}>✓</Text> : null}
          </View>
        ) : (
          <View style={styles.rowIcon}>
            <Ionicons name={iconForType(item.type)} size={15} color={colors.primary} />
          </View>
        )}
        <View style={{ flex: 1 }}>
          <Text style={styles.rowTitle}>{item.emp_name || `Employee #${item.emp_id}`}</Text>
          <Text style={styles.rowSubtitle}>
            {item.type || 'Expense'} ·{' '}
            {item.currency ? `${item.amount} ${item.currency}` : `₹${item.amount}`}
            {item.amount_usd != null && item.currency !== 'USD' ? ` ($${item.amount_usd})` : ''}
            {' · '}
            {item.from_date} to {item.to_date}
          </Text>
        </View>
        {!selectionMode ? <Ionicons name="chevron-forward" size={16} color={colors.textFaint} /> : null}
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

  return (
    <SafeAreaView edges={['top']} style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.headerTitle}>Pending Approvals</Text>
        <Text style={styles.headerSubtitle}>
          {items.length} claim{items.length === 1 ? '' : 's'} awaiting your decision
        </Text>
      </View>

      {selectionMode ? (
        <View style={styles.selectionBar}>
          <Text style={styles.selectionText}>{selectedIds.length} selected</Text>
          <TouchableOpacity onPress={exitSelectionMode}>
            <Text style={styles.cancelText}>Cancel</Text>
          </TouchableOpacity>
        </View>
      ) : (
        <Text style={styles.hint}>Long-press an item to select more than one.</Text>
      )}

      {error ? <Text style={styles.error}>{error}</Text> : null}

      <FlatList
        data={items}
        keyExtractor={(item) => String(item.id)}
        renderItem={renderItem}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={onRefresh} />}
        ListEmptyComponent={<Text style={styles.empty}>Nothing waiting on you right now.</Text>}
        contentContainerStyle={
          items.length === 0
            ? { flex: 1, justifyContent: 'center' }
            : { paddingHorizontal: 16, paddingBottom: selectionMode ? 190 : 140 }
        }
      />

      {selectionMode && selectedIds.length > 0 ? (
        <View style={styles.actionBar}>
          <TouchableOpacity
            style={[styles.actionButton, styles.acceptButton]}
            onPress={handleBulkAccept}
            disabled={submitting}
          >
            {submitting ? <ActivityIndicator color="#fff" /> : <Text style={styles.actionButtonText}>Accept</Text>}
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.actionButton, styles.reviseButton]}
            onPress={() => openCommentModal('revise')}
            disabled={submitting}
          >
            <Text style={styles.actionButtonText}>Revise</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.actionButton, styles.rejectButton]}
            onPress={() => openCommentModal('reject')}
            disabled={submitting}
          >
            <Text style={styles.actionButtonText}>Reject</Text>
          </TouchableOpacity>
        </View>
      ) : null}

      <Modal visible={!!commentModal} transparent animationType="slide" onRequestClose={() => setCommentModal(null)}>
        <View style={styles.modalOverlay}>
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>
              {commentModal === 'revise' ? 'Request revision' : 'Reject'} {selectedIds.length} expense{selectedIds.length === 1 ? '' : 's'}
            </Text>
            <TextInput
              style={styles.modalInput}
              value={commentText}
              onChangeText={setCommentText}
              placeholder="Add a note for the employee..."
              multiline
              autoFocus
            />
            <TouchableOpacity style={styles.modalSubmit} onPress={submitCommentModal}>
              <Text style={styles.modalSubmitText}>Submit</Text>
            </TouchableOpacity>
            <TouchableOpacity style={styles.modalCancel} onPress={() => setCommentModal(null)}>
              <Text style={styles.modalCancelText}>Cancel</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>
    </SafeAreaView>
  );
}

function createStyles(colors) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center', backgroundColor: colors.bg },
  header: { paddingHorizontal: 16, paddingTop: 16, paddingBottom: 4 },
  headerTitle: { fontSize: 20, fontWeight: '800', color: colors.text },
  headerSubtitle: { fontSize: 12, color: colors.textMuted, marginTop: 2 },
  error: { color: colors.red, padding: 12, textAlign: 'center', fontWeight: '600' },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.md,
    padding: 14,
    marginBottom: 10,
    ...shadow.card,
  },
  rowSelected: { backgroundColor: colors.primaryTint, borderColor: colors.primary },
  rowIcon: {
    width: 34,
    height: 34,
    borderRadius: 12,
    backgroundColor: colors.primaryTint,
    alignItems: 'center',
    justifyContent: 'center',
    marginRight: 12,
  },
  rowTitle: { fontSize: 14.5, fontWeight: '700', color: colors.text },
  rowSubtitle: { fontSize: 12, color: colors.textMuted, marginTop: 2 },
  empty: { textAlign: 'center', color: colors.textFaint, fontSize: 15 },

  checkbox: {
    width: 22,
    height: 22,
    borderRadius: 11,
    borderWidth: 2,
    borderColor: colors.borderStrong,
    marginRight: 12,
    alignItems: 'center',
    justifyContent: 'center',
  },
  checkboxChecked: { backgroundColor: colors.primary, borderColor: colors.primary },
  checkmark: { color: '#fff', fontSize: 12, fontWeight: '700' },

  selectionBar: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    paddingHorizontal: 16,
    paddingVertical: 10,
    backgroundColor: colors.primaryTint,
  },
  selectionText: { fontSize: 13, fontWeight: '800', color: colors.primary },
  cancelText: { fontSize: 13, color: colors.primary, fontWeight: '700' },
  hint: { fontSize: 11.5, color: colors.textFaint, textAlign: 'center', paddingVertical: 8 },

  actionBar: {
    position: 'absolute',
    left: 16,
    right: 16,
    bottom: 96,
    flexDirection: 'row',
    backgroundColor: colors.surface,
    borderRadius: radius.md,
    borderWidth: 1,
    borderColor: colors.border,
    padding: 10,
    gap: 8,
    ...shadow.raised,
  },
  actionButton: { flex: 1, borderRadius: radius.sm, padding: 12, alignItems: 'center' },
  acceptButton: { backgroundColor: colors.emerald },
  reviseButton: { backgroundColor: colors.amber },
  rejectButton: { backgroundColor: colors.red },
  actionButtonText: { color: '#fff', fontWeight: '700', fontSize: 13 },

  modalOverlay: { flex: 1, backgroundColor: 'rgba(15,23,42,0.5)', justifyContent: 'flex-end' },
  modalCard: { backgroundColor: colors.surface, borderTopLeftRadius: 20, borderTopRightRadius: 20, padding: 18 },
  modalTitle: { fontSize: 15, fontWeight: '800', marginBottom: 12, color: colors.text },
  modalInput: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    padding: 10,
    fontSize: 15,
    height: 80,
    marginBottom: 14,
    textAlignVertical: 'top',
    backgroundColor: colors.bg,
  },
  modalSubmit: { backgroundColor: colors.primary, borderRadius: radius.sm, padding: 13, alignItems: 'center', marginBottom: 8 },
  modalSubmitText: { color: '#fff', fontWeight: '700' },
  modalCancel: { alignItems: 'center', paddingVertical: 6 },
  modalCancelText: { color: colors.textMuted },
  });
}