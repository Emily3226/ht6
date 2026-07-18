# CaneOS Vercel backend

Thin serverless proxy in front of MongoDB and Resend. The Swift app calls
these endpoints instead of talking to Mongo or Resend directly, so those
credentials live only in Vercel's environment, never in the app bundle.

```
Swift app --> Vercel functions (/api/sos, /api/incidents, /api/contacts) --> MongoDB Atlas
                                                                          --> Resend
```

## Endpoints

| Method | Path                  | Does |
|--------|-----------------------|------|
| POST   | `/api/sos`             | Emails each contact's carrier gateway (SMS) via Resend, logs the incident to Mongo |
| GET    | `/api/incidents`       | List up to 200 most recent incidents |
| POST   | `/api/incidents`       | Log an incident |
| DELETE | `/api/incidents/:id`   | Remove one incident |
| GET    | `/api/contacts`        | List emergency contacts |
| POST   | `/api/contacts`        | Replace the full contacts list (full-sync from the app) |

Every request needs an `X-Api-Key` header matching `APP_API_KEY` (see below).

## 1. Get a MongoDB Atlas connection string

1. Go to https://cloud.mongodb.com and sign in (or create a free account).
2. Create a free-tier (M0) cluster if you don't have one.
3. **Database Access** (left sidebar) -> add a database user with a password. Save that password.
4. **Network Access** (left sidebar) -> Add IP Address -> "Allow access from anywhere" (`0.0.0.0/0`).
   Vercel functions run on rotating IPs, so you can't whitelist a fixed one.
5. Back on the cluster page, click **Connect** -> **Drivers** -> copy the connection string.
   It looks like:
   ```
   mongodb+srv://<username>:<password>@cluster0.xxxxx.mongodb.net/?retryWrites=true&w=majority
   ```
6. Replace `<username>`/`<password>` with what you created in step 3, and add
   a database name before the `?`, e.g. `.../caneos?retryWrites=...`.
   This full string is your `MONGODB_URI`.

## 2. Get a Resend API key

You may already have this from the current Resend-direct setup — same key works here.

1. https://resend.com -> sign in -> **API Keys** -> Create API Key. This is `RESEND_API_KEY`.
2. **Domains** -> verify a domain you own (Resend won't send from an unverified domain).
   The address you send from (e.g. `alerts@yourdomain.com`) is `RESEND_FROM_EMAIL`.

## 3. Make up an APP_API_KEY

This isn't from any provider — it's a shared secret you invent yourself, e.g.:
```bash
openssl rand -hex 32
```
This is what authenticates the Swift app to *your* Vercel endpoints. It goes in Vercel's env
vars, and the same value goes in the app's `Config.swift` as `backendAPIKey`.

## 4. Deploy to Vercel

1. Install the CLI if you don't have it: `npm i -g vercel`
2. From this `vercel-backend/` folder: `vercel` (first time links/creates the project), then `vercel --prod` to deploy.
   Or connect the repo at https://vercel.com/new and set the **root directory** to `vercel-backend`.
3. In the Vercel dashboard: your project -> **Settings** -> **Environment Variables**, add:
   - `MONGODB_URI`
   - `MONGODB_DB_NAME` (optional, defaults to `caneos`)
   - `RESEND_API_KEY`
   - `RESEND_FROM_EMAIL`
   - `APP_API_KEY`
4. Redeploy after adding env vars (Vercel only picks them up on a new deployment).
5. Note the deployment URL, e.g. `https://caneos-backend.vercel.app` — you'll need it in `Config.swift`.

## 5. Local testing (optional)

```bash
cd vercel-backend
npm install
cp .env.example .env   # fill in the real values
vercel dev
```

Test with curl:
```bash
curl -X GET https://<your-deployment>.vercel.app/api/incidents \
  -H "X-Api-Key: <your APP_API_KEY>"
```

## 6. Swift-side config

Add to `Config.swift` (gitignored, not in this repo):
```swift
static let backendAPIBaseURL = "https://<your-deployment>.vercel.app"
static let backendAPIKey = "<same value as APP_API_KEY in Vercel>"
```
You can now remove `resendAPIKey` / `resendFromEmail` from `Config.swift` —
`SOSManager` no longer calls Resend directly.
