// Add/Edit Expense screen.
//
// Project field: picker of active projects this employee is allocated to
// (PROJECT_ALLOCATION_WB joined to PROJECTMASTER server-side), falling back
// to a plain numeric box if there are no matching allocations.
// Type field: picker from the fixed EXPENSE_TYPES list.
// Date fields: real date pickers, shown as MM/DD/YYYY, stored as
// YYYY-MM-DD (see src/components/DateField.js for why).
//
// empId now comes from the session context, not route.params — see
// src/SessionContext.js.

import React, { useState, useEffect, useCallback, useMemo } from 'react';
import {
  ActivityIndicator,
  Alert,
  Image,
  Modal,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import * as DocumentPicker from 'expo-document-picker';
// Using the /legacy import on purpose — SDK 54 replaced downloadAsync with
// a new File/Directory-class API, but the legacy path keeps the same
// downloadAsync()/cacheDirectory calls working without a rewrite.
import * as FileSystem from 'expo-file-system/legacy';
import * as Sharing from 'expo-sharing';
import { useSession } from '../SessionContext';
import { useTheme } from '../ThemeContext';
import PickerField from '../components/PickerField';
import DateField from '../components/DateField';
import { EXPENSE_TYPES } from '../constants/expenseTypes';
import { radius, shadow, fileBadgeForName, stageLabel } from '../theme';
import { Ionicons } from '@expo/vector-icons';
import { showAlert } from '../utils/alert';
import {
  getExpense,
  createDraft,
  updateExpense,
  deleteExpense,
  submitExpense,
  uploadAttachment,
  listMyProjects,
  getAttachmentUrl,
  getAttachmentDownloadHeaders,
} from '../api/client';

const EDITABLE_STATUSES = ['DRAFT', 'REVISION_REQUESTED'];

// Everything except Bill Date is required before an expense can be
// submitted (Bill No./Project/Type/Description used to be optional). Draft
// saves still only require From Date/To Date/Amount — that's a hard
// backend requirement (the draft-creation endpoint rejects a request
// without those three), not a UX choice, so it stays as-is.
const ALLOWED_ATTACHMENT_EXTENSIONS = ['pdf', 'jpg', 'jpeg', 'png', 'xlsx', 'xls', 'csv', 'rar'];
const MAX_ATTACHMENT_BYTES = 1 * 1024 * 1024; // 1 MB

// A random id generated once per "new expense" attempt (see the
// clientRequestId state below) and sent with every draft-creation request
// for that attempt, even across retries. This lets the backend recognize
// "this is the same save attempt as before" and return the existing draft
// instead of inserting a duplicate — see 37_idempotent_draft_creation.sql.
// Without this, a lost/timed-out response (the intermittent 555 errors)
// looked like a failure on the phone even when the draft had actually been
// created, so tapping Save/Submit again created a second, identical draft.
function generateClientRequestId() {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

export default function AddEditExpenseScreen({ route, navigation }) {
  const { session } = useSession();
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);
  const empId = session.empId;
  const { expenseId: initialExpenseId } = route.params;

  // Only needed while creating a brand-new expense — once expenseId is set
  // (either because we opened an existing one, or because a draft was just
  // created), further saves go through updateExpense, which doesn't need
  // it. useState's initializer runs exactly once per screen instance, so
  // this stays the same value across every retry on this screen.
  const [clientRequestId] = useState(() => (initialExpenseId ? null : generateClientRequestId()));

  const [expenseId, setExpenseId] = useState(initialExpenseId);
  const [status, setStatus] = useState('DRAFT');
  const [currentStage, setCurrentStage] = useState(null);
  const [projectName, setProjectName] = useState(null);
  const [managerName, setManagerName] = useState(null);
  const [financeManagerName, setFinanceManagerName] = useState(null);
  const [loading, setLoading] = useState(!!initialExpenseId);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState(null);
  const [attachmentInfo, setAttachmentInfo] = useState(null);
  const [previewing, setPreviewing] = useState(false);
  const [previewImageUri, setPreviewImageUri] = useState(null);

  const [billNo, setBillNo] = useState('');
  const [billDate, setBillDate] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [projectId, setProjectId] = useState('');
  const [type, setType] = useState('');
  const [amount, setAmount] = useState('');
  const [description, setDescription] = useState('');

  const [myProjects, setMyProjects] = useState(null); // null = still loading, [] = loaded but empty
  const [projectsError, setProjectsError] = useState(false);

  const isLocked = !!expenseId && !EDITABLE_STATUSES.includes(status);

  useEffect(() => {
    listMyProjects(empId)
      .then((data) => setMyProjects(Array.isArray(data.items) ? data.items : []))
      .catch(() => {
        // Fall back to a plain numeric box rather than blocking the user
        // if this lookup isn't working yet.
        setProjectsError(true);
        setMyProjects([]);
      });
  }, [empId]);

  const loadExisting = useCallback(async () => {
    if (!initialExpenseId) return;
    try {
      const data = await getExpense(empId, initialExpenseId);
      setStatus(data.status);
      setCurrentStage(data.current_stage || null);
      setProjectName(data.project_name || null);
      setManagerName(data.manager_name || null);
      setFinanceManagerName(data.finance_manager_name || null);
      setBillNo(data.bill_no || '');
      setBillDate(data.bill_date || '');
      setFromDate(data.from_date || '');
      setToDate(data.to_date || '');
      setProjectId(data.project_id != null ? String(data.project_id) : '');
      setType(data.type || '');
      setAmount(data.amount != null ? String(data.amount) : '');
      setDescription(data.description || '');
      setAttachmentInfo(
        data.attachment_filename ? { name: data.attachment_filename, alreadyUploaded: true } : null
      );
    } catch (e) {
      setError(e.message || 'Failed to load this expense.');
    } finally {
      setLoading(false);
    }
  }, [empId, initialExpenseId]);

  useEffect(() => {
    loadExisting();
  }, [loadExisting]);

  function buildPayload() {
    return {
      bill_no: billNo || null,
      bill_date: billDate || null,
      from_date: fromDate,
      to_date: toDate,
      project_id: projectId ? Number(projectId) : null,
      type: type || null,
      amount: amount ? Number(amount) : null,
      description: description || null,
      // Only relevant to createDraft (expenseId is still null at that
      // point) — updateExpense doesn't need it, and the backend ignores it
      // harmlessly either way since PUT doesn't read this field.
      client_request_id: expenseId ? undefined : clientRequestId,
    };
  }

  // Everything except Bill Date — used to gate Submit (not Save Draft).
  function findMissingRequiredField() {
    if (!billNo.trim()) return 'Bill No.';
    if (!fromDate) return 'From Date';
    if (!toDate) return 'To Date';
    if (!projectId) return 'Project';
    if (!type) return 'Type';
    if (!amount) return 'Amount';
    if (!description.trim()) return 'Description';
    if (!attachmentInfo) return 'Receipt Attachment';
    return null;
  }

  // Shared by Save Draft, Submit, and (now) attaching a file on a brand-new
  // expense: creates the draft if it doesn't exist yet, or updates it if it
  // does. Always safe to call repeatedly — retries reuse the same
  // clientRequestId, so a retry after a lost/timed-out response updates the
  // same draft instead of creating a duplicate (see
  // 37_idempotent_draft_creation.sql).
  async function ensureDraftSaved() {
    if (expenseId) {
      await updateExpense(empId, expenseId, buildPayload());
      return expenseId;
    }
    if (!fromDate || !toDate || !amount) {
      throw new Error('From Date, To Date, and Amount are required.');
    }
    const result = await createDraft(empId, buildPayload());
    // Guard against a malformed/empty response silently producing a bad id
    // (e.g. JS `undefined` getting interpolated into a later request URL as
    // the literal text "undefined", which is exactly what caused a
    // confusing ORA-01722 further down the line instead of a clear error
    // here, where the actual problem is).
    const newId = result && result.id;
    if (newId === undefined || newId === null || Number.isNaN(Number(newId))) {
      throw new Error(
        "The server didn't return a valid expense id after saving. Check My Expenses — a draft may have already been created — before trying again."
      );
    }
    setExpenseId(newId);
    setStatus('DRAFT');
    return newId;
  }

  async function handleSaveDraft() {
    if (!fromDate || !toDate || !amount) {
      showAlert('Missing fields', 'From Date, To Date, and Amount are required.');
      return;
    }
    setSaving(true);
    setError(null);
    try {
      await ensureDraftSaved();
      showAlert('Saved', 'Draft saved successfully.');
    } catch (e) {
      const message = e.message || 'Failed to save.';
      setError(message);
      showAlert('Save failed', message);
    } finally {
      setSaving(false);
    }
  }

  async function handlePickAndUploadAttachment() {
    // Back to requiring the expense to already be saved as a draft before
    // attaching a file — simpler and more predictable than auto-saving
    // behind the scenes.
    if (!expenseId) {
      showAlert('Save first', 'Save this as a draft before attaching a file.');
      return;
    }

    // Wrapped in try/catch — getDocumentAsync() failing for any reason (a
    // missing native module, a denied permission, etc.) used to fail
    // silently with no error shown at all, so tapping "attach" would just
    // appear to do nothing.
    let result;
    try {
      result = await DocumentPicker.getDocumentAsync({ type: '*/*', copyToCacheDirectory: true });
    } catch (e) {
      const message = e.message || 'Failed to open the file/photo picker.';
      setError(message);
      showAlert('Could not open picker', message);
      return;
    }
    if (result.canceled) return;

    const file = result.assets[0];

    const ext = (file.name || '').split('.').pop().toLowerCase();
    if (!ALLOWED_ATTACHMENT_EXTENSIONS.includes(ext)) {
      showAlert(
        'File type not allowed',
        `Allowed file types: ${ALLOWED_ATTACHMENT_EXTENSIONS.join(', ').toUpperCase()}.`
      );
      return;
    }
    if (typeof file.size === 'number' && file.size > MAX_ATTACHMENT_BYTES) {
      showAlert(
        'File too large',
        `Maximum file size is 1 MB. This file is ${(file.size / (1024 * 1024)).toFixed(2)} MB — please choose a smaller file.`
      );
      return;
    }

    setSaving(true);
    setError(null);
    try {
      await uploadAttachment(empId, expenseId, file);
      setAttachmentInfo({ name: file.name, alreadyUploaded: true });
      showAlert('Uploaded', 'Attachment uploaded successfully.');
    } catch (e) {
      // The backend returns a clear message for disallowed file types too
      // (pdf, jpg, jpeg, png, xlsx, xls, csv, rar only).
      const message = e.message || 'Failed to upload attachment.';
      setError(message);
      showAlert('Upload failed', message);
    } finally {
      setSaving(false);
    }
  }

  function handleDelete() {
    showAlert(
      'Delete expense',
      'Are you sure you want to delete this draft? This cannot be undone.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: async () => {
            setSaving(true);
            setError(null);
            try {
              await deleteExpense(empId, expenseId);
              navigation.goBack();
            } catch (e) {
              const message = e.message || 'Failed to delete.';
              setError(message);
              showAlert('Delete failed', message);
              setSaving(false);
            }
          },
        },
      ]
    );
  }

  // Downloads the attachment to a local temp file (with the same auth
  // headers every other request uses) and either shows it in-app (images)
  // or hands it to the OS's own viewer/share sheet (everything else — PDF,
  // Excel, etc.), since RN has no built-in universal file viewer.
  async function handlePreviewAttachment() {
    setPreviewing(true);
    setError(null);
    try {
      const headers = await getAttachmentDownloadHeaders(empId);

      // Web has no filesystem to download into (FileSystem.cacheDirectory is
      // null and downloadAsync is unimplemented), and no OS share sheet.
      // Fetch the bytes, wrap them in an object URL, and either show the
      // image inline or hand the file to the browser in a new tab.
      if (Platform.OS === 'web') {
        const res = await fetch(getAttachmentUrl(expenseId), { headers });
        if (!res.ok) throw new Error('Failed to download attachment.');
        const blob = await res.blob();
        const objectUrl = URL.createObjectURL(blob);
        if ((blob.type || '').startsWith('image/')) {
          setPreviewImageUri(objectUrl);
        } else {
          window.open(objectUrl, '_blank');
        }
        return;
      }

      const safeName = (attachmentInfo && attachmentInfo.name) || `attachment-${expenseId}`;
      const localUri = FileSystem.cacheDirectory + safeName;

      const result = await FileSystem.downloadAsync(getAttachmentUrl(expenseId), localUri, { headers });
      if (result.status !== 200) {
        throw new Error('Failed to download attachment.');
      }

      const contentType = (result.headers['Content-Type'] || result.headers['content-type'] || '').toLowerCase();

      if (contentType.startsWith('image/')) {
        setPreviewImageUri(result.uri);
        return;
      }

      const canShare = await Sharing.isAvailableAsync();
      if (canShare) {
        await Sharing.shareAsync(result.uri, { mimeType: contentType || undefined });
      } else {
        showAlert('Preview not available', 'This device has no way to open this file type.');
      }
    } catch (e) {
      const message = e.message || 'Failed to preview attachment.';
      setError(message);
      showAlert('Preview failed', message);
    } finally {
      setPreviewing(false);
    }
  }

  async function handleSubmit() {
    const missingField = findMissingRequiredField();
    if (missingField) {
      showAlert('Missing fields', `${missingField} is required. Every field except Bill Date must be filled in before you can submit.`);
      return;
    }
    setSaving(true);
    setError(null);
    let idToSubmit;
    try {
      idToSubmit = await ensureDraftSaved();
    } catch (e) {
      // Failed before we even got to the submit step — nothing saved as
      // SUBMITTED, but a draft may now exist (if createDraft succeeded and
      // it was the following updateExpense-on-retry that failed instead).
      const message = e.message || 'Failed to save this expense.';
      setError(message);
      showAlert('Save failed', message);
      setSaving(false);
      return;
    }

    try {
      await submitExpense(empId, idToSubmit);
      showAlert('Submitted', 'Expense submitted for approval.', [
        { text: 'OK', onPress: () => navigation.goBack() },
      ]);
    } catch (e) {
      // The draft itself DID save successfully above — only the actual
      // submit step failed. Say so explicitly, otherwise it looks like
      // nothing happened and the same details get submitted again as a
      // second, duplicate draft.
      const message = e.message || 'Failed to submit.';
      setError(message);
      showAlert(
        'Saved as draft, but not submitted',
        `Your details were saved, but submitting for approval failed: ${message}\n\nTap Submit Claim again to retry — you won't create a duplicate.`
      );
    } finally {
      setSaving(false);
    }
  }

  function fieldStyle(locked) {
    return [styles.input, locked ? styles.inputLocked : null];
  }

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color={colors.primary} />
      </View>
    );
  }

  return (
    <ScrollView style={styles.container} contentContainerStyle={{ padding: 16 }}>
      {expenseId && status !== 'DRAFT' ? (
        <View style={styles.progressCard}>
          <Text style={styles.progressTitle}>{stageLabel(status, currentStage)}</Text>
          {projectName ? <Text style={styles.progressLine}>Project: {projectName}</Text> : null}
          {managerName ? <Text style={styles.progressLine}>Project Manager: {managerName}</Text> : null}
          {financeManagerName ? (
            <Text style={styles.progressLine}>Finance Manager: {financeManagerName}</Text>
          ) : null}
        </View>
      ) : null}

      {isLocked ? (
        <View style={styles.lockedBanner}>
          <Text style={styles.lockedText}>
            This expense is {stageLabel(status, currentStage)} and can no longer be edited or deleted.
          </Text>
        </View>
      ) : null}

      {error ? <Text style={styles.error}>{error}</Text> : null}

      <View style={styles.row2}>
        <View style={styles.halfField}>
          <Field label="Bill No. *" styles={styles}>
            <TextInput style={fieldStyle(isLocked)} value={billNo} onChangeText={setBillNo} editable={!isLocked} />
          </Field>
        </View>
        <View style={styles.halfField}>
          <Field label="Bill Date" styles={styles}>
            <DateField
              value={billDate}
              onChange={setBillDate}
              disabled={isLocked}
              fieldStyle={fieldStyle(isLocked)}
            />
          </Field>
        </View>
      </View>

      <View style={styles.row2}>
        <View style={styles.halfField}>
          <Field label="From Date *" styles={styles}>
            <DateField
              value={fromDate}
              onChange={setFromDate}
              disabled={isLocked}
              fieldStyle={fieldStyle(isLocked)}
            />
          </Field>
        </View>
        <View style={styles.halfField}>
          <Field label="To Date *" styles={styles}>
            <DateField
              value={toDate}
              onChange={setToDate}
              disabled={isLocked}
              fieldStyle={fieldStyle(isLocked)}
            />
          </Field>
        </View>
      </View>

      <Field label="Project *" styles={styles}>
        {myProjects && myProjects.length > 0 && !projectsError ? (
          <PickerField
            options={myProjects}
            valueKey="project_id"
            labelKey="project_name"
            value={projectId}
            onSelect={(v) => setProjectId(String(v))}
            disabled={isLocked}
            placeholder="Select a project..."
            fieldStyle={fieldStyle(isLocked)}
          />
        ) : myProjects === null ? (
          <ActivityIndicator />
        ) : (
          // No allocations found (or the lookup failed) — fall back to a
          // plain numeric box so the employee isn't blocked from submitting.
          <>
            <Text style={styles.helperText}>
              {projectsError
                ? "Couldn't load your assigned projects — enter the Project ID manually."
                : 'No assigned projects found — enter the Project ID manually.'}
            </Text>
            <TextInput
              style={fieldStyle(isLocked)}
              value={projectId}
              onChangeText={setProjectId}
              editable={!isLocked}
              keyboardType="number-pad"
            />
          </>
        )}
      </Field>

      <Field label="Type *" styles={styles}>
        <PickerField
          options={EXPENSE_TYPES}
          valueKey="id"
          labelKey="label"
          value={type}
          onSelect={setType}
          disabled={isLocked}
          placeholder="Select a type..."
          fieldStyle={fieldStyle(isLocked)}
        />
      </Field>

      <Field label="Amount *" styles={styles}>
        <TextInput
          style={fieldStyle(isLocked)}
          value={amount}
          onChangeText={setAmount}
          editable={!isLocked}
          keyboardType="decimal-pad"
        />
      </Field>

      <Field label="Description *" styles={styles}>
        <TextInput
          style={[fieldStyle(isLocked), { height: 80 }]}
          value={description}
          onChangeText={setDescription}
          editable={!isLocked}
          multiline
        />
      </Field>

      <Field label="Receipt Attachment *" styles={styles}>
        {attachmentInfo ? (
          <View style={styles.attachedRow}>
            <View style={[styles.fileBadge, { backgroundColor: fileBadgeForName(attachmentInfo.name).bg }]}>
              <Text style={[styles.fileBadgeText, { color: fileBadgeForName(attachmentInfo.name).text }]}>
                {fileBadgeForName(attachmentInfo.name).label}
              </Text>
            </View>
            <View style={{ flex: 1 }}>
              <Text style={styles.attachmentName} numberOfLines={1}>{attachmentInfo.name}</Text>
              <Text style={styles.attachmentSub}>Attached</Text>
            </View>
            {attachmentInfo.alreadyUploaded && (
              <TouchableOpacity onPress={handlePreviewAttachment} disabled={previewing} style={{ padding: 4 }}>
                {previewing ? (
                  <ActivityIndicator color={colors.primary} />
                ) : (
                  <Text style={styles.viewLink}>View</Text>
                )}
              </TouchableOpacity>
            )}
          </View>
        ) : (
          !isLocked && (
            <TouchableOpacity
              style={styles.dropzone}
              onPress={handlePickAndUploadAttachment}
              disabled={saving}
            >
              <Ionicons name="attach-outline" size={22} color={colors.textFaint} />
              <Text style={styles.dropzoneText}>
                {expenseId ? 'Tap to attach photo or file' : 'Save draft first to attach a file'}
              </Text>
              <Text style={styles.dropzoneHint}>PDF, JPG, JPEG, PNG, XLSX, XLS, CSV, RAR up to 1MB</Text>
            </TouchableOpacity>
          )
        )}

        {attachmentInfo && !isLocked && (
          <TouchableOpacity
            style={[styles.secondaryButton, { marginTop: 8 }]}
            onPress={handlePickAndUploadAttachment}
          >
            <Text style={styles.secondaryButtonText}>Replace File</Text>
          </TouchableOpacity>
        )}
      </Field>

      {!isLocked && (
        <View style={{ marginTop: 20 }}>
          <View style={styles.footerRow}>
            <TouchableOpacity style={[styles.saveButton, styles.footerButton]} onPress={handleSaveDraft} disabled={saving}>
              {saving ? <ActivityIndicator color={colors.text} /> : <Text style={styles.buttonText}>Save Draft</Text>}
            </TouchableOpacity>
            <TouchableOpacity style={[styles.submitButton, styles.footerButton]} onPress={handleSubmit} disabled={saving}>
              {saving ? <ActivityIndicator color="#fff" /> : <Text style={styles.submitButtonText}>Submit Claim</Text>}
            </TouchableOpacity>
          </View>
          {expenseId && (
            <TouchableOpacity style={styles.deleteButton} onPress={handleDelete} disabled={saving}>
              <Text style={styles.deleteButtonText}>Delete Expense</Text>
            </TouchableOpacity>
          )}
        </View>
      )}

      <Modal visible={!!previewImageUri} transparent animationType="fade">
        <View style={styles.previewOverlay}>
          <TouchableOpacity
            style={styles.previewCloseButton}
            onPress={() => setPreviewImageUri(null)}
          >
            <Text style={styles.previewCloseText}>Close</Text>
          </TouchableOpacity>
          {previewImageUri && (
            <Image source={{ uri: previewImageUri }} style={styles.previewImage} resizeMode="contain" />
          )}
        </View>
      </Modal>
    </ScrollView>
  );
}

