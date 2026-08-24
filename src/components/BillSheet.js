// One bill on a claim — the add/edit sheet.
//
// A claim (EXPENSES) holds many bills (EXPENSE_ITEMS). This is the form for a
// single bill; the claim header lives in AddEditExpenseScreen. See
// MULTI_BILL_PLAN.md.
//
// ELEVEN FIELDS, ten of them required. Bill No is the only optional one, and
// the receipt is required to SUBMIT rather than to save — so you can type the
// amounts now and hunt for the photo later without losing the typing.
//
//
// TWO THINGS THIS SCREEN DOES NOT DO, DELIBERATELY
// ------------------------------------------------
// 1. It never computes the conversion rate or the USD amount. Both are shown
//    read-only, fetched from GET /expenses/exchange-rate, and the server
//    recomputes them on save from the currency, amount and from_date it stored.
//    A rate the client could set is a reimbursement figure the client could
//    set.
//
// 2. It does not upload the receipt. The picked file is handed back to the
//    caller, which saves the bill first and then uploads against the id it
//    gets — the same two-step a brand-new expense has always used. That is what
//    makes "attach before saving" work: the file sits in state until there is a
//    row to attach it to.

import React, { useState, useEffect, useMemo, useCallback } from 'react';
import {
  ActivityIndicator,
  Modal,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import * as DocumentPicker from 'expo-document-picker';
import { useTheme } from '../ThemeContext';
import { radius } from '../theme';
import PickerField from './PickerField';
import DateField from './DateField';
import { EXPENSE_TYPES } from '../constants/expenseTypes';
import { getExchangeRate, isoFromMDY } from '../api/client';
import { showAlert } from '../utils/alert';

const ALLOWED_EXTENSIONS = ['pdf', 'jpg', 'jpeg', 'png', 'xlsx', 'xls', 'csv', 'rar'];
const MAX_BYTES = 1 * 1024 * 1024; // 1 MB — matches the handler's c_max_bytes

const EMPTY = {
  bill_no: '',
  bill_date: '',
  type: '',
  description: '',
  from_date: '',
  to_date: '',
  currency: 'INR',
  amount: '',
};

export default function BillSheet({
  visible,
  empId,
  bill,            // existing bill from GET :id/items, or null to add
  currencies,
  saving,
  onSave,          // (fields, pickedFile) => Promise
  onClose,
}) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);

  const [f, setF] = useState(EMPTY);
  const [picked, setPicked] = useState(null);   // newly chosen file, not yet uploaded
  const [rate, setRate] = useState(null);
  const [rateError, setRateError] = useState(null);
  const [rateLoading, setRateLoading] = useState(false);
  const [error, setError] = useState(null);

  const isEdit = !!(bill && bill.id);

  // Reset every time the sheet opens, so a cancelled edit never bleeds into
  // the next bill.
  useEffect(() => {
    if (!visible) return;
    setError(null);
    setPicked(null);
    setRate(null);
    setRateError(null);
    if (bill) {
      setF({
        bill_no: bill.bill_no || '',
        // The API returns MM/DD/YYYY on reads and wants ISO on writes; the
        // conversion lives in client.js, not here.
        bill_date: bill.bill_date || '',
        type: bill.type || '',
        description: bill.description || '',
        from_date: bill.from_date || '',
        to_date: bill.to_date || '',
        currency: bill.currency || 'INR',
        amount: bill.amount != null ? String(bill.amount) : '',
      });
      if (bill.exchange_rate != null) {
        setRate({ exchange_rate: bill.exchange_rate, amount_usd: bill.amount_usd });
      }
    } else {
      setF(EMPTY);
    }
  }, [visible, bill]);

  const set = useCallback((k, v) => setF((prev) => ({ ...prev, [k]: v })), []);

  // Live conversion preview. Keyed on from_date as well as currency and
  // amount, because from_date decides WHICH MONTH's rate applies — a July
  // hotel and an August taxi in the same claim can price differently.
  //
  // Debounced: this fires on every keystroke in the amount field.
  useEffect(() => {
    if (!f.amount || !f.currency || !f.from_date) {
      setRate(null);
      setRateError(null);
      return;
    }
    let cancelled = false;
    setRateLoading(true);
    const timer = setTimeout(() => {
      getExchangeRate(empId, f.currency, isoFromMDY(f.from_date), f.amount)
        .then((data) => {
          if (cancelled) return;
          setRate(data);
          setRateError(null);
        })
        .catch((e) => {
          if (cancelled) return;
          setRate(null);
          setRateError(e.message || 'Could not fetch the conversion rate.');
        })
        .finally(() => {
          if (!cancelled) setRateLoading(false);
        });
    }, 400);
    return () => {
      cancelled = true;
      clearTimeout(timer);
      setRateLoading(false);
    };
  }, [empId, f.amount, f.currency, f.from_date]);

  async function handlePick() {
    try {
      const res = await DocumentPicker.getDocumentAsync({ copyToCacheDirectory: true });
      if (res.canceled) return;
      const file = res.assets && res.assets[0];
      if (!file) return;

      const ext = String(file.name || '').split('.').pop().toLowerCase();
      if (!ALLOWED_EXTENSIONS.includes(ext)) {
        showAlert('File type not allowed', `Use one of: ${ALLOWED_EXTENSIONS.join(', ')}.`);
        return;
      }
      // Checked here as well as server-side so the person finds out before
      // waiting for a 1 MB upload to be rejected.
      if (file.size && file.size > MAX_BYTES) {
        showAlert('File too large', 'Receipts must be 1 MB or smaller.');
        return;
      }
      setPicked(file);
    } catch (e) {
      showAlert('Could not open the file picker', e.message || 'Please try again.');
    }
  }

  function validate() {
    const missing = [];
    if (!f.bill_date)   missing.push('Bill Date');
    if (!f.type)        missing.push('Type');
    if (!f.description) missing.push('Description');
    if (!f.from_date)   missing.push('From Date');
    if (!f.to_date)     missing.push('To Date');
    if (!f.currency)    missing.push('Currency');
    if (!f.amount)      missing.push('Amount');
    if (missing.length) return `Please fill in: ${missing.join(', ')}.`;

    if (Number(f.amount) <= 0) return 'Amount must be greater than zero.';

    const from = isoFromMDY(f.from_date);
    const to = isoFromMDY(f.to_date);
    if (from && to && to < from) return 'To Date cannot be before From Date.';

    // The server rejects a bill it cannot price (EXCHANGE_RATE is NOT NULL),
    // so catch it here rather than letting the save fail.
    if (rateError) return rateError;
    return null;
  }

  async function handleSave() {
    const problem = validate();
    if (problem) {
      setError(problem);
      return;
    }
    setError(null);
    // ISO out — the item endpoints expect it. exchange_rate and amount_usd are
    // deliberately NOT sent; the server derives them.
    await onSave(
      {
        bill_no: f.bill_no || null,
        bill_date: isoFromMDY(f.bill_date),
        type: f.type,
        description: f.description,
        from_date: isoFromMDY(f.from_date),
        to_date: isoFromMDY(f.to_date),
        currency: f.currency,
        amount: Number(f.amount),
      },
      picked
    );
  }

  const currencyOptions = (currencies && currencies.length
    ? currencies
    : [{ currency: 'INR' }]
  ).map((c) => ({ id: c.currency, label: c.currency }));

  const receiptLabel = picked
    ? picked.name
    : bill && bill.attachment_filename
    ? bill.attachment_filename
    : null;

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity onPress={onClose} disabled={saving} style={styles.headerBtn}>
            <Text style={styles.cancel}>Cancel</Text>
          </TouchableOpacity>
          <Text style={styles.title}>{isEdit ? `Bill ${bill.item_no}` : 'Add Bill'}</Text>
          <TouchableOpacity onPress={handleSave} disabled={saving} style={styles.headerBtn}>
            {saving ? (
              <ActivityIndicator color={colors.primary} />
            ) : (
              <Text style={styles.save}>Save</Text>
            )}
          </TouchableOpacity>
        </View>

        <ScrollView contentContainerStyle={{ padding: 16, paddingBottom: 48 }}>
          {error ? <Text style={styles.error}>{error}</Text> : null}

          <Text style={styles.label}>Bill No <Text style={styles.optional}>(optional)</Text></Text>
          <TextInput
            style={styles.input}
            value={f.bill_no}
            onChangeText={(v) => set('bill_no', v)}
            placeholder="e.g. INV-2214"
            placeholderTextColor={colors.textFaint}
          />

          <Text style={styles.label}>Bill Date</Text>
          <DateField value={f.bill_date} onChange={(v) => set('bill_date', v)} fieldStyle={styles.input} />

          <Text style={styles.label}>Type</Text>
          <PickerField
            options={EXPENSE_TYPES}
            valueKey="id"
            labelKey="label"
            value={f.type}
            onSelect={(v) => set('type', v)}
            placeholder="Select a type"
            fieldStyle={styles.input}
          />

          <Text style={styles.label}>Description</Text>
          <TextInput
            style={[styles.input, styles.multiline]}
            value={f.description}
            onChangeText={(v) => set('description', v)}
            placeholder="What was this for?"
            placeholderTextColor={colors.textFaint}
            multiline
          />

          <View style={styles.row}>
            <View style={styles.rowItem}>
              <Text style={styles.label}>From Date</Text>
              <DateField value={f.from_date} onChange={(v) => set('from_date', v)} fieldStyle={styles.input} />
            </View>
            <View style={styles.rowItem}>
              <Text style={styles.label}>To Date</Text>
              <DateField value={f.to_date} onChange={(v) => set('to_date', v)} fieldStyle={styles.input} />
            </View>
          </View>

          <View style={styles.row}>
            <View style={{ width: 110 }}>
              <Text style={styles.label}>Currency</Text>
              <PickerField
                options={currencyOptions}
                valueKey="id"
                labelKey="label"
                value={f.currency}
                onSelect={(v) => set('currency', v)}
                placeholder="CUR"
                fieldStyle={styles.input}
              />
            </View>
            <View style={styles.rowItem}>
              <Text style={styles.label}>Expense Amount</Text>
              <TextInput
                style={styles.input}
                value={f.amount}
                onChangeText={(v) => set('amount', v.replace(/[^0-9.]/g, ''))}
                keyboardType="decimal-pad"
                placeholder="0.00"
                placeholderTextColor={colors.textFaint}
              />
            </View>
          </View>

          {/* Read-only, and visibly so. Both come from the server. */}
          <View style={styles.computed}>
            <View style={styles.computedRow}>
              <Text style={styles.computedLabel}>Conversion Rate</Text>
              <Text style={styles.computedValue}>
                {rateLoading ? '…' : rate ? `1 ${f.currency} = ${rate.exchange_rate} USD` : '—'}
              </Text>
            </View>
            <View style={styles.computedRow}>
              <Text style={styles.computedLabel}>Amount</Text>
              <Text style={[styles.computedValue, styles.computedStrong]}>
                {rateLoading ? '…' : rate && rate.amount_usd != null ? `${rate.amount_usd} USD` : '—'}
              </Text>
            </View>
            <Text style={styles.computedNote}>
              Set by the server from the currency and From Date. Not editable.
            </Text>
            {rate && rate.is_fallback === 'Y' ? (
              <Text style={styles.warn}>
                No rate published for {rate.requested_month || 'that month'} — using{' '}
                {rate.rate_month || 'the latest available'}.
              </Text>
            ) : null}
            {rateError ? <Text style={styles.error}>{rateError}</Text> : null}
          </View>

          <Text style={styles.label}>Upload Receipt</Text>
          <TouchableOpacity style={styles.fileBtn} onPress={handlePick} disabled={saving}>
            <Ionicons
              name={receiptLabel ? 'document-attach' : 'cloud-upload-outline'}
              size={18}
              color={colors.primary}
            />
            <Text style={styles.fileText} numberOfLines={1}>
              {receiptLabel || 'Choose a file (pdf, jpg, png, xlsx, xls, csv, rar)'}
            </Text>
          </TouchableOpacity>
          {picked ? (
            <Text style={styles.hint}>Uploads when you save this bill.</Text>
          ) : (
            <Text style={styles.hint}>
              Optional now — required on every bill before you can submit the claim.
            </Text>
          )}
        </ScrollView>
      </View>
    </Modal>
  );
}

