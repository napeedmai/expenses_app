// Where a receipt comes from: the camera, the gallery, or a file.
//
//
// WHY THIS EXISTS
// ---------------
// The app only ever offered a FILE BROWSER. On a phone that means: leave the
// app, open the camera, take the photo, come back, find it in Files. For an
// expense app whose whole job is photographing receipts, that is backwards.
//
// The gap was invisible during web testing, because a browser's
// <input type="file"> quietly offers "Camera" on mobile. So the web build got a
// camera for free from the platform and the real app -- the one that ships to
// the stores and that people will actually use -- had none at all.
//
//
// ALL THREE RETURN THE SAME SHAPE
//
//     { uri, name, mimeType, size, file? }
//
// which is exactly what expo-document-picker already produced, so nothing
// downstream changes: the same compression, the same scan, the same upload.
// `file` is web-only -- the real File object, which uploadItemAttachment and
// scanReceipt use to send actual bytes rather than a "[object Object]" string.
//
//
// WHY expo-image-picker RATHER THAN A CAMERA SCREEN
// -------------------------------------------------
// It hands off to the phone's own camera app, which people already know how to
// use and which handles focus, flash and orientation properly. A camera built
// into this app would be worse at all three and would be ours to maintain.

import { Platform } from 'react-native';
import * as DocumentPicker from 'expo-document-picker';

// expo-image-picker names files like "ImagePicker_abc123.jpeg" or gives no name
// at all. The extension matters -- BillSheet decides what can be scanned from
// it, and the server stores it as ATTACHMENT_FILENAME -- so build a sensible
// one rather than filing every receipt under a random id.
function receiptName(uri, mimeType) {
  const fromMime = (mimeType || '').split('/')[1];
  const fromUri = String(uri || '').split('?')[0].split('.').pop();
  const ext = (fromMime || fromUri || 'jpg').toLowerCase().replace('jpeg', 'jpg');
  const stamp = new Date().toISOString().slice(0, 19).replace(/[-:T]/g, '');
  return `receipt-${stamp}.${ext}`;
}

function fromImagePicker(asset) {
  if (!asset) return null;
  const mimeType = asset.mimeType || 'image/jpeg';
  return {
    uri: asset.uri,
    name: asset.fileName || receiptName(asset.uri, mimeType),
    mimeType,
    size: asset.fileSize ?? null,
    file: asset.file,          // web only; undefined on native
  };
}

/**
 * Take a photo. Returns the file, or null if the person cancelled or refused
 * permission.
 *
 * Throws only with a message worth showing. A denied permission is NOT an
 * error -- the person said no, which is an answer, and the caller offers them
 * the file browser instead.
 */
export async function takePhoto() {
  const ImagePicker = await import('expo-image-picker');

  const perm = await ImagePicker.requestCameraPermissionsAsync();
  if (!perm.granted) {
    const err = new Error(
      'The camera is not available. Allow camera access in your phone settings, '
      + 'or choose an existing file instead.'
    );
    err.permissionDenied = true;
    throw err;
  }

  const res = await ImagePicker.launchCameraAsync({
    // No editing step. Cropping a receipt is how someone accidentally cuts off
    // the total, and the scan needs the whole document.
    allowsEditing: false,
    // Full quality. The photo is compressed later ONLY for storage, while the
    // original goes to the AI -- see compressImage.js. Compressing here would
    // throw away detail before anything had read it.
    quality: 1,
    exif: false,
  });

  if (res.canceled) return null;
  return fromImagePicker(res.assets && res.assets[0]);
}

/** Pick an existing photo from the gallery. Same contract as takePhoto. */
export async function pickFromGallery() {
  const ImagePicker = await import('expo-image-picker');

  const perm = await ImagePicker.requestMediaLibraryPermissionsAsync();
  if (!perm.granted) {
    const err = new Error(
      'Access to your photos is not available. Allow it in your phone settings, '
      + 'or choose a file instead.'
    );
    err.permissionDenied = true;
    throw err;
  }

  const res = await ImagePicker.launchImageLibraryAsync({
    allowsEditing: false,
    quality: 1,
    exif: false,
  });

  if (res.canceled) return null;
  return fromImagePicker(res.assets && res.assets[0]);
}

/** The original path: any file, including PDFs and spreadsheets. */
export async function pickFile() {
  const res = await DocumentPicker.getDocumentAsync({ copyToCacheDirectory: true });
  if (res.canceled) return null;
  const f = res.assets && res.assets[0];
  if (!f) return null;
  return {
    uri: f.uri,
    name: f.name,
    mimeType: f.mimeType,
    size: f.size,
    file: f.file,
  };
}

// On web the browser's own file input already offers Camera on a phone and
// Files everywhere else, so a three-way menu would be a worse version of
// something the platform does properly. Native gets the menu; web goes straight
// to the file picker, as it does today.
export const SUPPORTS_CAMERA = Platform.OS !== 'web';
