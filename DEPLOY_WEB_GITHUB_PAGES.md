# Hosting the web build on GitHub Pages

Gives your team a public URL. No laptop running, no tunnel, no APK.

## Before you start

Confirm the app actually works in a browser, because a broken web build
deploys just as happily as a working one:

```
npx expo start --web
```

Some dependencies have no real web implementation and may need
`Platform.OS === 'web'` guards — `expo-notifications`,
`@react-native-community/datetimepicker`, `expo-document-picker`,
`expo-file-system`, `expo-sharing`. Fix anything fatal before deploying.

---

Target repo: **https://github.com/napeedmai/expenses_app** (already exists,
public, holds the source on `main`).

The built site goes on a separate `gh-pages` branch so it never mixes with
your source history.

## 1. Base URL — already set

`app.json` now contains:

```json
"experiments": { "baseUrl": "/expenses_app" }
```

It must equal the repo name exactly, because Pages serves project repos at
`https://napeedmai.github.io/expenses_app/` while Expo would otherwise
reference assets from `/`. A mismatch is the usual cause of a blank white
page with 404s on every `.js` file.

## 2. Build

```
npx expo export -p web
```

Produces `dist/`.

## 3. Add .nojekyll  — DO NOT SKIP

GitHub Pages runs Jekyll, and Jekyll **ignores every folder whose name starts
with an underscore**. Expo puts all its JavaScript in `_expo/`. Without this
file the page loads and renders nothing, with 404s on every bundle.

```
cd dist
type nul > .nojekyll
```

## 4. Push dist to the gh-pages branch

From inside `dist` (this is a throwaway repo used only to push the build):

```
git init
git add -A
git commit -m "Web build"
git branch -M gh-pages
git remote add origin https://github.com/napeedmai/expenses_app.git
git push --force origin gh-pages
```

`--force` is correct here and safe: `gh-pages` holds only generated output,
and each deploy replaces it wholesale. It does **not** touch `main`.

Note `dist/` is gitignored in the project, which is why it gets its own
throwaway repo rather than being committed to `main`.

## 5. Enable Pages

Repo → **Settings** → **Pages** → Source: **Deploy from a branch**,
Branch: `gh-pages`, folder: `/ (root)` → Save.

Live within a minute or two at:

```
https://napeedmai.github.io/expenses_app/
```

## 6. Redeploying after code changes

From the project root:

```
npx expo export -p web
cd dist
type nul > .nojekyll
git init
git add -A
git commit -m "Update"
git branch -M gh-pages
git remote add origin https://github.com/napeedmai/expenses_app.git
git push --force origin gh-pages
```

`expo export` wipes `dist`, so the git setup is repeated each time. If you
redeploy often, a GitHub Actions workflow building on push to `main` is
worth the setup.

---

## CORS — the app will not work without this

Your team's browsers will call `https://karyasiddhi.trinamix.com` from the
`github.io` origin. Browsers block cross-origin requests unless the server
explicitly permits them, so **every API call including login fails** until
ORDS is configured to allow it.

This never came up for the mobile app because native apps aren't subject to
CORS. `13_cors_fix_for_web_testing.sql` exists for exactly this; your notes
say to skip it for mobile-only deployments, which is why it was never run
on prod.

Apply it to `REPO` with the Pages origin allowed:

```
https://napeedmai.github.io
```

Set `p_origins_allowed` on the ORDS modules to that origin. Check what is
currently allowed with:

```sql
SELECT name, uri_prefix, origins_allowed FROM user_ords_modules;
```

Note the origin is scheme + host only — no path, no trailing slash.

## Security note

A public GitHub Pages site is readable by anyone, and it talks to your
production API. The build contains no secrets (`config.js` holds only the
base URL, and OAuth credentials live server-side), so exposure is limited to
the URL itself — but anyone who finds the page can attempt logins against
prod. Take the repo private, or delete it once the demo is done.
