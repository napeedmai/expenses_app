// Shrink a receipt photo so it fits the 1 MB attachment limit.
//
//
// THE PROBLEM THIS SOLVES
// -----------------------
// A phone camera produces 3-5 MB. The receipt endpoint stores at most 1 MB
// (c_max_bytes in db/65). So before this, a real photo of a real receipt could
// be SCANNED but not ATTACHED, and the person had to take a second, worse photo
// just to have something to file. Two photos of one receipt, and the one that
// gets kept is the deliberately bad one.
//
//
// WHAT IT DOES NOT TOUCH
// ----------------------
// The ORIGINAL is still what gets sent to the AI. Downscaling first would save
// a little money and cost accuracy on exactly the thing that matters -- a total
// printed in 8pt next to three other numbers. The scan endpoint accepts 6 MB
// precisely so it can have the good copy. See BillSheet: `picked` is what gets
// attached, `scanSource` is what gets read.
//
// PDFs are returned untouched. There is no sensible lossy resize for one, and a
// PDF receipt is almost always small anyway.
//
//
// WHY TWO IMPLEMENTATIONS
// -----------------------
// Native uses expo-image-manipulator. Web uses a canvas, which needs no
// dependency at all and avoids finding out the hard way which parts of the
// library behave differently in a browser.

import { Platform } from 'react-native';

const JPEG = 'image/jpeg';

// Quality/width pairs, tried in order until one fits. Starts by only
// recompressing at full size -- a 4 MB photo is usually 4 MB because it is a
// PNG or a low-compression JPEG, not because it is enormous, and keeping the
// pixels is what keeps the small print readable if anyone opens it later.
const ATTEMPTS = [
  { width: null, quality: 0.8 },
  { width: 2400, quality: 0.75 },
  { width: 1800, quality: 0.7 },
  { width: 1400, quality: 0.65 },
  { width: 1000, quality: 0.6 },
];

function isImage(file) {
  const mime = String(file?.mimeType || '').toLowerCase();
  if (mime.startsWith('image/')) return true;
  const ext = String(file?.name || '').split('.').pop().toLowerCase();
  return ['jpg', 'jpeg', 'png', 'webp', 'heic'].includes(ext);
}

function renameToJpg(name) {
  return String(name || 'receipt').replace(/\.[^.]+$/, '') + '.jpg';
}

// ---- web -------------------------------------------------------------------

async function shrinkOnWeb(file, maxBytes) {
  const blob = file.file || (await (await fetch(file.uri)).blob());
  const bitmap = await createImageBitmap(blob);

  for (const attempt of ATTEMPTS) {
    const scale = attempt.width ? Math.min(1, attempt.width / bitmap.width) : 1;
    const canvas = document.createElement('canvas');
    canvas.width = Math.round(bitmap.width * scale);
    canvas.height = Math.round(bitmap.height * scale);
    canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);

    const out = await new Promise((resolve) =>
      canvas.toBlob(resolve, JPEG, attempt.quality)
    );
    if (out && out.size <= maxBytes) {
      const name = renameToJpg(file.name);
      // A File rather than a Blob: uploadItemAttachment reads file.file on web,
      // and the name is what ends up in ATTACHMENT_FILENAME.
      const asFile = new File([out], name, { type: JPEG });
      return { uri: URL.createObjectURL(out), name, mimeType: JPEG,
               size: out.size, file: asFile };
    }
  }
  return null;   // could not get it small enough
}

// ---- native ----------------------------------------------------------------

async function shrinkOnNative(file, maxBytes) {
  const IM = await import('expo-image-manipulator');
  const FS = await import('expo-file-system/legacy');

  // SDK 52 introduced a new object-oriented API and deprecated manipulateAsync.
  // Both exist in SDK 54. Detect rather than assume -- importing the wrong one
  // is precisely how openAttachment.js broke on expo-file-system.
  const legacy = typeof IM.manipulateAsync === 'function';

  for (const attempt of ATTEMPTS) {
    const actions = attempt.width ? [{ resize: { width: attempt.width } }] : [];
    let uri;

    if (legacy) {
      const res = await IM.manipulateAsync(file.uri, actions, {
        compress: attempt.quality,
        format: IM.SaveFormat.JPEG,
      });
      uri = res.uri;
    } else {
      const ctx = IM.ImageManipulator.manipulate(file.uri);
      if (attempt.width) ctx.resize({ width: attempt.width });
      const image = await ctx.renderAsync();
      const saved = await image.saveAsync({
        compress: attempt.quality,
        format: IM.SaveFormat.JPEG,
      });
      uri = saved.uri;
    }

    const info = await FS.getInfoAsync(uri, { size: true });
    if (info.exists && info.size <= maxBytes) {
      const name = renameToJpg(file.name);
      return { uri, name, mimeType: JPEG, size: info.size };
    }
  }
  return null;
}

// ---- the one thing anyone calls --------------------------------------------

/**
 * Returns a version of `file` under maxBytes, or the original when it already
 * fits, is not an image, or cannot be shrunk far enough.
 *
 * NEVER THROWS. A failure here must leave the person exactly where they were --
 * with a file too big to attach and a clear message about it -- rather than
 * turning "your photo is large" into "something went wrong".
 */
export async function shrinkForAttachment(file, maxBytes) {
  if (!file) return { file: null, compressed: false };
  if (!file.size || file.size <= maxBytes) return { file, compressed: false };
  if (!isImage(file)) return { file, compressed: false };

  try {
    const out = Platform.OS === 'web'
      ? await shrinkOnWeb(file, maxBytes)
      : await shrinkOnNative(file, maxBytes);

    if (out) return { file: out, compressed: true, originalSize: file.size };
    return { file, compressed: false, failed: true };
  } catch (e) {
    return { file, compressed: false, failed: true, error: e?.message };
  }
}
