// Downloading a receipt and opening it in something that can display it.
//
// Shared by AddEditExpenseScreen (the person who attached it) and
// ReviewExpenseScreen (the person deciding whether to approve it). It lived in
// both screens as a near-copy until the PDF bug had to be fixed twice.
//
// THE BUG THIS EXISTS TO PREVENT
// ------------------------------
// Non-image attachments were handed to Sharing.shareAsync, which opens the
// "send this to someone" sheet — so a PDF offered Gmail and WhatsApp but no
// way to simply read it. Images worked, everything else appeared broken.
// Opening a file is ACTION_VIEW, not a share.
//
// Two details Android will not forgive:
//   * a content:// URI, because file:// URIs have been rejected across app
//     boundaries since Android 7 (FileUriExposedException)
//   * FLAG_GRANT_READ_URI_PERMISSION, or the viewer opens and immediately
//     fails with a permission error

import { Platform } from 'react-native';
// The /legacy import is deliberate. SDK 54 replaced downloadAsync and
// cacheDirectory with a new File/Directory class API; the legacy path keeps
// these calls working without a rewrite. Importing plain 'expo-file-system'
// here makes downloadAsync throw a deprecation error at runtime rather than
// warn at build time, which surfaces to the user as "Preview failed".
import * as FileSystem from 'expo-file-system/legacy';
import * as Sharing from 'expo-sharing';
import * as IntentLauncher from 'expo-intent-launcher';

// Android picks the app that can open a file purely from its MIME type. Servers
// commonly answer application/octet-stream for anything that isn't an image,
// from which Android concludes "nothing can open this" and does nothing at all
// — no error, no viewer. The filename still knows what the file is.
const MIME_BY_EXTENSION = {
  pdf: 'application/pdf',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  png: 'image/png',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  xls: 'application/vnd.ms-excel',
  csv: 'text/csv',
  rar: 'application/vnd.rar',
};

export function mimeFromFilename(name) {
  const ext = String(name || '').split('.').pop().toLowerCase();
  return MIME_BY_EXTENSION[ext] || null;
}

/**
 * Download an attachment and show it.
 *
 * @param {string}   url        attachment endpoint
 * @param {object}   headers    auth headers
 * @param {string}   filename   used for the cache name and to recover the type
 * @param {function} onImage    called with a local/object URI for images, so
 *                              the caller can show them in its own modal
 * @returns {Promise<'image'|'opened'|'shared'>}
 * @throws  {Error}  with a message fit to show the person
 */
export async function openAttachment({ url, headers, filename, onImage }) {
  const safeName = filename || 'attachment';

  // Web has no filesystem (FileSystem.cacheDirectory is null) and no OS share
  // sheet. Fetch the bytes, wrap them in an object URL, and let the browser
  // deal with it — every browser can display a PDF in a tab.
  if (Platform.OS === 'web') {
    const res = await fetch(url, { headers });
    if (!res.ok) throw new Error('Failed to download attachment.');
    const blob = await res.blob();
    const objectUrl = URL.createObjectURL(blob);
    if ((blob.type || '').startsWith('image/')) {
      onImage(objectUrl);
      return 'image';
    }
    window.open(objectUrl, '_blank');
    return 'opened';
  }

  const localUri = FileSystem.cacheDirectory + safeName;
  const result = await FileSystem.downloadAsync(url, localUri, { headers });
  if (result.status !== 200) throw new Error('Failed to download attachment.');

  let contentType = (
    result.headers['Content-Type'] ||
    result.headers['content-type'] ||
    ''
  ).toLowerCase();

  if (!contentType || contentType.startsWith('application/octet-stream')) {
    contentType = mimeFromFilename(safeName) || contentType;
  }

  if (contentType.startsWith('image/')) {
    onImage(result.uri);
    return 'image';
  }

  if (Platform.OS === 'android') {
    try {
      const contentUri = await FileSystem.getContentUriAsync(result.uri);
      await IntentLauncher.startActivityAsync('android.intent.action.VIEW', {
        data: contentUri,
        flags: 1, // FLAG_GRANT_READ_URI_PERMISSION
        type: contentType || '*/*',
      });
      return 'opened';
    } catch (e) {
      // No installed app claims this type. The share sheet below at least lets
      // the person send it somewhere that can open it.
    }
  }

  if (await Sharing.isAvailableAsync()) {
    await Sharing.shareAsync(result.uri, { mimeType: contentType || undefined });
    return 'shared';
  }

  throw new Error(
    'No app on this device can open this file type. Try installing a PDF reader.'
  );
}

export default openAttachment;
