// One bill, read-only, with its receipt shown in place.
//
//
// WHY THIS EXISTS
// ---------------
// Tapping a bill used to open the EDIT form. That is the wrong thing for the
// commonest reason anyone taps a bill: to look at it. It is especially wrong
// once a claim is submitted, when the form is locked anyway and every field is
// greyed out — a read-only form pretending to be editable.
//
// And the receipt was worse. The only way to see it was a button that handed
// the file to the operating system: a share sheet on a phone, a download in a
// browser. So checking your own receipt meant downloading it, opening it in
// another app, and coming back. The receipt is part of the bill. It belongs on
// the same screen as the amount it justifies.
//
//
// NOTHING LOADS UNTIL IT IS ASKED FOR
// -----------------------------------
// The receipt shows as a file row — badge, name, size cue — and only downloads
// when tapped. Rendering it automatically meant every bill anyone glanced at
// pulled a photo over the network, which on a phone is somebody's data for a
// picture they did not ask to see. Twenty bills, twenty downloads.
//
// Tapping opens it as a popup over this sheet:
//   image  full-screen, on a dark backdrop
//   PDF    on web, in an iframe — every browser has a PDF viewer
//          on native, no inline viewer without another dependency, so it hands
//          off to the OS. Honest about the limit rather than pretending
//   other  hands off to the OS. A .rar has nothing to preview
//
// The iframe is a real DOM element. react-native-web renders to the DOM, so
// React.createElement('iframe') works there and is never reached on native —
// which is why it is behind Platform.OS.

