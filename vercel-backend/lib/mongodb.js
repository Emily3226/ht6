const { MongoClient } = require("mongodb");

// Vercel serverless functions can reuse a warm container between
// invocations, so we cache the client/connection on `global` instead of
// reconnecting on every request (opening a fresh TLS connection to Atlas
// on every single API call would be slow and would burn through Atlas's
// connection limit fast).
let cachedClient = global._mongoClient;
let cachedDb = global._mongoDb;

async function getDb() {
  if (cachedDb) return cachedDb;

  const uri = process.env.MONGODB_URI;
  if (!uri) {
    throw new Error("MONGODB_URI is not set in this Vercel project's environment variables.");
  }

  if (!cachedClient) {
    cachedClient = new MongoClient(uri);
    global._mongoClient = cachedClient;
  }
  await cachedClient.connect();

  // Database name comes from the URI path (e.g. .../caneos?retryWrites=...).
  // Falls back to "caneos" if the URI doesn't specify one.
  cachedDb = cachedClient.db(process.env.MONGODB_DB_NAME || "caneos");
  global._mongoDb = cachedDb;
  return cachedDb;
}

// Simple shared-secret check. The app is single-user / no login system, so
// this isn't per-user auth -- it just stops randoms on the internet from
// reading/writing your Mongo data through these endpoints. Set APP_API_KEY
// in Vercel and pass the same value as the "X-Api-Key" header from Swift.
function requireApiKey(req, res) {
  const expected = process.env.APP_API_KEY;
  if (!expected) {
    // Fail closed: if you forgot to set it, refuse instead of running open.
    res.status(500).json({ error: "APP_API_KEY is not set on the server." });
    return false;
  }
  const provided = req.headers["x-api-key"];
  if (provided !== expected) {
    res.status(401).json({ error: "Unauthorized" });
    return false;
  }
  return true;
}

module.exports = { getDb, requireApiKey };