function createStyles(colors) {
  return StyleSheet.create({
    container: { flex: 1, backgroundColor: colors.bg },
    header: {
      flexDirection: 'row',
      alignItems: 'center',
      justifyContent: 'space-between',
      paddingHorizontal: 12,
      paddingTop: Platform.OS === 'ios' ? 52 : 18,
      paddingBottom: 12,
      borderBottomWidth: 1,
      borderBottomColor: colors.border,
      backgroundColor: colors.surface,
    },
    headerBtn: { minWidth: 64, paddingVertical: 6 },
    title: { fontSize: 16, fontWeight: '800', color: colors.text },
    cancel: { color: colors.textMuted, fontSize: 15 },
    save: { color: colors.primary, fontSize: 15, fontWeight: '700', textAlign: 'right' },
    label: {
      fontSize: 12,
      fontWeight: '700',
      color: colors.textMuted,
      marginBottom: 6,
      marginTop: 14,
    },
    optional: { fontWeight: '500', color: colors.textFaint },
    input: {
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.sm,
      paddingHorizontal: 12,
      paddingVertical: 11,
      fontSize: 15,
      color: colors.text,
    },
    multiline: { minHeight: 70, textAlignVertical: 'top' },
    row: { flexDirection: 'row', gap: 10 },
    rowItem: { flex: 1 },
    computed: {
      marginTop: 18,
      backgroundColor: colors.primaryTint,
      borderRadius: radius.sm,
      padding: 12,
    },
    computedRow: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      alignItems: 'center',
      paddingVertical: 3,
    },
    computedLabel: { fontSize: 13, color: colors.textMuted, fontWeight: '600' },
    computedValue: { fontSize: 13.5, color: colors.text, fontWeight: '700' },
    computedStrong: { fontSize: 15, color: colors.primary },
    computedNote: { fontSize: 11, color: colors.textFaint, marginTop: 6 },
    warn: { fontSize: 11.5, color: colors.status.REVISION_REQUESTED.text, marginTop: 6 },
    fileBtn: {
      flexDirection: 'row',
      alignItems: 'center',
      gap: 8,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderStyle: 'dashed',
      borderColor: colors.borderStrong,
      borderRadius: radius.sm,
      padding: 13,
    },
    fileText: { flex: 1, fontSize: 13.5, color: colors.text },
    hint: { fontSize: 11.5, color: colors.textFaint, marginTop: 6 },
    error: {
      color: colors.red,
      backgroundColor: colors.redTint,
      borderRadius: radius.sm,
      padding: 10,
      fontSize: 13,
      marginTop: 10,
    },
  });
}
