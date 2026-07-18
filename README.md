# CaneOS

A 3D-printed, clip-on module for a white cane that detects the obstacles
standard canes miss — overhanging branches, chest-height barriers, sudden
drop-offs — and turns them into directional haptics, spoken narration, and
automatic SOS alerts.

**Pipeline:** ToF sensor → camera frame → Gemini vision (structured hazard
JSON) → iOS app → ElevenLabs narration over Bluetooth + Apple Watch haptics,
with high-urgency hazards firing the SOS path (geolocation + SMS/email to
emergency contacts) in parallel.

## MongoDB Atlas integration

All structured data lives in an Atlas cluster (`cane_os` database), reached
through a thin serverless proxy (`backend/api/db.js`, deployed on Vercel at
`caneos-api.vercel.app`) that runs the official MongoDB Node driver —
MongoDB sunset the hosted Atlas Data API, so this proxy is our replacement.

- **Collections:** `incidents` (timestamped hazard log with GeoJSON
  locations), `contacts` (emergency contacts), `settings` (user preferences)
  — all synced live from the app and scoped per user.
- **Aggregation pipelines:** the History tab's Insights card is computed
  server-side by a `$facet` pipeline (totals, urgency breakdown, top hazard
  types) — not by scanning documents in the app.
- **Geospatial queries:** incident locations are stored as GeoJSON points
  under a `2dsphere` index; when a hazard is logged, a `$geoNear` query
  checks whether the user has hit the same hazard type within ~40 m before
  and, if so, the app speaks a "you've encountered this here before"
  callback.
- **Indexes** (`{userId, date}` + `2dsphere`) are ensured automatically by
  the backend.

## Auth0 integration

Auth0 is the app's identity layer *and* its API security layer:

- **Universal Login** (Auth0.swift SDK) with profile (name, email, avatar)
  shown in Settings.
- **Session persistence & silent renewal** via Auth0's `CredentialsManager`
  with refresh tokens (`offline_access` scope).
- **Token-secured data plane:** every request the app makes to the MongoDB
  proxy carries the user's Auth0-issued ID token. The backend verifies the
  RS256 signature against the tenant's JWKS (`jose`), checks issuer and
  audience, and then forces the `userId` on every query and document to the
  *verified* token subject — a client can never read or write another
  user's data, regardless of what it sends.
- **Cross-device sync:** because identity comes from Auth0, signing in on a
  new phone pulls your contacts, settings, and incident history from Atlas.

## Repo layout

- `CaneOS App/` — iOS + watchOS app (SwiftUI)
- `backend/api/` — Vercel serverless MongoDB proxy (Auth0-JWT-verified)
- `backend/pipeline/` — Python hazard pipeline (ToF/camera → Gemini →
  WebSocket), see `backend/README.md`