// Defined at module scope (not inside AddEditExpenseScreen) and taking
// `styles` as an explicit prop — a component defined INSIDE another
// component's function body gets recreated as a brand-new function on
// every render, which makes React treat it as a different component type
// and remount its children every time. Since Field wraps the TextInputs,
// that remount was dropping keyboard focus after every single keystroke —
// exactly the "keyboard disappears after typing one character" bug.
function Field({ label, children, styles }) {
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      {children}
    </View>
  );
}

function createStyles(colors) {
  return StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.bg },
  center: { flex: 1, justifyContent: 'center', alignItems: 'center', backgroundColor: colors.bg },
  error: { color: colors.red, marginBottom: 12, fontWeight: '600' },
  row2: { flexDirection: 'row', gap: 12 },
  halfField: { flex: 1 },
  field: { marginBottom: 14 },
  label: { fontSize: 11, color: colors.textMuted, marginBottom: 6, fontWeight: '800', textTransform: 'uppercase', letterSpacing: 0.3 },
  input: {
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    padding: 12,
    fontSize: 15,
    fontWeight: '600',
    color: colors.text,
    backgroundColor: colors.surface,
  },
  inputLocked: { backgroundColor: colors.bg, color: colors.textMuted },
  helperText: { fontSize: 12, color: colors.textMuted, marginBottom: 6 },
  progressCard: {
    backgroundColor: colors.primaryTint,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    padding: 12,
    marginBottom: 14,
  },
  progressTitle: { color: colors.primary, fontWeight: '800', fontSize: 13.5, marginBottom: 4 },
  progressLine: { color: colors.text, fontSize: 12.5, marginTop: 2 },
  lockedBanner: {
    backgroundColor: colors.amberTint,
    borderWidth: 1,
    borderColor: '#fde68a',
    borderRadius: radius.sm,
    padding: 12,
    marginBottom: 16,
  },
  lockedText: { color: '#92400e', fontWeight: '600', fontSize: 12.5 },
  dropzone: {
    borderWidth: 1.5,
    borderStyle: 'dashed',
    borderColor: colors.borderStrong,
    borderRadius: radius.md,
    paddingVertical: 20,
    alignItems: 'center',
    backgroundColor: colors.surface,
    marginBottom: 8,
  },
  dropzoneText: { fontSize: 12.5, fontWeight: '700', color: colors.text, marginTop: 6 },
  dropzoneHint: { fontSize: 10.5, color: colors.textFaint, marginTop: 2 },
  attachedRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    backgroundColor: colors.surface,
    borderWidth: 1,
    borderColor: colors.border,
    borderRadius: radius.sm,
    padding: 12,
    marginBottom: 8,
  },
  fileBadge: {
    width: 38,
    height: 38,
    borderRadius: 10,
    alignItems: 'center',
    justifyContent: 'center',
  },
  fileBadgeText: { fontSize: 9.5, fontWeight: '800' },
  attachmentName: { fontSize: 13.5, color: colors.text, fontWeight: '700' },
  attachmentSub: { fontSize: 11, color: colors.textFaint, marginTop: 1 },
  viewLink: { color: colors.primary, fontWeight: '700', fontSize: 13 },
  secondaryButton: {
    borderWidth: 1,
    borderColor: colors.primary,
    borderRadius: radius.sm,
    padding: 11,
    alignItems: 'center',
    backgroundColor: colors.primaryTint,
  },
  secondaryButtonText: { color: colors.primary, fontWeight: '700', fontSize: 13 },
  footerRow: { flexDirection: 'row', gap: 12, marginBottom: 10 },
  footerButton: { flex: 1, marginBottom: 0 },
  saveButton: {
    backgroundColor: colors.surface,
    borderWidth: 1.5,
    borderColor: colors.border,
    borderRadius: radius.sm,
    padding: 14,
    alignItems: 'center',
  },
  submitButton: {
    backgroundColor: colors.primary,
    borderRadius: radius.sm,
    padding: 14,
    alignItems: 'center',
    ...shadow.card,
  },
  buttonText: { color: colors.text, fontSize: 15, fontWeight: '700' },
  submitButtonText: { color: '#fff', fontSize: 15, fontWeight: '700' },
  deleteButton: {
    marginTop: 10,
    backgroundColor: colors.redTint,
    borderRadius: radius.sm,
    padding: 14,
    alignItems: 'center',
  },
  deleteButtonText: { color: colors.red, fontSize: 15, fontWeight: '700' },
  previewOverlay: {
    flex: 1,
    backgroundColor: 'rgba(15,23,42,0.94)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  previewImage: { width: '100%', height: '80%' },
  previewCloseButton: {
    position: 'absolute',
    top: 50,
    right: 20,
    backgroundColor: 'rgba(255,255,255,0.15)',
    paddingHorizontal: 16,
    paddingVertical: 8,
    borderRadius: 20,
    zIndex: 1,
  },
  previewCloseText: { color: '#fff', fontWeight: '600' },
  });
}