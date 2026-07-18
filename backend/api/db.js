const { MongoClient } = require('mongodb');

let _client = null;
let _jwks = null;
let _indexesEnsured = false;

// Auth0 tenant used to verify Bearer tokens. Overridable via env, but the
// defaults match the app's Auth0.plist so a fresh deploy works with zero
// Vercel env configuration.
const AUTH0_DOMAIN = process.env.AUTH0_DOMAIN || 'dev-oujycjwa44qo68ll.ca.auth0.com';
const AUTH0_CLIENT_ID = process.env.AUTH0_CLIENT_ID || 'u3kpBUoxH3rr9WSnLkK61PBWh0iROW0a';

async function getCollection(database, collection) {
    if (!_client) {
        _client = new MongoClient(process.env.MONGODB_URI);
        await _client.connect();
    }
    const col = _client.db(database).collection(collection);
    // Index setup is idempotent; kick it off once per cold start so the
    // incidents collection supports fast per-user history reads and
    // $geoNear ("you've been here before") queries.
    if (!_indexesEnsured && collection === 'incidents') {
        _indexesEnsured = true;
        col.createIndex({ userId: 1, date: -1 }).catch(() => {});
        col.createIndex({ location: '2dsphere' }).catch(() => {});
    }
    return col;
}

/// Verifies an Auth0-issued ID token (RS256) against the tenant's JWKS and
/// returns the token's subject (the Auth0 user id).
async function verifyAuth0Token(token) {
    const { createRemoteJWKSet, jwtVerify } = await import('jose');
    if (!_jwks) {
        _jwks = createRemoteJWKSet(
            new URL(`https://${AUTH0_DOMAIN}/.well-known/jwks.json`)
        );
    }
    const { payload } = await jwtVerify(token, _jwks, {
        issuer: `https://${AUTH0_DOMAIN}/`,
        audience: AUTH0_CLIENT_ID,
    });
    return payload.sub;
}

// When a request is authenticated with an Auth0 token, the userId in every
// filter/document is forced to the token's subject server-side — a client
// can never read or write another user's data, regardless of what it sends.
function scopeFilter(filter, uid) {
    const f = filter || {};
    return uid ? { ...f, userId: uid } : f;
}

function scopeDoc(doc, uid) {
    return uid ? { ...doc, userId: uid } : doc;
}

function scopePipeline(pipeline, uid) {
    if (!uid) return pipeline;
    const [first, ...rest] = pipeline;
    // $geoNear must stay the first stage, so scope its query instead of
    // prepending a $match.
    if (first && first.$geoNear) {
        return [
            { $geoNear: { ...first.$geoNear, query: scopeFilter(first.$geoNear.query, uid) } },
            ...rest,
        ];
    }
    return [{ $match: { userId: uid } }, ...pipeline];
}

module.exports = async (req, res) => {
    if (req.method !== 'POST') {
        return res.status(405).json({ error: 'Method not allowed' });
    }

    // Preferred auth: an Auth0 Bearer token, verified against the tenant's
    // JWKS. Fallback: the shared api-key header (used before login and by
    // curl/testing).
    let authedUserId = null;
    const authHeader = req.headers['authorization'];
    if (authHeader && authHeader.startsWith('Bearer ')) {
        try {
            authedUserId = await verifyAuth0Token(authHeader.slice(7));
        } catch (err) {
            return res.status(401).json({ error: `Invalid Auth0 token: ${err.message}` });
        }
    } else {
        const apiKey = req.headers['api-key'];
        if (!apiKey || apiKey !== process.env.API_KEY) {
            return res.status(401).json({ error: 'Unauthorized' });
        }
    }

    // Accept the action from the query string or the request body, so both
    // /api/db?action=find and a body {"action": "find"} work.
    const { database, collection, action: bodyAction, dataSource, ...rest } = req.body;
    const action = req.query.action || bodyAction;

    if (!database || !collection) {
        return res.status(400).json({ error: 'database and collection are required' });
    }

    try {
        const col = await getCollection(database, collection);

        switch (action) {
            case 'insertOne': {
                const result = await col.insertOne(scopeDoc(rest.document, authedUserId));
                return res.json({ insertedId: result.insertedId.toString() });
            }
            case 'insertMany': {
                if (!rest.documents || rest.documents.length === 0) {
                    return res.json({ insertedIds: [] });
                }
                const docs = rest.documents.map(d => scopeDoc(d, authedUserId));
                const result = await col.insertMany(docs);
                return res.json({
                    insertedIds: Object.values(result.insertedIds).map(id => id.toString())
                });
            }
            case 'find': {
                let cursor = col.find(scopeFilter(rest.filter, authedUserId));
                if (rest.sort) cursor = cursor.sort(rest.sort);
                const documents = await cursor.toArray();
                return res.json({ documents });
            }
            case 'aggregate': {
                const pipeline = scopePipeline(rest.pipeline || [], authedUserId);
                const documents = await col.aggregate(pipeline).toArray();
                return res.json({ documents });
            }
            case 'replaceOne': {
                const result = await col.replaceOne(
                    scopeFilter(rest.filter, authedUserId),
                    scopeDoc(rest.replacement, authedUserId),
                    { upsert: rest.upsert ?? false }
                );
                return res.json({
                    matchedCount: result.matchedCount,
                    modifiedCount: result.modifiedCount,
                    upsertedId: result.upsertedId?.toString() ?? null
                });
            }
            case 'deleteOne': {
                const result = await col.deleteOne(scopeFilter(rest.filter, authedUserId));
                return res.json({ deletedCount: result.deletedCount });
            }
            case 'deleteMany': {
                const result = await col.deleteMany(scopeFilter(rest.filter, authedUserId));
                return res.json({ deletedCount: result.deletedCount });
            }
            default:
                return res.status(400).json({ error: `Unknown action: ${action}` });
        }
    } catch (err) {
        console.error('[caneos-backend]', err);
        return res.status(500).json({ error: err.message });
    }
};
