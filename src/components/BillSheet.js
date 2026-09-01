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
import {
  getExchangeRate,
  isoFromMDY,
  mdyFromISO,
  scanReceipt,
  recordScanOutcome,
} from '../api/client';
import { showAlert } from '../utils/alert';
import { shrinkForAttachment } from '../utils/compressImage';

// Only these can be scanned. The stored-receipt list is wider on purpose -- a
// spreadsheet or a .rar is a legitimate thing to keep on file and nothing a
// vision model can read, and offering to scan one would only produce a
// confident answer about nothing. Mirrors the server's own check in db/79.
const SCANNABLE = ['pdf', 'jpg', 'jpeg', 'png', 'webp', 'heic'];

// The fields the scan may fill, in the order they appear in the form, so the
// review sheet reads top-to-bottom like the thing it is about to change.
const SCAN_FIELDS = [
  { key: 'bill_no',     label: 'Bill No' },
  { key: 'bill_date',   label: 'Bill Date' },
  { key: 'type',        label: 'Type' },
  { key: 'description', label: 'Description' },
  // Added in prompt v2 (db/79d). An Airtel wifi bill prints a statement period,
  // and that is what these two mean -- before v2 the schema had no such field,
  // so a month of internet was filled in as a one-day expense.
  { key: 'from_date',   label: 'From Date' },
  { key: 'to_date',     label: 'To Date' },
  { key: 'currency',    label: 'Currency' },
  { key: 'amount',      label: 'Expense Amount' },
];