import React, { useState, useEffect, useMemo } from 'react';
import {
  ActivityIndicator,
  Image,
  Modal,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { Ionicons } from '@expo/vector-icons';
import { useTheme } from '../ThemeContext';
import { radius, fileBadgeForName } from '../theme';
import { getItemAttachmentUrl, getAttachmentDownloadHeaders } from '../api/client';
import { loadAttachment, openAttachment } from '../utils/openAttachment';

export default function BillDetailSheet({
  visible,
  empId,
  expenseId,
  bill,
  canEdit,
  onEdit,
  onClose,
}) {
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);

  const [receipt, setReceipt] = useState(null);   // { uri, mimeType, isImage, isPdf }
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [receiptOpen, setReceiptOpen] = useState(false);

  // Forget the loaded file when the sheet closes. Otherwise opening a second
  // bill would flash the previous bill's receipt before the new one arrives --
  // and on a claim being checked against its receipts, showing the wrong one
  // for even a moment is worse than showing none.
  useEffect(() => {
    if (!visible) {
      setReceipt(null);
      setReceiptOpen(false);
      setError(null);
    }
  }, [visible]);

  // On demand. Nothing is fetched until somebody taps the file.
  async function handleShowReceipt() {
    if (loading) return;
    setError(null);

    // Already downloaded once for this bill -- just show it again.
    if (receipt) {
      if (receipt.isImage || (receipt.isPdf && Platform.OS === 'web')) {
        setReceiptOpen(true);
      } else {
        await handleOpenExternally();
      }
      return;
    }

    setLoading(true);
    try {
      const headers = await getAttachmentDownloadHeaders(empId);
      const res = await loadAttachment({
        url: getItemAttachmentUrl(expenseId, bill.id),
        headers,
        filename: bill.attachment_filename,
      });
      setReceipt(res);
      if (res.isImage || (res.isPdf && Platform.OS === 'web')) {
        setReceiptOpen(true);
      } else {
        // Nothing we can render. Hand it straight to whatever can open it,
        // rather than opening an empty popup to then offer a second tap.
        await handleOpenExternally();
      }
    } catch (e) {
      setError(e.message || 'Could not load the receipt.');
    } finally {
      setLoading(false);
    }
  }

  async function handleOpenExternally() {
    try {
      const headers = await getAttachmentDownloadHeaders(empId);
      await openAttachment({
        url: getItemAttachmentUrl(expenseId, bill.id),
        headers,
        filename: bill.attachment_filename,
        onImage: () => setReceiptOpen(true),
      });
    } catch (e) {
      setError(e.message || 'Could not open that file.');
    }
  }

  if (!bill) return null;

  const badge = bill.attachment_filename ? fileBadgeForName(bill.attachment_filename) : null;

  return (
    <Modal visible={visible} animationType="slide" onRequestClose={onClose}>
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity onPress={onClose} style={styles.headerBtn}>
            <Text style={styles.close}>Close</Text>
          </TouchableOpacity>
          <Text style={styles.title}>Bill {bill.item_no}</Text>
          {canEdit ? (
            <TouchableOpacity onPress={onEdit} style={styles.headerBtn}>
              <Text style={styles.edit}>Edit</Text>
            </TouchableOpacity>
          ) : (
            <View style={styles.headerBtn} />
          )}
        </View>

        <ScrollView contentContainerStyle={{ padding: 16, paddingBottom: 48 }}>
          {error ? <Text style={styles.error}>{error}</Text> : null}

          {/* The amount first. It is what the bill is about and what anyone
              checking the receipt is checking it against. */}
          <View style={styles.amountCard}>
            <Text style={styles.amountBig}>
              {bill.amount} {bill.currency}
            </Text>
            <Text style={styles.amountUsd}>
              {bill.amount_usd != null ? `${bill.amount_usd} USD` : '—'}
              {bill.exchange_rate != null && bill.currency !== 'USD'
                ? `   ·   1 ${bill.currency} = ${bill.exchange_rate} USD`
                : ''}
            </Text>
          </View>

          <View style={styles.card}>
            <Field styles={styles} label="Type" value={bill.type} />
            <Field styles={styles} label="Description" value={bill.description} />
            <Field styles={styles} label="Bill No" value={bill.bill_no} />
            <Field styles={styles} label="Bill Date" value={bill.bill_date} />
            <Field styles={styles} label="From Date" value={bill.from_date} />
            <Field styles={styles} label="To Date" value={bill.to_date} last />
          </View>

          <Text style={styles.sectionLabel}>Receipt</Text>

          {bill.has_receipt !== 'Y' ? (
            <View style={styles.noReceipt}>
              <Ionicons name="alert-circle-outline" size={20} color={colors.amber} />
              <Text style={styles.noReceiptText}>
                No receipt attached. This claim cannot be submitted until every bill
                has one.
              </Text>
            </View>
          ) : (
            <>
              {/* A file row, not the file. Tapping it fetches and shows it. */}
              <TouchableOpacity
                style={styles.fileRow}
                onPress={handleShowReceipt}
                activeOpacity={0.7}
                disabled={loading}
              >
                <View style={[styles.tag, badge ? { backgroundColor: badge.bg } : null]}>
                  <Text style={[styles.tagText, badge ? { color: badge.text } : null]}>
                    {badge ? badge.label : 'FILE'}
                  </Text>
                </View>
                <Text style={styles.fileName} numberOfLines={1}>
                  {bill.attachment_filename || 'Receipt'}
                </Text>
                {loading ? (
                  <ActivityIndicator size="small" color={colors.primary} />
                ) : (
                  <Ionicons name="eye-outline" size={18} color={colors.primary} />
                )}
              </TouchableOpacity>
              <Text style={styles.hint}>Tap to view the receipt.</Text>
            </>
          )}

        </ScrollView>
      </View>

      {/* The popup. Full screen, because a receipt is only useful if the small
          print is readable -- a thumbnail in a card is decoration. */}
      <Modal visible={receiptOpen} transparent animationType="fade">
        <View style={styles.zoomOverlay}>
          <TouchableOpacity style={styles.zoomClose} onPress={() => setReceiptOpen(false)}>
            <Text style={styles.zoomCloseText}>Close</Text>
          </TouchableOpacity>

          {receipt && receipt.isImage ? (
            <Image source={{ uri: receipt.uri }} style={styles.zoomImage} resizeMode="contain" />
          ) : receipt && receipt.isPdf && Platform.OS === 'web' ? (
            React.createElement('iframe', {
              src: receipt.uri,
              title: bill.attachment_filename || 'Receipt',
              style: {
                width: '92%',
                height: '88%',
                border: 'none',
                borderRadius: 10,
                background: '#fff',
              },
            })
          ) : null}
        </View>
      </Modal>
    </Modal>
  );
}

