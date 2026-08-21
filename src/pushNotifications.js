// Real push notifications — the actual phone-notification-banner kind, not
// just the in-app bell panel on Home.
//
// IMPORTANT — how to actually TEST this on your phone:
// Expo Go (the app you scan a QR code into) stopped supporting remote push
// notifications starting with Expo SDK 53 — this is a real limitation from
// Expo itself, not a bug in this code. To receive an actual push
// notification, you need a "development build" of this app instead of
// Expo Go:
//   1. npx expo install expo-dev-client
//   2. eas build --profile development --platform android   (or ios)
//   3. Install the resulting app on your phone (the build finishes with a
//      download link/QR code)
//   4. npx expo start --dev-client   (instead of the usual `npx expo start`)
// Everything below still runs fine under Expo Go — it just won't be able
// to obtain a real push token there, so registration quietly does nothing
// instead of erroring.
//
// Also requires a free Expo account + `eas.json`/project ID set up if this
// project doesn't have one yet (`eas init`) — expo-notifications needs an
// Expo "project ID" to mint a push token.

import { useEffect, useRef } from 'react';
import { Platform } from 'react-native';
import * as Notifications from 'expo-notifications';
import Constants from 'expo-constants';
import { registerPushToken } from './api/client';

// True when running inside plain Expo Go, where remote push notifications
// have not been supported since SDK 53 — checked once up front so we can
// skip touching expo-notifications entirely in that case, rather than
// letting it log its own scary-looking red ERROR line on every app open.
// (Constants.appOwnership is the older/simpler check; executionEnvironment
// is the newer one — checking both covers Expo Go across SDK versions.)
const IS_EXPO_GO =
  Constants.appOwnership === 'expo' || Constants.executionEnvironment === 'storeClient';

// Makes a notification actually show (banner + sound) even while the app
// is open in the foreground — without this, foreground pushes arrive
// silently with no visible banner. Skipped in Expo Go since it can't
// receive remote pushes there anyway.
//
// shouldShowBanner / shouldShowList, NOT shouldShowAlert. The single
// shouldShowAlert key was split into these two in expo-notifications for
// SDK 53+, and the old key is now ignored — so a handler still using it
// returns "show nothing", and a notification arriving while the app is
// open produces no banner at all while still being delivered. That is a
// silent presentation failure, not a delivery failure: the push arrives
// fine, the OS just never draws it.
//   shouldShowBanner -> the heads-up banner that slides down
//   shouldShowList   -> the entry in the notification drawer/centre
if (!IS_EXPO_GO) {
  Notifications.setNotificationHandler({
    handleNotification: async () => ({
      shouldShowBanner: true,
      shouldShowList: true,
      shouldPlaySound: true,
      shouldSetBadge: false,
    }),
  });
}

// Why registration last succeeded or failed, so a human can find out.
//
// Registration is deliberately non-fatal — the app is fully usable without
// push — but "non-fatal" had been implemented as an empty catch block, which
// made a failure completely undiagnosable: the phone simply never appeared in
// EMP_PUSH_TOKENS and nothing anywhere said why. Every step below records its
// outcome here, and Settings displays it.
let lastPushStatus = { state: 'idle', detail: 'Not attempted yet.' };
const statusListeners = new Set();

function setPushStatus(state, detail) {
  lastPushStatus = { state, detail, at: new Date().toISOString() };
  statusListeners.forEach((fn) => {
    try {
      fn(lastPushStatus);
    } catch (e) {
      /* a broken listener must not break registration */
    }
  });
}

export function getPushStatus() {
  return lastPushStatus;
}

export function subscribeToPushStatus(fn) {
  statusListeners.add(fn);
  fn(lastPushStatus);
  return () => statusListeners.delete(fn);
}

// Call once near the root of the app (see App.js) whenever a session
// exists. Requests permission, gets this device's Expo push token, and
// sends it to the backend so it knows where to deliver notifications for
// this employee. Safe to call on every render — only actually does
// anything once per empId per app session.
export function usePushNotifications(empId) {
  const registeredFor = useRef(null);

  useEffect(() => {
    if (!empId) return;
    if (registeredFor.current === empId) return;
    if (IS_EXPO_GO) {
      setPushStatus(
        'unsupported',
        'Running in Expo Go, which cannot receive push notifications since SDK 53. Install an EAS build instead.'
      );
      return;
    }

    let cancelled = false;

    async function register() {
      try {
        // Android 8+ decides how intrusive a notification is from its
        // CHANNEL, not from the message. AndroidImportance.DEFAULT puts the
        // notification in the drawer silently — no heads-up banner, no
        // sound — which looks exactly like push being broken even though
        // delivery worked. MAX is what produces the banner that slides
        // down over whatever the person is doing.
        //
        // Importance is fixed when the channel is FIRST created. Raising it
        // here does nothing on a phone that already has the old channel;
        // the app must be reinstalled, or the channel renamed. Hence
        // 'expense-updates' rather than reusing 'default'.
        if (Platform.OS === 'android') {
          await Notifications.setNotificationChannelAsync('expense-updates', {
            name: 'Expense updates',
            description: 'Approvals, revisions and rejections on your expenses.',
            importance: Notifications.AndroidImportance.MAX,
            vibrationPattern: [0, 250, 250, 250],
            lockscreenVisibility: Notifications.AndroidNotificationVisibility.PUBLIC,
            sound: 'default',
          });
        }

        const { status: existingStatus } = await Notifications.getPermissionsAsync();
        let finalStatus = existingStatus;
        if (existingStatus !== 'granted') {
          const { status } = await Notifications.requestPermissionsAsync();
          finalStatus = status;
        }
        if (cancelled) return;
        if (finalStatus !== 'granted') {
          setPushStatus(
            'denied',
            `Notification permission is "${finalStatus}". Enable notifications for this app in the phone's settings, then log out and back in.`
          );
          return;
        }

        const projectId =
          Constants?.expoConfig?.extra?.eas?.projectId || Constants?.easConfig?.projectId;

        if (!projectId) {
          setPushStatus(
            'no-project-id',
            'No EAS projectId in the build. Run "eas init", commit app.json, and rebuild the app.'
          );
          return;
        }

        const tokenResponse = await Notifications.getExpoPushTokenAsync({ projectId });
        const token = tokenResponse && tokenResponse.data;
        if (cancelled) return;
        if (!token) {
          setPushStatus('no-token', 'Expo returned no push token for this device.');
          return;
        }

        // Reaching the server is a separate failure from getting a token, and
        // they need different fixes -- so they are reported separately.
        try {
          await registerPushToken(empId, token);
        } catch (e) {
          setPushStatus(
            'server-rejected',
            `Got a token but the server would not store it: ${e.message || e}`
          );
          return;
        }

        registeredFor.current = empId;
        setPushStatus('registered', `Registered as ${token.slice(0, 28)}...`);
      } catch (e) {
        // Still non-fatal — the app works fully without push, and nobody
        // wants an error dialog on every launch because notifications are
        // unavailable. But the reason is now recorded rather than discarded:
        // Settings shows it, which is the difference between "push doesn't
        // work" and knowing which of the six steps above failed.
        setPushStatus('error', String((e && e.message) || e));
      }
    }

    register();
    return () => {
      cancelled = true;
    };
  }, [empId]);
}