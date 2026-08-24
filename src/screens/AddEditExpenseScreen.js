// Add / Edit an expense CLAIM.
//
// A claim is the header — who, which project, what it was for — plus a list of
// BILLS, each with its own dates, currency, amount and receipt. The old version
// of this screen was one claim = one bill; see MULTI_BILL_PLAN.md and
// db/64..66 for the change.
//
// The claim's USD total is NOT computed here. recalc_claim_totals sums the bills
// server-side and GET /expenses/{id} returns it. The list below shows the sum of
// what it just fetched, which is the same number by construction — two places
// deciding what a claim is worth is how they end up disagreeing.
//
//
// ORDER OF OPERATIONS, AND WHY
// ----------------------------
// A bill cannot exist without a claim to hang off, so "Add Bill" on an unsaved
// claim saves the header first and then adds the bill. The user sees one action.
//
// Saving a bill is likewise two calls: POST the bill, then upload the receipt
// against the id that comes back. That is what makes "attach the file before
// saving" work — the file sits in BillSheet's state until there is a row for it.
// If the upload fails the bill still exists without a receipt, which is a valid
// state; losing the typing would not be.

import React, { useState, useEffect, useCallback, useMemo } from 'react';
import {
  ActivityIndicator,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useSession } from '../SessionContext';
import { useTheme } from '../ThemeContext';
import PickerField from '../components/PickerField';
import BillSheet from '../components/BillSheet';
import { radius, shadow, stageLabel, fileBadgeForName } from '../theme';
import { showAlert } from '../utils/alert';
import {
  getExpense,
  createDraft,
  updateExpense,
  deleteExpense,
  submitExpense,
  listMyProjects,
  listCurrencies,
  listItems,
  addItem,
  updateItem,
  deleteItem,
  uploadItemAttachment,
} from '../api/client';

const EDITABLE_STATUSES = ['DRAFT', 'REVISION_REQUESTED'];
const MAX_BILLS = 20;

// One id per "new claim" attempt, reused across retries, so a lost response
// cannot produce two claims. See 37_idempotent_draft_creation.sql — without it
// a timed-out save looked like a failure even when the row had been created.
function generateClientRequestId() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

