// Holds the logged-in employee's session (empId, display name, reviewer
// flags) in one place, backed by AsyncStorage. Introduced alongside the
// drawer navigation redesign so every screen can just call useSession()
// instead of having empId/flags threaded through route.params across
// nested navigators (which gets messy once you have a Drawer containing
// several Stacks).
//
// Also handles session expiry: the access token issued at login is
// short-lived, and there's no silent client-side refresh (that would
// require holding a secret again, exactly what the login redesign
// removed). Two things catch an expired session instead of letting a
// screen just show a confusing raw error:
//   1. An AppState listener here checks the token's known expiry the
//      moment the app comes back to the foreground — catches the "left it
//      in the background for a while, came back, first tap looked broken"
//      case BEFORE any request is even made.
//   2. client.js's setOnAuthFailure() registers a callback fired whenever
//      any request comes back 401 WHILE a screen is actively using the
//      app — catches expiry that happens mid-session instead of on resume.
// Both paths land on the same signOutWithMessage() below.

import React, { createContext, useContext, useEffect, useRef, useState, useCallback } from 'react';
import { AppState } from 'react-native';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { setSessionToken, setAccessToken, isAccessTokenExpired, setOnAuthFailure } from './api/client';

const SessionContext = createContext(null);

export function SessionProvider({ children }) {
  const [session, setSession] = useState(null);
  const [loading, setLoading] = useState(true);
  const [expiredMessage, setExpiredMessage] = useState(null);
  // Mirrors `session` into a ref so the AppState listener (registered once,
  // on mount) always reads the CURRENT session rather than whatever it was
  // when the listener was first set up.
  const sessionRef = useRef(null);

  useEffect(() => {
    AsyncStorage.getItem('session')
      .then((value) => {
        const restored = value ? JSON.parse(value) : null;
        // Re-arm client.js's in-memory session token AND access token
        // after an app restart — both variables reset to null on every
        // fresh launch, even though the saved session survives in
        // AsyncStorage. Without this, every request after an app restart
        // would send an empty X-Session-Token/Authorization header and get
        // rejected, forcing a re-login every single time the app opens.
        setSessionToken(restored ? restored.sessionToken : null);
        setAccessToken(restored ? restored.accessToken : null, restored ? restored.accessTokenExpiresAt : null);
        sessionRef.current = restored;
        setSession(restored);
      })
      .catch(() => setSession(null))
      .finally(() => setLoading(false));
  }, []);

  const logout = useCallback(async () => {
    setSessionToken(null);
    setAccessToken(null);
    sessionRef.current = null;
    await AsyncStorage.removeItem('session');
    setSession(null);
  }, []);

  const signOutWithMessage = useCallback(
    (message) => {
      setExpiredMessage(message);
      logout();
    },
    [logout]
  );

  // Registered once — fires whenever ANY endpoint (other than login
  // itself) comes back 401, meaning the session/access token was rejected
  // server-side while a screen was actively using it.
  useEffect(() => {
    setOnAuthFailure(() => {
      if (sessionRef.current) {
        signOutWithMessage('Your session expired. Please log in again.');
      }
    });
  }, [signOutWithMessage]);

  // Catches the OTHER case: the token quietly passed its expiry while the
  // app was backgrounded, and nothing has actually tried a request yet.
  useEffect(() => {
    const sub = AppState.addEventListener('change', (nextState) => {
      if (nextState === 'active' && sessionRef.current && isAccessTokenExpired()) {
        signOutWithMessage('Your session expired while the app was in the background. Please log in again.');
      }
    });
    return () => sub.remove();
  }, [signOutWithMessage]);

  const login = useCallback(async (newSession) => {
    setSessionToken(newSession.sessionToken);
    setAccessToken(newSession.accessToken, newSession.accessTokenExpiresAt);
    sessionRef.current = newSession;
    await AsyncStorage.setItem('session', JSON.stringify(newSession));
    setExpiredMessage(null);
    setSession(newSession);
  }, []);

  const clearExpiredMessage = useCallback(() => setExpiredMessage(null), []);

  return (
    <SessionContext.Provider
      value={{ session, loading, login, logout, expiredMessage, clearExpiredMessage }}
    >
      {children}
    </SessionContext.Provider>
  );
}

// Usage: const { session, login, logout, expiredMessage, clearExpiredMessage } = useSession();
// session is null when logged out, otherwise
// { empId, displayName, isReportingManager, isFinanceManager }.
// expiredMessage is a friendly string LoginScreen shows when the session
// was ended automatically (rather than by the person tapping Logout) —
// null the rest of the time.
export function useSession() {
  return useContext(SessionContext);
}