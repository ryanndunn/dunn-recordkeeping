# Google Cloud setup (one time, about 20 minutes)

You need this before **Phase 2** (real distances) and **Phase 3** (Google Sheet).
Phase 1 runs without it.

App identifiers used below:

| Platform | Identifier |
|---|---|
| Android package name | `com.dunnrecordkeeping.mileage_log` |
| macOS bundle ID | `com.dunnrecordkeeping.mileageLog` |

## 1. Create a project

1. Go to <https://console.cloud.google.com/> and sign in with the Google account
   that should own the mileage spreadsheet.
2. Project picker (top bar), then **New project**. Name it `Mileage Log`, then **Create**.
3. **Billing**: link a billing account. Routes and Places require one. Personal
   use (a few trips a day) stays inside Google's free monthly allowance. You can
   also set a budget alert under **Billing → Budgets & alerts**, for example $5.

## 2. Turn on the APIs

**APIs & Services → Library**. Search for each of these and click **Enable**:

- Google Sheets API
- Google Drive API (lets the app find its spreadsheet on your second device)
- Routes API
- Places API (New)

## 3. OAuth consent screen

**APIs & Services → OAuth consent screen** (may be labeled **Google Auth Platform**):

1. App name `Mileage Log`, user support email = your email.
2. Audience: **External** for a personal Gmail account. Choose **Internal** if your
   Google account is in a Google Workspace organization.
3. Data access / scopes: add `.../auth/drive.file`. That is the only scope
   the app uses, and it can only see files the app created itself.
4. Test users: add your own email address.
5. After the app works, click **Publish app**. Because `drive.file` is a
   non-sensitive scope, Google does not review it, and publishing stops the
   weekly "sign in again" prompts that apps left in testing mode get.

## 4. OAuth client IDs

**APIs & Services → Credentials → Create credentials → OAuth client ID**.

### Android

- Application type: **Android**
- Package name: `com.dunnrecordkeeping.mileage_log`
- SHA-1: run this on the Mac after Flutter and Android Studio are installed,
  then copy the `SHA1:` line:

```bash
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android
```

  When you make a release build later (Phase 5), add a second Android client
  using the release keystore's SHA-1.

### macOS

- Application type: **iOS** (Google uses the iOS client type for macOS apps)
- Bundle ID: `com.dunnrecordkeeping.mileageLog`
- After it's created, note the **Client ID** and the **iOS URL scheme**
  (`com.googleusercontent.apps.…`). Phase 3 puts both into the macOS app.

## 5. API key for Routes and Places

1. **Credentials → Create credentials → API key**.
2. Click the new key, then **API restrictions → Restrict key**. Tick only
   **Routes API** and **Places API (New)**, then save.
3. Copy the key. You will paste it into the app's **Settings** screen, which
   stores it in the phone's or Mac's secure storage. Do not put it in the code
   or in chat.

## What to send back

When you finish, tell me it's done and paste **only** these (they are not secret):

- The macOS **Client ID** and **iOS URL scheme**

Keep the API key to yourself and enter it in the app's Settings.
