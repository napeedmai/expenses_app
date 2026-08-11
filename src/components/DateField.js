// Real date picker field. Both displays AND stores/sends MM/DD/YYYY —
// matching the backend now (see 23_date_format_mmddyyyy.sql), so there's no
// format conversion happening in this component anymore; the value prop IS
// the MM/DD/YYYY string, straight from/to the API.
//
// Android shows the system date dialog automatically and closes itself.
// iOS's inline/spinner picker doesn't close itself, so we wrap it in a
// small sheet with Cancel/Done for iOS only.
//
// WEB: @react-native-community/datetimepicker has no web implementation, and
// the branches below only cover 'android' and 'ios' — so on web the field
// rendered as tappable text that opened nothing at all. Web uses a native
// <input type="date"> instead (react-native-web renders real DOM, so this is
// fine), which brings the browser's own date picker with it.

import React, { useState } from 'react';
import { View, Text, TouchableOpacity, Modal, StyleSheet, Platform } from 'react-native';
import DateTimePicker from '@react-native-community/datetimepicker';

function toMDY(d) {
  const mm = String(d.getMonth() + 1).padStart(2, '0');
  const dd = String(d.getDate()).padStart(2, '0');
  const yyyy = d.getFullYear();
  return `${mm}/${dd}/${yyyy}`;
}

function parseMDY(str) {
  if (!str) return new Date();
  const [mm, dd, yyyy] = str.split('/').map(Number);
  if (!mm || !dd || !yyyy) return new Date();
  return new Date(yyyy, mm - 1, dd);
}

// <input type="date"> speaks YYYY-MM-DD only; the rest of the app and the
// backend use MM/DD/YYYY (see 23_date_format_mmddyyyy.sql).
function mdyToISO(str) {
  if (!str) return '';
  const [mm, dd, yyyy] = str.split('/');
  if (!mm || !dd || !yyyy) return '';
  return `${yyyy}-${mm.padStart(2, '0')}-${dd.padStart(2, '0')}`;
}

function isoToMDY(str) {
  if (!str) return '';
  const [yyyy, mm, dd] = str.split('-');
  if (!yyyy || !mm || !dd) return '';
  return `${mm}/${dd}/${yyyy}`;
}

export default function DateField({ value, onChange, disabled, placeholder, fieldStyle }) {
  const [show, setShow] = useState(false);
  const [tempDate, setTempDate] = useState(parseMDY(value));

  if (Platform.OS === 'web') {
    return (
      <View style={fieldStyle}>
        <input
          type="date"
          value={mdyToISO(value)}
          disabled={disabled}
          onChange={(e) => onChange(isoToMDY(e.target.value))}
          style={{
            border: 'none',
            outline: 'none',
            background: 'transparent',
            font: 'inherit',
            fontSize: 15,
            color: value ? '#000' : '#999',
            width: '100%',
            padding: 0,
          }}
        />
      </View>
    );
  }

  function open() {
    setTempDate(parseMDY(value));
    setShow(true);
  }

  function handleChange(event, selectedDate) {
    if (Platform.OS === 'android') {
      setShow(false);
      if (event.type === 'set' && selectedDate) {
        onChange(toMDY(selectedDate));
      }
      return;
    }
    // iOS: keep the sheet open, just track the value until "Done" is tapped
    if (selectedDate) setTempDate(selectedDate);
  }

  function confirmIos() {
    onChange(toMDY(tempDate));
    setShow(false);
  }

  return (
    <>
      <TouchableOpacity style={fieldStyle} disabled={disabled} onPress={open}>
        <Text style={{ fontSize: 15, color: value ? '#000' : '#999' }}>
          {value || placeholder || 'MM/DD/YYYY'}
        </Text>
      </TouchableOpacity>

      {show && Platform.OS === 'android' && (
        <DateTimePicker value={tempDate} mode="date" display="default" onChange={handleChange} />
      )}

      {show && Platform.OS === 'ios' && (
        <Modal visible={show} transparent animationType="slide" onRequestClose={() => setShow(false)}>
          <View style={styles.overlay}>
            <View style={styles.card}>
              <DateTimePicker value={tempDate} mode="date" display="spinner" onChange={handleChange} />
              <View style={styles.buttonRow}>
                <TouchableOpacity onPress={() => setShow(false)}>
                  <Text style={styles.cancelText}>Cancel</Text>
                </TouchableOpacity>
                <TouchableOpacity onPress={confirmIos}>
                  <Text style={styles.doneText}>Done</Text>
                </TouchableOpacity>
              </View>
            </View>
          </View>
        </Modal>
      )}
    </>
  );
}

const styles = StyleSheet.create({
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.4)', justifyContent: 'flex-end' },
  card: { backgroundColor: '#fff', borderTopLeftRadius: 16, borderTopRightRadius: 16, padding: 16 },
  buttonRow: { flexDirection: 'row', justifyContent: 'space-between', paddingTop: 8 },
  cancelText: { color: '#888', fontSize: 16, padding: 8 },
  doneText: { color: '#2d6cdf', fontWeight: '700', fontSize: 16, padding: 8 },
});