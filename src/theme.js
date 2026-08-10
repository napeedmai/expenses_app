// Shared design tokens for the app's visual style — the "design_2" look
// (blue/slate, rounded cards) approved for the whole app, per
// design_combined.html.
//
// Light/dark: getColors(scheme) returns one of the two palettes below.
// Screens don't import `colors` directly anymore — they call
// `const { colors } = useTheme();` (see src/ThemeContext.js) so the whole
// app re-renders with the right palette when the Settings toggle flips.
// `colors` is still exported here too, as a light-mode fallback, for any
// non-component code that might need a color outside of React (there
// isn't any right now, but it's harmless to keep).

export const lightColors = {
  bg: '#f8fafc', // slate-50 — screen backgrounds
  slate900: '#0f172a', // hero/dark surfaces (login banner, bottom nav pill)
  slate800: '#1e293b',
  surface: '#ffffff', // cards
  border: '#e2e8f0', // slate-200
  borderStrong: '#cbd5e1', // slate-300
  text: '#0f172a', // slate-900
  textMuted: '#64748b', // slate-500
  textFaint: '#94a3b8', // slate-400

  primary: '#2563eb', // blue-600 — the one accent color
  primaryDark: '#1d4ed8', // blue-700 (pressed/hover)
  primaryTint: '#eff6ff', // blue-50

  amber: '#f59e0b',
  amberTint: '#fef3c7',
  emerald: '#16a34a',
  emeraldTint: '#dcfce7',
  red: '#dc2626',
  redTint: '#fee2e2',

  status: {
    DRAFT: { bg: '#f1f5f9', text: '#475569' },
    SUBMITTED: { bg: '#eff6ff', text: '#1d4ed8' },
    REVISION_REQUESTED: { bg: '#fef3c7', text: '#b45309' },
    APPROVED: { bg: '#dcfce7', text: '#15803d' },
    REJECTED: { bg: '#fee2e2', text: '#b91c1c' },
  },
};

export const darkColors = {
  bg: '#0b1220',
  slate900: '#000000', // login banner / nav pill go true black in dark mode
  slate800: '#1e293b',
  surface: '#151f30',
  border: '#26344a',
  borderStrong: '#38496399',
  text: '#f1f5f9',
  textMuted: '#94a3b8',
  textFaint: '#64748b',

  primary: '#3b82f6', // blue-500 — brighter for contrast against dark bg
  primaryDark: '#2563eb',
  primaryTint: 'rgba(59,130,246,0.16)',

  amber: '#f59e0b',
  amberTint: 'rgba(245,158,11,0.16)',
  emerald: '#22c55e',
  emeraldTint: 'rgba(34,197,94,0.16)',
  red: '#f87171',
  redTint: 'rgba(248,113,113,0.16)',

  status: {
    DRAFT: { bg: 'rgba(148,163,184,0.16)', text: '#cbd5e1' },
    SUBMITTED: { bg: 'rgba(59,130,246,0.16)', text: '#93c5fd' },
    REVISION_REQUESTED: { bg: 'rgba(245,158,11,0.16)', text: '#fbbf24' },
    APPROVED: { bg: 'rgba(34,197,94,0.16)', text: '#4ade80' },
    REJECTED: { bg: 'rgba(248,113,113,0.16)', text: '#fca5a5' },
  },
};

// Same in both themes — just what word to show for each status code.
export const statusLabel = {
  DRAFT: 'Draft',
  SUBMITTED: 'Submitted',
  REVISION_REQUESTED: 'Needs Revision',
  APPROVED: 'Approved',
  REJECTED: 'Rejected',
};

// A richer label than statusLabel — distinguishes the two approval stages
// that both otherwise show as the flat "Submitted" status. `current_stage`
// comes back as 'MANAGER' while it's waiting on the Reporting Manager, then
// flips to 'FINANCE' the moment the manager approves (see
// process_expense_action in 07_phase2_reviewer_endpoints.sql) — so an
// employee (or the Finance Manager reviewing it) can actually tell "my
// manager already said yes, this is just waiting on Finance now" instead of
// seeing "Submitted" the entire time with no visible progress.
export function stageLabel(status, currentStage) {
  if (status === 'SUBMITTED') {
    if (currentStage === 'FINANCE') return 'Approved by Manager — Awaiting Finance';
    if (currentStage === 'MANAGER') return 'Awaiting Manager Approval';
    return statusLabel.SUBMITTED;
  }
  return statusLabel[status] || status;
}

