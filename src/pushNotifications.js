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
if (!IS_EXPO_GO) {
  Notifications.setNotificationHandler({
    handleNotification: async () => ({
      shouldShowAlert: true,
      shouldPlaySound: true,
      shouldSetBadge: false,
    }),
  });
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
    if (IS_EXPO_GO) return; // see note above — Expo Go can't do this at all

    let cancelled = false;

    async function register() {
      try {
        if (Platform.OS === 'android') {
          await Notifications.setNotificationChannelAsync('default', {
            name: 'default',
            importance: Notifications.AndroidImportance.DEFAULT,
          });
        }

        const { status: existingStatus } = await Notifications.getPermissionsAsync();
        let finalStatus = existingStatus;
        if (existingStatus !== 'granted') {
          const { status } = await Notifications.requestPermissionsAsync();
          finalStatus = status;
        }
        if (finalStatus !== 'granted' || cancelled) {
          return; // user declined, or this screen unmounted mid-request
        }

        const projectId =
          Constants?.expoConfig?.extra?.eas?.projectId || Constants?.easConfig?.projectId;

        const tokenResponse = await Notifications.getExpoPushTokenAsync(
          projectId ? { projectId } : undefined
        );
        const token = tokenResponse && tokenResponse.data;
        if (!token || cancelled) return;

        await registerPushToken(empId, token);
        registeredFor.current = empId;
      } catch (e) {
        // Non-fatal by design — the app works fully without push
        // notifications, this just means this particular device won't
        // receive them. The most common cause during development is
        // running in Expo Go rather than a development build (see the
        // note at the top of this file), which isn't something to alert
        // the user about every time the app opens.
      }
    }

    register();
    return () => {
      cancelled = true;
    };
  }, [empId]);
}