// Module scope, not nested: a component defined inside another component's body
// is a new function identity on every render, so React remounts it instead of
// updating it. Same reasoning as Row in ReviewExpenseScreen.
function Field({ label, value, last, styles }) {
  return (
    <View style={[styles.row, last && styles.rowLast]}>
      <Text style={styles.rowLabel}>{label}</Text>
      <Text style={styles.rowValue}>{value || '—'}</Text>
    </View>
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
    headerBtn: { minWidth: 60, paddingVertical: 6 },
    title: { fontSize: 16, fontWeight: '800', color: colors.text },
    close: { color: colors.textMuted, fontSize: 15 },
    edit: { color: colors.primary, fontSize: 15, fontWeight: '700', textAlign: 'right' },

    amountCard: {
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      borderWidth: 1,
      borderColor: colors.border,
      padding: 16,
      alignItems: 'center',
    },
    amountBig: { fontSize: 26, fontWeight: '800', color: colors.text },
    amountUsd: { fontSize: 12.5, color: colors.textMuted, marginTop: 4, textAlign: 'center' },

    card: {
      backgroundColor: colors.surface,
      borderRadius: radius.md,
      borderWidth: 1,
      borderColor: colors.border,
      paddingHorizontal: 14,
      marginTop: 14,
    },
    row: {
      flexDirection: 'row',
      justifyContent: 'space-between',
      alignItems: 'flex-start',
      gap: 16,
      paddingVertical: 11,
      borderBottomWidth: 1,
      borderBottomColor: colors.border,
    },
    rowLast: { borderBottomWidth: 0 },
    rowLabel: { fontSize: 12.5, color: colors.textMuted, fontWeight: '600' },
    rowValue: { fontSize: 14, color: colors.text, flexShrink: 1, textAlign: 'right' },

    sectionLabel: {
      fontSize: 12,
      fontWeight: '800',
      color: colors.textMuted,
      marginTop: 22,
      marginBottom: 8,
      letterSpacing: 0.4,
    },
    fileRow: {
      flexDirection: 'row',
      alignItems: 'center',
      gap: 12,
      backgroundColor: colors.surface,
      borderWidth: 1,
      borderColor: colors.border,
      borderRadius: radius.sm,
      paddingVertical: 14,
      paddingHorizontal: 14,
    },
    fileName: { flex: 1, fontSize: 13.5, color: colors.text },
    tag: { paddingHorizontal: 8, paddingVertical: 3, borderRadius: radius.sm,
           backgroundColor: colors.border },
    tagText: { fontSize: 10.5, fontWeight: '800', color: colors.textMuted },
    hint: { fontSize: 11.5, color: colors.textFaint, marginTop: 8, textAlign: 'center' },

    noReceipt: {
      flexDirection: 'row',
      alignItems: 'flex-start',
      gap: 10,
      backgroundColor: colors.amberTint,
      borderRadius: radius.sm,
      padding: 12,
    },
    noReceiptText: { flex: 1, fontSize: 12.5, lineHeight: 18, color: colors.amber },

    error: {
      color: colors.red,
      backgroundColor: colors.redTint,
      borderRadius: radius.sm,
      padding: 10,
      fontSize: 13,
      marginBottom: 12,
    },

    zoomOverlay: {
      flex: 1,
      backgroundColor: 'rgba(15,23,42,0.94)',
      justifyContent: 'center',
      alignItems: 'center',
    },
    zoomImage: { width: '100%', height: '85%' },
    zoomClose: {
      position: 'absolute',
      top: 48,
      right: 20,
      paddingVertical: 8,
      paddingHorizontal: 16,
      borderRadius: radius.pill,
      backgroundColor: 'rgba(255,255,255,0.18)',
      zIndex: 2,
    },
    zoomCloseText: { color: '#fff', fontWeight: '600' },
  });
}
