// App-wide light/dark theme switch, persisted via AsyncStorage so it
// sticks across app restarts. Wraps the whole app in App.js.
//
// Usage in any screen:
//   const { colors, scheme, toggleTheme } = useTheme();
// then use `colors.xxx` exactly as before — `colors` is just dynamic now
// instead of a static import from src/theme.js, so the whole screen
// re-renders with the right palette when the user flips the Settings
// switch. `colors.statusLabel` is still available on this object too (see
// below), so existing `colors.statusLabel[...]` call sites don't need to
// change.

import React, { createContext, useContext, useEffect, useState, useCallback, useMemo } from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { getColors, statusLabel } from './theme';

const ThemeContext = createContext(null);

export function ThemeProvider({ children }) {
  const [scheme, setScheme] = useState('light');
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    AsyncStorage.getItem('themeScheme')
      .then((v) => {
        if (v === 'dark' || v === 'light') setScheme(v);
      })
      .finally(() => setLoaded(true));
  }, []);

  const setTheme = useCallback(async (next) => {
    setScheme(next);
    try {
      await AsyncStorage.setItem('themeScheme', next);
    } catch (e) {
      // Non-fatal — worst case the choice doesn't persist across restarts.
    }
  }, []);

  const toggleTheme = useCallback(() => {
    setTheme(scheme === 'dark' ? 'light' : 'dark');
  }, [scheme, setTheme]);

  const colors = useMemo(() => ({ ...getColors(scheme), statusLabel }), [scheme]);

  const value = useMemo(
    () => ({ scheme, colors, setTheme, toggleTheme, loaded }),
    [scheme, colors, setTheme, toggleTheme, loaded]
  );

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme() {
  return useContext(ThemeContext);
}