const ALLOWED_EXTENSIONS = ['pdf', 'jpg', 'jpeg', 'png', 'xlsx', 'xls', 'csv', 'rar'];
// TWO DIFFERENT CEILINGS, and conflating them is what stopped the scan button
// appearing at all.
//
//   ATTACH: 1 MB. What the receipt endpoint will STORE (c_max_bytes in db/65).
//   SCAN:   6 MB. What the scan endpoint will READ (db/79). Nothing is kept, so
//           the limit is about request size, not storage.
//
// A phone camera produces 3-5 MB. Rejecting those at pick time meant `picked`
// was never set, so there was nothing to offer a scan for -- the feature was
// unreachable for exactly the files it exists to handle.
const MAX_BYTES = 1 * 1024 * 1024;      // attach
const MAX_SCAN_BYTES = 6 * 1024 * 1024; // scan

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
  // TWO FILES, deliberately.
  //   picked     -- what gets ATTACHED. Compressed to fit the 1 MB limit.
  //   scanSource -- what gets READ by the AI. The original, full quality.
  // They are the same object unless compression happened. The AI gets the good
  // copy because a receipt total is small print, and the stored copy is the one
  // that has to fit.
  const [picked, setPicked] = useState(null);   // newly chosen file, not yet uploaded
  const [scanSource, setScanSource] = useState(null);
  const [shrinking, setShrinking] = useState(false);
  const [shrankFrom, setShrankFrom] = useState(null);   // original size in bytes
  const [rate, setRate] = useState(null);
  const [rateError, setRateError] = useState(null);
  const [rateLoading, setRateLoading] = useState(false);
  const [error, setError] = useState(null);

  // ---- AI receipt scan ----
  const [scanning, setScanning] = useState(false);
  const [scan, setScan] = useState(null);        // { scan_id, fields } awaiting review
  // What was applied, and what it was applied as. Compared at save time so we
  // can tell APPLIED from EDITED -- the difference between "this saved me
  // typing" and "this was close but wrong", which is the only number that says
  // whether the feature earns its keep.
  const [applied, setApplied] = useState(null);  // { scan_id, values }

  const isEdit = !!(bill && bill.id);

  // Reset every time the sheet opens, so a cancelled edit never bleeds into
  // the next bill.
  useEffect(() => {
    if (!visible) return;
    setError(null);
    setPicked(null);
    setRate(null);
    setRateError(null);
    setScan(null);
    setApplied(null);
    setScanning(false);
    setScanSource(null);
    setShrinking(false);
    setShrankFrom(null);
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
      // A big photo is still worth accepting if it can be SCANNED: the fields
      // are the valuable part, and the receipt itself is only required at
      // submit, not at save. So the ceiling here is the scan limit for images
      // and the attach limit for everything else.
      const scannable = SCANNABLE.includes(ext);
      const ceiling = scannable ? MAX_SCAN_BYTES : MAX_BYTES;
      if (file.size && file.size > ceiling) {
        showAlert(
          'File too large',
          scannable
            ? 'Photos must be 6 MB or smaller. Take it again at a lower resolution.'
            : 'Receipts must be 1 MB or smaller.'
        );
        return;
      }
      // The original is always what the AI reads.
      setScanSource(file);

      if (!file.size || file.size <= MAX_BYTES) {
        setPicked(file);
        setShrankFrom(null);
        return;
      }

      // Too big to store. Try to make a copy that fits rather than making the
      // person photograph the receipt a second time.
      setShrinking(true);
      try {
        const res = await shrinkForAttachment(file, MAX_BYTES);
        setPicked(res.file);
        setShrankFrom(res.compressed ? res.originalSize : null);
      } finally {
        setShrinking(false);
      }
    } catch (e) {
      showAlert('Could not open the file picker', e.message || 'Please try again.');
    }
  }

  // ---- AI scan ----
  //
  // Explicit button rather than firing on pick. Scanning costs money per call
  // and someone attaching a file they have already typed up should not pay for
  // a read nobody asked for. It also means the person can scan twice if the
  // first photo was bad.
  const canScan = useMemo(() => {
    const f = scanSource || picked;
    if (!f) return false;
    const ext = String(f.name || '').split('.').pop().toLowerCase();
    return SCANNABLE.includes(ext);
  }, [scanSource, picked]);

  // Over the ATTACH limit but within the SCAN limit. Scannable, not storable.
  // The bill can still be saved -- a receipt is only required to SUBMIT -- so
  // this is a warning, not an error.
  const tooBigToAttach = !!(picked && picked.size && picked.size > MAX_BYTES);

  async function handleScan() {
    if (!scanSource && !picked) return;
    setScanning(true);
    setError(null);
    try {
      const res = await scanReceipt(empId, scanSource || picked);
      // The endpoint answers 200 for an unreadable photo too -- the request was
      // fine, the image was not. So the error lives in the body, not the status.
      if (!res || res.error || !res.fields) {
        showAlert(
          'Could not read that receipt',
          (res && res.error) ||
            'Nothing legible came back. Fill the bill in by hand — the file is still attached.'
        );
        return;
      }
      setScan({ scan_id: res.scan_id, fields: res.fields });
    } catch (e) {
      showAlert('Could not read that receipt', e.message || 'Please fill the bill in by hand.');
    } finally {
      setScanning(false);
    }
  }

  // What the scan proposes, filtered to what this form can actually accept.
  //
  // A type or currency the model invents is dropped rather than shown: offering
  // to apply a value the picker cannot hold would put the form in a state the
  // person could not then save, and they would have no idea why.
  const proposals = useMemo(() => {
    if (!scan || !scan.fields) return [];
    const s = scan.fields;
    const allowedTypes = EXPENSE_TYPES.map((t) => t.id);
    const allowedCur = (currencies && currencies.length ? currencies : [{ currency: 'INR' }])
      .map((c) => c.currency);

    return SCAN_FIELDS.map(({ key, label }) => {
      let value = s[key];
      let dropped = null;

      if ((key === 'bill_date' || key === 'from_date' || key === 'to_date') && value) {
        value = mdyFromISO(value);
      }
      if (key === 'amount' && value != null) value = String(value);
      if (key === 'type' && value && !allowedTypes.includes(value)) {
        dropped = value; value = null;
      }
      if (key === 'currency' && value && !allowedCur.includes(value)) {
        dropped = value; value = null;
      }

      return {
        key,
        label,
        value: value === '' ? null : value,
        dropped,
        replaces: f[key] && value && String(f[key]) !== String(value) ? f[key] : null,
      };
    });
  }, [scan, currencies, f]);

  function applyScan() {
    const next = { ...f };
    const values = {};
    proposals.forEach((p) => {
      if (p.value == null) return;
      next[p.key] = p.value;
      values[p.key] = p.value;
    });

    // Fall back to the bill date ONLY where the scan gave nothing. Since prompt
    // v2 a null here means "this document states no period", which is the true
    // answer for a taxi fare or a meal -- so the same-day default is right for
    // those and no longer overrides a period the document actually printed.
    if (next.bill_date) {
      if (!next.from_date) next.from_date = next.bill_date;
      if (!next.to_date) next.to_date = next.bill_date;
    }

    setF(next);
    setApplied({ scan_id: scan.scan_id, values });
    setScan(null);
  }

  function discardScan() {
    recordScanOutcome(empId, scan.scan_id, 'DISCARDED');
    setScan(null);
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

    // Was the scan any use? Answered here rather than at apply time, because
    // "applied then corrected" only becomes visible once the person stops
    // typing. Fire and forget -- recordScanOutcome swallows everything.
    if (applied) {
      const changed = Object.keys(applied.values).some(
        (k) => String(f[k] ?? '') !== String(applied.values[k] ?? '')
      );
      recordScanOutcome(empId, applied.scan_id, changed ? 'EDITED' : 'APPLIED');
    }

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
      // Only pass the file if it is small enough to STORE. A 4 MB photo has
      // already done its job by then -- it filled the form -- and sending it
      // would earn a 400 from the receipt endpoint and lose the typing with it.
      tooBigToAttach ? null : picked
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
          {shrinking ? (
            <Text style={styles.hint}>Resizing the photo so it can be attached…</Text>
          ) : null}

          {/* Said, not silent. The stored copy is not the file they chose, and
              anyone comparing the two later deserves to know why. */}
          {!shrinking && shrankFrom ? (
            <Text style={styles.hint}>
              Resized from {(shrankFrom / (1024 * 1024)).toFixed(1)} MB to{' '}
              {(picked.size / 1024).toFixed(0)} KB to fit the 1 MB limit. The full
              quality photo is still what gets read below.
            </Text>
          ) : null}

          {picked && !tooBigToAttach && !shrinking && !shrankFrom ? (
            <Text style={styles.hint}>Uploads when you save this bill.</Text>
          ) : null}

          {/* Only reachable now if compression could not get it under 1 MB --
              a PDF, or an image that resists. Rare, but it must still say so
              rather than failing at save. */}
          {tooBigToAttach && !shrinking ? (
            <Text style={styles.appliedNote}>
              This file is {(picked.size / (1024 * 1024)).toFixed(1)} MB and could not
              be made smaller, so it will not be attached. You can still read the
              fields off it below, then attach a smaller file before submitting.
            </Text>
          ) : null}

          {!picked ? (
            <Text style={styles.hint}>
              Optional now — required on every bill before you can submit the claim.
            </Text>
          ) : null}

          {/* Picked, but nothing a vision model can read. Said out loud, because
              a button that simply is not there looks the same as one that is
              broken -- which is exactly how this came up. */}
          {picked && !canScan ? (
            <Text style={styles.hint}>
              This file can be attached but not read automatically — scanning works
              on photos and PDFs ({SCANNABLE.join(', ')}).
            </Text>
          ) : null}

          {/* Offered only for a photo or PDF, and only once one is picked.
              Deliberately a button and not automatic: a scan costs a paid API
              call, and someone attaching a file to a bill they have already
              filled in should not pay for a read they did not ask for. */}
          {canScan ? (
            <TouchableOpacity
              style={styles.scanBtn}
              onPress={handleScan}
              disabled={scanning || saving || shrinking}
            >
              {scanning ? (
                <ActivityIndicator color={colors.primary} />
              ) : (
                <Ionicons name="sparkles-outline" size={18} color={colors.primary} />
              )}
              <Text style={styles.scanText}>
                {scanning ? 'Reading the receipt…' : 'Fill the form from this receipt'}
              </Text>
            </TouchableOpacity>
          ) : null}
          {canScan && !scanning ? (
            <Text style={styles.hint}>
              Reads the photo and suggests the fields. You see everything it read
              before any of it goes in.
            </Text>
          ) : null}

          {applied ? (
            <Text style={styles.appliedNote}>
              Some fields were filled from the receipt. Check them — especially the
              amount — before saving.
            </Text>
          ) : null}
        </ScrollView>
      </View>

      {/* ---- review sheet ---- */}
      {/*
          Nothing reaches the form until Apply. That was a deliberate choice
          while accuracy is unproven: the model is small, and a plausible wrong
          total that nobody notices is far worse than six fields typed by hand.
      */}
      <Modal visible={!!scan} animationType="slide" transparent onRequestClose={discardScan}>
        <View style={styles.reviewBackdrop}>
          <View style={styles.reviewCard}>
            <Text style={styles.reviewTitle}>What the receipt says</Text>
            <Text style={styles.reviewSub}>
              Read from your photo. Nothing has changed in the form yet.
            </Text>

            <ScrollView style={{ maxHeight: 340 }}>
              {proposals.map((p) => (
                <View key={p.key} style={styles.reviewRow}>
                  <Text style={styles.reviewLabel}>{p.label}</Text>
                  {p.value != null ? (
                    <Text style={styles.reviewValue}>{p.value}</Text>
                  ) : (
                    <Text style={styles.reviewEmpty}>
                      {/* A null is the model saying it could not read this, which
                          is the answer we asked it for. Saying so is better than
                          a blank line the person has to interpret. */}
                      couldn’t read this
                    </Text>
                  )}
                  {p.replaces ? (
                    <Text style={styles.reviewReplaces}>replaces “{p.replaces}”</Text>
                  ) : null}
                  {p.dropped ? (
                    <Text style={styles.reviewReplaces}>
                      read “{p.dropped}”, which is not one of the allowed values — ignored
                    </Text>
                  ) : null}
                </View>
              ))}

              {/* Said before Apply, not discovered after it. */}
              {scan && scan.fields && !scan.fields.from_date && !scan.fields.to_date ? (
                <Text style={styles.reviewFoot}>
                  No billing period printed on this document, so From and To Date
                  will both be set to the bill date.
                </Text>
              ) : null}

              {scan && scan.fields && scan.fields.vendor ? (
                <View style={styles.reviewRow}>
                  <Text style={styles.reviewLabel}>Vendor</Text>
                  <Text style={styles.reviewValue}>{scan.fields.vendor}</Text>
                  <Text style={styles.reviewReplaces}>
                    not a field on the bill — shown so you can tell this is the right receipt
                  </Text>
                </View>
              ) : null}

              {scan && scan.fields && scan.fields.unreadable ? (
                <Text style={styles.reviewWarn}>{scan.fields.unreadable}</Text>
              ) : null}
            </ScrollView>

            <View style={styles.reviewActions}>
              <TouchableOpacity onPress={discardScan} style={styles.reviewCancel}>
                <Text style={styles.reviewCancelText}>Discard</Text>
              </TouchableOpacity>
              <TouchableOpacity onPress={applyScan} style={styles.reviewApply}>
                <Text style={styles.reviewApplyText}>Apply</Text>
              </TouchableOpacity>
            </View>
            <Text style={styles.reviewFoot}>
              The conversion rate and USD amount are always worked out by the
              server, never by the AI.
            </Text>
          </View>
        </View>
      </Modal>
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

    // ---- AI scan ----
    scanBtn: {
      flexDirection: 'row',
      alignItems: 'center',
      gap: 10,
      marginTop: 12,
      borderWidth: 1,
      borderColor: colors.primary,
      borderRadius: radius.sm,
      padding: 13,
      backgroundColor: colors.surface,
    },
    scanText: { flex: 1, fontSize: 13.5, color: colors.primary, fontWeight: '700' },
    appliedNote: {
      fontSize: 11.5,
      lineHeight: 17,
      color: colors.amber,
      backgroundColor: colors.amberTint,
      borderRadius: radius.sm,
      paddingVertical: 7,
      paddingHorizontal: 10,
      marginTop: 12,
    },

    reviewBackdrop: {
      flex: 1,
      backgroundColor: 'rgba(0,0,0,0.45)',
      justifyContent: 'flex-end',
    },
    reviewCard: {
      backgroundColor: colors.bg,
      borderTopLeftRadius: radius.lg,
      borderTopRightRadius: radius.lg,
      padding: 18,
      paddingBottom: Platform.OS === 'ios' ? 34 : 18,
    },
    reviewTitle: { fontSize: 16, fontWeight: '800', color: colors.text },
    reviewSub: { fontSize: 12, color: colors.textMuted, marginTop: 4, marginBottom: 12 },
    reviewRow: {
      borderTopWidth: 1,
      borderTopColor: colors.border,
      paddingVertical: 9,
    },
    reviewLabel: { fontSize: 11, fontWeight: '700', color: colors.textMuted },
    reviewValue: { fontSize: 15, color: colors.text, marginTop: 2 },
    reviewEmpty: { fontSize: 14, color: colors.textFaint, marginTop: 2, fontStyle: 'italic' },
    reviewReplaces: { fontSize: 11, color: colors.textFaint, marginTop: 3 },
    reviewWarn: {
      fontSize: 12,
      lineHeight: 18,
      color: colors.amber,
      backgroundColor: colors.amberTint,
      borderRadius: radius.sm,
      padding: 10,
      marginTop: 12,
    },
    reviewActions: { flexDirection: 'row', gap: 10, marginTop: 16 },
    reviewCancel: {
      flex: 1,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.sm,
      paddingVertical: 13,
      alignItems: 'center',
    },
    reviewCancelText: { color: colors.textMuted, fontSize: 14, fontWeight: '600' },
    reviewApply: {
      flex: 1,
      backgroundColor: colors.primary,
      borderRadius: radius.sm,
      paddingVertical: 13,
      alignItems: 'center',
    },
    reviewApplyText: { color: '#fff', fontSize: 14, fontWeight: '700' },
    reviewFoot: { fontSize: 11, color: colors.textFaint, marginTop: 10, textAlign: 'center' },
  });
}
