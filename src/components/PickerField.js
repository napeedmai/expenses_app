// Generic "tap to open a bottom sheet, pick one" field. Used for both the
// Project dropdown and the Type dropdown, instead of writing the same
// Modal + FlatList code twice.
//
// options: array of objects
// valueKey / labelKey: which fields on each option object hold the value
//   you want back and the text to display
// value: the currently selected value (or '')
// onSelect(value): called when the user taps an option

import React, { useState } from 'react';
import { View, Text, TouchableOpacity, Modal, FlatList, StyleSheet } from 'react-native';

export default function PickerField({
  options,
  valueKey,
  labelKey,
  value,
  onSelect,
  disabled,
  placeholder,
  fieldStyle,
}) {
  const [visible, setVisible] = useState(false);
  const selected = options.find((o) => String(o[valueKey]) === String(value));

  return (
    <>
      <TouchableOpacity style={fieldStyle} disabled={disabled} onPress={() => setVisible(true)}>
        <Text style={{ fontSize: 15, color: selected ? '#000' : '#999' }}>
          {selected ? selected[labelKey] : placeholder || 'Select...'}
        </Text>
      </TouchableOpacity>

      <Modal visible={visible} animationType="slide" transparent onRequestClose={() => setVisible(false)}>
        <View style={styles.overlay}>
          <View style={styles.card}>
            <FlatList
              data={options}
              keyExtractor={(item) => String(item[valueKey])}
              renderItem={({ item }) => (
                <TouchableOpacity
                  style={styles.row}
                  onPress={() => {
                    onSelect(item[valueKey]);
                    setVisible(false);
                  }}
                >
                  <Text style={styles.rowText}>{item[labelKey]}</Text>
                </TouchableOpacity>
              )}
            />
            <TouchableOpacity style={styles.close} onPress={() => setVisible(false)}>
              <Text style={styles.closeText}>Cancel</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>
    </>
  );
}

const styles = StyleSheet.create({
  overlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.4)', justifyContent: 'flex-end' },
  card: {
    backgroundColor: '#fff',
    borderTopLeftRadius: 16,
    borderTopRightRadius: 16,
    maxHeight: '70%',
    padding: 16,
  },
  row: { paddingVertical: 14, borderBottomWidth: 1, borderBottomColor: '#eee' },
  rowText: { fontSize: 15 },
  close: { paddingVertical: 14, alignItems: 'center' },
  closeText: { color: '#c0392b', fontWeight: '600' },
});