// Cross-platform alert.
//
// WHY THIS EXISTS
// ---------------
// react-native-web does NOT implement Alert.alert — calling it on web is a
// silent no-op. Every confirmation and error dialog in this app simply did
// nothing when running in a browser: logging out appeared broken, failed
// uploads gave no feedback, and validation errors vanished. Nothing threw,
// so there was no clue in the console either.
//
// showAlert() keeps the exact React Native Alert.alert signature, so call
// sites need no restructuring, and maps it onto window.alert/window.confirm
// on web.
//
// MAPPING RULES
//   0 or 1 button  -> window.alert, then run that button's onPress
//   2+ buttons     -> window.confirm; OK runs the first non-cancel button,
//                     Cancel runs the button with style 'cancel' if present
//
// window.confirm only offers two choices, so a three-button Alert loses its
// middle option. Nothing in this app uses three buttons today; if that
// changes, build a real modal instead of extending this.

import { Alert, Platform } from 'react-native';

export function showAlert(title, message, buttons) {
  if (Platform.OS !== 'web') {
    Alert.alert(title, message, buttons);
    return;
  }

  const text = [title, message].filter(Boolean).join('\n\n');

  if (!buttons || buttons.length === 0) {
    window.alert(text);
    return;
  }

  if (buttons.length === 1) {
    window.alert(text);
    if (typeof buttons[0].onPress === 'function') buttons[0].onPress();
    return;
  }

  const cancelButton  = buttons.find((b) => b.style === 'cancel');
  const confirmButton = buttons.find((b) => b.style !== 'cancel') || buttons[0];

  if (window.confirm(text)) {
    if (typeof confirmButton.onPress === 'function') confirmButton.onPress();
  } else if (cancelButton && typeof cancelButton.onPress === 'function') {
    cancelButton.onPress();
  }
}

export default showAlert;