export default function AddEditExpenseScreen({ route, navigation }) {
  const { session } = useSession();
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const empId = session.empId;
  const { expenseId: initialExpenseId } = route.params || {};

  const [clientRequestId] = useState(() =>
    initialExpenseId ? null : generateClientRequestId()
  );

  const [expenseId, setExpenseId] = useState(initialExpenseId);
  const [status, setStatus] = useState('DRAFT');
  const [currentStage, setCurrentStage] = useState(null);
  const [managerName, setManagerName] = useState(null);
  const [financeManagerName, setFinanceManagerName] = useState(null);

  const [projectId, setProjectId] = useState('');
  const [claimFor, setClaimFor] = useState('');

  const [items, setItems] = useState([]);
  const [myProjects, setMyProjects] = useState(null);
  const [currencies, setCurrencies] = useState([]);

  const [loading, setLoading] = useState(!!initialExpenseId);
  const [saving, setSaving] = useState(false);
  const [billSaving, setBillSaving] = useState(false);
  const [error, setError] = useState(null);

  const [sheetOpen, setSheetOpen] = useState(false);
  const [editingBill, setEditingBill] = useState(null);

  const isLocked = !!expenseId && !EDITABLE_STATUSES.includes(status);

  // ---- loading ----

  useEffect(() => {
    listMyProjects(empId)
      .then((d) => setMyProjects(Array.isArray(d.items) ? d.items : []))
      .catch(() => setMyProjects([]));
    listCurrencies(empId)
      .then((d) => {
        const list = Array.isArray(d.items) ? d.items : [];
        setCurrencies(list.length ? list : [{ currency: 'INR' }]);
      })
      .catch(() => setCurrencies([{ currency: 'INR' }]));
  }, [empId]);

  const loadBills = useCallback(
    async (id) => {
      const d = await listItems(empId, id);
      setItems(Array.isArray(d.items) ? d.items : []);
    },
    [empId]
  );

  useEffect(() => {
    if (!initialExpenseId) return;
    let cancelled = false;
    (async () => {
      try {
        const claim = await getExpense(empId, initialExpenseId);
        if (cancelled) return;
        setStatus(claim.status || 'DRAFT');
        setCurrentStage(claim.current_stage || null);
        setProjectId(claim.project_id != null ? String(claim.project_id) : '');
        setClaimFor(claim.claim_for || '');
        setManagerName(claim.manager_name || null);
        setFinanceManagerName(claim.finance_manager_name || null);
        await loadBills(initialExpenseId);
      } catch (e) {
        if (!cancelled) setError(e.message || 'Could not load this claim.');
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [empId, initialExpenseId, loadBills]);

  // ---- the claim header ----

  function headerPayload() {
    return {
      project_id: projectId ? Number(projectId) : null,
      claim_for: claimFor || null,
      ...(clientRequestId ? { client_request_id: clientRequestId } : {}),
    };
  }

  // Returns the claim id, creating the claim if this is the first save. Every
  // action that needs a claim to exist goes through here rather than each one
  // deciding for itself whether to create.
  async function ensureClaim() {
    if (expenseId) {
      await updateExpense(empId, expenseId, headerPayload());
      return expenseId;
    }
    if (!projectId) {
      throw new Error('Choose a project first — it decides who approves this claim.');
    }
    const created = await createDraft(empId, headerPayload());
    const id = created.id;
    setExpenseId(id);
    return id;
  }

  async function handleSaveHeader() {
    setSaving(true);
    setError(null);
    try {
      await ensureClaim();
      showAlert('Saved', 'Your claim has been saved as a draft.');
    } catch (e) {
      setError(e.message || 'Could not save this claim.');
    } finally {
      setSaving(false);
    }
  }

  // ---- bills ----

  async function handleOpenSheet(bill) {
    if (isLocked) return;
    if (!bill && items.length >= MAX_BILLS) {
      showAlert(
        'That is the limit',
        `A claim can hold ${MAX_BILLS} bills. Submit this one and start another.`
      );
      return;
    }
    setEditingBill(bill || null);
    setSheetOpen(true);
  }

  async function handleSaveBill(fields, pickedFile) {
    setBillSaving(true);
    setError(null);
    try {
      const id = await ensureClaim();

      let itemId;
      if (editingBill && editingBill.id) {
        await updateItem(empId, id, editingBill.id, fields);
        itemId = editingBill.id;
      } else {
        const created = await addItem(empId, id, fields);
        itemId = created.id;
      }

      // Separate call, and separately reported: a failed upload must not lose
      // the bill that was just saved successfully.
      if (pickedFile) {
        try {
          await uploadItemAttachment(empId, id, itemId, pickedFile);
        } catch (e) {
          showAlert(
            'Bill saved, receipt did not upload',
            `${e.message || 'The upload failed.'} The bill is saved — open it again to retry the receipt.`
          );
        }
      }

      await loadBills(id);
      setSheetOpen(false);
      setEditingBill(null);
    } catch (e) {
      // Shown inside the sheet, which stays open so the typing survives.
      showAlert('Could not save this bill', e.message || 'Please try again.');
    } finally {
      setBillSaving(false);
    }
  }

  function handleDeleteBill(bill) {
    showAlert('Remove this bill?', `Bill ${bill.item_no}: ${bill.type} — ${bill.amount} ${bill.currency}`, [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Remove',
        style: 'destructive',
        onPress: async () => {
          try {
            await deleteItem(empId, expenseId, bill.id);
            await loadBills(expenseId);
          } catch (e) {
            showAlert('Could not remove it', e.message || 'Please try again.');
          }
        },
      },
    ]);
  }

  // ---- submit / delete ----

  async function handleSubmit() {
    setSaving(true);
    setError(null);
    try {
      const id = await ensureClaim();
      await submitExpense(empId, id);
      showAlert('Submitted', 'Your claim has gone to your project manager.', [
        { text: 'OK', onPress: () => navigation.goBack() },
      ]);
    } catch (e) {
      // The submit handler returns 409 with a specific reason — no bills, a
      // bill without a receipt (named), or no Claim For. Show it as-is rather
      // than replacing it with something vaguer.
      setError(e.message || 'Could not submit this claim.');
    } finally {
      setSaving(false);
    }
  }

  function handleDeleteClaim() {
    showAlert('Delete this claim?', 'The claim and all of its bills will be removed.', [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: async () => {
          try {
            await deleteExpense(empId, expenseId);
            navigation.goBack();
          } catch (e) {
            showAlert('Could not delete it', e.message || 'Please try again.');
          }
        },
      },
    ]);
  }

  // ---- derived ----

  const totalUsd = items.reduce((sum, b) => sum + (Number(b.amount_usd) || 0), 0);
  const missingReceipts = items.filter((b) => b.has_receipt !== 'Y').length;
  const canSubmit =
    !isLocked && items.length > 0 && missingReceipts === 0 && !!claimFor && !!projectId;

  if (loading) {
    return (
      <View style={styles.centre}>
        <ActivityIndicator size="large" color={colors.primary} />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={{ padding: 16, paddingBottom: 120 }}>
        {error ? <Text style={styles.error}>{error}</Text> : null}

        {expenseId ? (
          <View style={styles.statusRow}>
            <Text style={styles.statusText}>{stageLabel(status, currentStage)}</Text>
            {isLocked ? (
              <Text style={styles.lockedNote}>Awaiting review — not editable</Text>
            ) : null}
          </View>
        ) : null}

        {/* ---- claim header ---- */}
        <Text style={styles.sectionLabel}>Claim</Text>
        <View style={styles.card}>
          <Text style={styles.label}>Project</Text>
          <PickerField
            options={myProjects || []}
            valueKey="project_id"
            labelKey="project_name"
            value={projectId}
            onSelect={(v) => setProjectId(String(v))}
            disabled={isLocked}
            placeholder={myProjects === null ? 'Loading…' : 'Select a project'}
            fieldStyle={styles.input}
          />

          <Text style={styles.label}>Claim For</Text>
          <TextInput
            style={styles.input}
            value={claimFor}
            onChangeText={setClaimFor}
            editable={!isLocked}
            placeholder="e.g. Client visit — Chennai"
            placeholderTextColor={colors.textFaint}
          />

          {/* Read-only. The reporting manager comes from the project, and the
              finance manager from get_finance_manager_empid() — both resolved
              server-side at submit. Shown so the person knows who will see it. */}
          <View style={styles.readonlyRow}>
            <View style={{ flex: 1 }}>
              <Text style={styles.readonlyLabel}>Reporting Manager</Text>
              <Text style={styles.readonlyValue}>
                {managerName || (expenseId ? 'Set when you submit' : '—')}
              </Text>
            </View>
            <View style={{ flex: 1 }}>
              <Text style={styles.readonlyLabel}>Manager (Finance)</Text>
              <Text style={styles.readonlyValue}>
                {financeManagerName || (expenseId ? 'Set when you submit' : '—')}
              </Text>
            </View>
          </View>
        </View>

        {/* ---- bills ---- */}
        <View style={styles.billsHeader}>
          <Text style={styles.sectionLabel}>Expense Details</Text>
          <Text style={styles.billCount}>
            {items.length} of {MAX_BILLS}
          </Text>
        </View>

        {items.length === 0 ? (
          <View style={styles.empty}>
            <Ionicons name="receipt-outline" size={26} color={colors.textFaint} />
            <Text style={styles.emptyText}>No bills yet.</Text>
            <Text style={styles.emptyHint}>Add one for each receipt you are claiming.</Text>
          </View>
        ) : (
          items.map((b) => {
            const badge = b.attachment_filename ? fileBadgeForName(b.attachment_filename) : null;
            return (
              <TouchableOpacity
                key={b.id}
                style={styles.billRow}
                onPress={() => handleOpenSheet(b)}
                disabled={isLocked}
                activeOpacity={0.7}
              >
                <View style={styles.billNo}>
                  <Text style={styles.billNoText}>{b.item_no}</Text>
                </View>
                <View style={{ flex: 1 }}>
                  <Text style={styles.billType}>{b.type}</Text>
                  <Text style={styles.billMeta} numberOfLines={1}>
                    {b.bill_no ? `${b.bill_no} · ` : ''}
                    {b.from_date}
                    {b.to_date && b.to_date !== b.from_date ? ` – ${b.to_date}` : ''}
                  </Text>
                  <View style={styles.billTags}>
                    {b.has_receipt === 'Y' ? (
                      <View style={[styles.tag, badge ? { backgroundColor: badge.bg } : null]}>
                        <Text style={[styles.tagText, badge ? { color: badge.text } : null]}>
                          {badge ? badge.label : 'RECEIPT'}
                        </Text>
                      </View>
                    ) : (
                      <View style={[styles.tag, styles.tagMissing]}>
                        <Text style={[styles.tagText, styles.tagMissingText]}>NO RECEIPT</Text>
                      </View>
                    )}
                  </View>
                </View>
                <View style={styles.billAmounts}>
                  <Text style={styles.billAmount}>
                    {b.amount} {b.currency}
                  </Text>
                  <Text style={styles.billUsd}>${b.amount_usd}</Text>
                </View>
                {!isLocked ? (
                  <TouchableOpacity
                    onPress={() => handleDeleteBill(b)}
                    style={styles.removeBtn}
                    hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
                  >
                    <Ionicons name="trash-outline" size={17} color={colors.red} />
                  </TouchableOpacity>
                ) : null}
              </TouchableOpacity>
            );
          })
        )}

        {!isLocked ? (
          <TouchableOpacity style={styles.addBtn} onPress={() => handleOpenSheet(null)}>
            <Ionicons name="add" size={19} color={colors.primary} />
            <Text style={styles.addBtnText}>Add Bill</Text>
          </TouchableOpacity>
        ) : null}

        {items.length > 0 ? (
          <View style={styles.totalRow}>
            <Text style={styles.totalLabel}>Total</Text>
            <Text style={styles.totalValue}>${totalUsd.toFixed(2)} USD</Text>
          </View>
        ) : null}

        {missingReceipts > 0 && !isLocked ? (
          <Text style={styles.warn}>
            {missingReceipts === 1
              ? '1 bill has no receipt. Attach one before submitting.'
              : `${missingReceipts} bills have no receipt. Attach one to each before submitting.`}
          </Text>
        ) : null}

        {expenseId && !isLocked ? (
          <TouchableOpacity style={styles.deleteClaim} onPress={handleDeleteClaim}>
            <Text style={styles.deleteClaimText}>Delete this claim</Text>
          </TouchableOpacity>
        ) : null}
      </ScrollView>

      {!isLocked ? (
        <View style={styles.footer}>
          <TouchableOpacity
            style={[styles.footerBtn, styles.secondary]}
            onPress={handleSaveHeader}
            disabled={saving}
          >
            <Text style={styles.secondaryText}>{saving ? 'Saving…' : 'Save Draft'}</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.footerBtn, styles.primary, !canSubmit ? styles.disabled : null]}
            onPress={handleSubmit}
            disabled={saving || !canSubmit}
          >
            <Text style={styles.primaryText}>Submit</Text>
          </TouchableOpacity>
        </View>
      ) : null}

      <BillSheet
        visible={sheetOpen}
        empId={empId}
        bill={editingBill}
        currencies={currencies}
        saving={billSaving}
        onSave={handleSaveBill}
        onClose={() => {
          setSheetOpen(false);
          setEditingBill(null);
        }}
      />
    </View>
  );
}

function createStyles(colors) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.bg },
    centre: { flex: 1, alignItems: 'center', justifyContent: 'center', backgroundColor: colors.bg },
    sectionLabel: {
      fontSize: 11,
      fontWeight: '800',
      color: colors.textFaint,
      textTransform: 'uppercase',
      letterSpacing: 0.4,
      marginBottom: 8,
      marginTop: 4,
    },
    statusRow: { flexDirection: 'row', alignItems: 'center', gap: 10, marginBottom: 12 },
    statusText: { fontSize: 13, fontWeight: '700', color: colors.primary },
    lockedNote: { fontSize: 12, color: colors.textMuted },
    card: {
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.md,
      padding: 14,
      marginBottom: 20,
      ...shadow.card,
    },
    label: { fontSize: 12, fontWeight: '700', color: colors.textMuted, marginBottom: 6, marginTop: 10 },
    input: {
      backgroundColor: colors.bg,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.sm,
      paddingHorizontal: 12,
      paddingVertical: 11,
      fontSize: 15,
      color: colors.text,
    },
    readonlyRow: { flexDirection: 'row', gap: 12, marginTop: 16 },
    readonlyLabel: { fontSize: 11, color: colors.textFaint, fontWeight: '700' },
    readonlyValue: { fontSize: 13, color: colors.text, marginTop: 3 },
    billsHeader: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' },
    billCount: { fontSize: 11.5, color: colors.textFaint, fontWeight: '700' },
    empty: {
      alignItems: 'center',
      padding: 26,
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      borderWidth: 1,
      borderColor: colors.border,
      borderStyle: 'dashed',
    },
    emptyText: { fontSize: 14, fontWeight: '700', color: colors.text, marginTop: 8 },
    emptyHint: { fontSize: 12, color: colors.textFaint, marginTop: 3 },
    billRow: {
      flexDirection: 'row',
      alignItems: 'center',
      gap: 10,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.md,
      padding: 12,
      marginBottom: 8,
    },
    billNo: {
      width: 24,
      height: 24,
      borderRadius: 8,
      backgroundColor: colors.primaryTint,
      alignItems: 'center',
      justifyContent: 'center',
    },
    billNoText: { fontSize: 11.5, fontWeight: '800', color: colors.primary },
    billType: { fontSize: 14, fontWeight: '700', color: colors.text },
    billMeta: { fontSize: 11.5, color: colors.textMuted, marginTop: 2 },
    billTags: { flexDirection: 'row', gap: 6, marginTop: 6 },
    tag: {
      paddingHorizontal: 7,
      paddingVertical: 2,
      borderRadius: 999,
      backgroundColor: colors.primaryTint,
    },
    tagText: { fontSize: 9.5, fontWeight: '800', color: colors.primary },
    tagMissing: { backgroundColor: colors.amberTint },
    tagMissingText: { color: colors.status.REVISION_REQUESTED.text },
    billAmounts: { alignItems: 'flex-end' },
    billAmount: { fontSize: 13.5, fontWeight: '700', color: colors.text },
    billUsd: { fontSize: 11.5, color: colors.textMuted, marginTop: 2 },
    removeBtn: { paddingLeft: 4 },
    addBtn: {
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'center',
      gap: 6,
      borderWidth: 1,
      borderStyle: 'dashed',
      borderColor: colors.primary,
      borderRadius: radius.md,
      paddingVertical: 13,
      marginTop: 4,
    },
    addBtnText: { color: colors.primary, fontWeight: '700', fontSize: 14 },
    totalRow: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      alignItems: 'center',
      marginTop: 18,
      paddingTop: 14,
      borderTopWidth: 1,
      borderTopColor: colors.border,
    },
    totalLabel: { fontSize: 13, fontWeight: '700', color: colors.textMuted },
    totalValue: { fontSize: 18, fontWeight: '800', color: colors.text },
    warn: {
      marginTop: 12,
      fontSize: 12.5,
      color: colors.status.REVISION_REQUESTED.text,
      backgroundColor: colors.amberTint,
      borderRadius: radius.sm,
      padding: 10,
    },
    error: {
      color: colors.red,
      backgroundColor: colors.redTint,
      borderRadius: radius.sm,
      padding: 11,
      fontSize: 13,
      marginBottom: 12,
    },
    deleteClaim: { marginTop: 26, alignItems: 'center', padding: 12 },
    deleteClaimText: { color: colors.red, fontSize: 13.5, fontWeight: '600' },
    footer: {
      flexDirection: 'row',
      gap: 10,
      padding: 12,
      paddingBottom: 26,
      backgroundColor: colors.surface,
      borderTopWidth: 1,
      borderTopColor: colors.border,
    },
    footerBtn: { flex: 1, borderRadius: radius.sm, paddingVertical: 14, alignItems: 'center' },
    secondary: { backgroundColor: colors.bg, borderWidth: 1, borderColor: colors.borderStrong },
    secondaryText: { color: colors.text, fontWeight: '700', fontSize: 15 },
    primary: { backgroundColor: colors.primary },
    primaryText: { color: '#fff', fontWeight: '700', fontSize: 15 },
    disabled: { opacity: 0.45 },
  });
}