// A short version of stageLabel, for small pill badges (list rows) where
// the full phrase above wouldn't fit or would wrap awkwardly.
export function stageLabelShort(status, currentStage) {
  if (status === 'SUBMITTED') {
    if (currentStage === 'FINANCE') return 'With Finance';
    if (currentStage === 'MANAGER') return 'With Manager';
    return statusLabel.SUBMITTED;
  }
  return statusLabel[status] || status;
}

export function getColors(scheme) {
  return scheme === 'dark' ? darkColors : lightColors;
}

// Light-mode fallback for anything importing `colors` directly (kept for
// backwards compatibility — components should use useTheme() instead).
export const colors = { ...lightColors, statusLabel };

export const radius = { sm: 10, md: 14, lg: 20, xl: 28, pill: 999 };

export const shadow = {
  card: {
    shadowColor: '#000',
    shadowOpacity: 0.08,
    shadowRadius: 10,
    shadowOffset: { width: 0, height: 4 },
    elevation: 2,
  },
  raised: {
    shadowColor: '#000',
    shadowOpacity: 0.16,
    shadowRadius: 20,
    shadowOffset: { width: 0, height: 10 },
    elevation: 6,
  },
};

// Best-effort icon per expense Type label (see src/constants/expenseTypes.js)
// — purely cosmetic, falls back to a generic tag icon for anything not
// matched below.
export function iconForType(type) {
  const t = (type || '').toLowerCase();
  if (t.includes('air') || t.includes('fare')) return 'airplane-outline';
  if (t.includes('hotel') || t.includes('accommodation')) return 'bed-outline';
  if (t.includes('taxi') || t.includes('car') || t.includes('travel')) return 'car-outline';
  if (t.includes('meal') || t.includes('food') || t.includes('dinner') || t.includes('lunch')) return 'restaurant-outline';
  if (t.includes('phone') || t.includes('cell') || t.includes('telephone')) return 'call-outline';
  if (t.includes('internet') || t.includes('wifi')) return 'wifi-outline';
  if (t.includes('medical')) return 'medkit-outline';
  if (t.includes('gift')) return 'gift-outline';
  if (t.includes('visa')) return 'document-text-outline';
  if (t.includes('parking')) return 'car-sport-outline';
  if (t.includes('courier')) return 'cube-outline';
  if (t.includes('gas')) return 'flame-outline';
  return 'pricetag-outline';
}

// Small colored file-type badge (extension + tint) for attachment rows —
// e.g. red "PDF", blue "JPG", green "XLS" — purely cosmetic, based on the
// filename's extension only (we don't store file size, so that's never
// shown/invented). Same in both themes — these tints are already low-
// opacity in the dark colors above / solid in light, but this helper's
// values are only used for the light-leaning badge look; dark screens
// still read fine against a dark card since these are pastel bg + dark
// text pairs, kept deliberately simple rather than theme-branching.
export function fileBadgeForName(name) {
  const ext = (name || '').split('.').pop().toUpperCase().slice(0, 4);
  const map = {
    PDF: { bg: '#fee2e2', text: '#dc2626' },
    JPG: { bg: '#eff6ff', text: '#2563eb' },
    JPEG: { bg: '#eff6ff', text: '#2563eb' },
    PNG: { bg: '#eff6ff', text: '#2563eb' },
    XLS: { bg: '#dcfce7', text: '#15803d' },
    XLSX: { bg: '#dcfce7', text: '#15803d' },
    CSV: { bg: '#dcfce7', text: '#15803d' },
    ZIP: { bg: '#f1f5f9', text: '#475569' },
    RAR: { bg: '#f1f5f9', text: '#475569' },
  };
  return { label: ext || 'FILE', ...(map[ext] || { bg: '#f1f5f9', text: '#475569' }) };
}