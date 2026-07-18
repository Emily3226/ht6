const { MongoClient } = require('mongodb');

let _client = null;

async function getCollection(database, collection) {
    if (!_client) {
        _client = new MongoClient(process.env.MONGODB_URI);
        await _client.connect();
    }
    return _client.db(database).collection(collection);
}

module.exports = async (req, res) => {
    if (req.method !== 'POST') {
        return res.status(405).json({ error: 'Method not allowed' });
    }

    const apiKey = req.headers['api-key'];
    if (!apiKey || apiKey !== process.env.API_KEY) {
        return res.status(401).json({ error: 'Unauthorized' });
    }

    const action = req.query.action;
    const { database, collection, ...rest } = req.body;

    if (!database || !collection) {
        return res.status(400).json({ error: 'database and collection are required' });
    }

    try {
        const col = await getCollection(database, collection);

        switch (action) {
            case 'insertOne': {
                const result = await col.insertOne(rest.document);
                return res.json({ insertedId: result.insertedId.toString() });
            }
            case 'insertMany': {
                if (!rest.documents || rest.documents.length === 0) {
                    return res.json({ insertedIds: [] });
                }
                const result = await col.insertMany(rest.documents);
                return res.json({
                    insertedIds: Object.values(result.insertedIds).map(id => id.toString())
                });
            }
            case 'find': {
                let cursor = col.find(rest.filter || {});
                if (rest.sort) cursor = cursor.sort(rest.sort);
                const documents = await cursor.toArray();
                return res.json({ documents });
            }
            case 'replaceOne': {
                const result = await col.replaceOne(
                    rest.filter,
                    rest.replacement,
                    { upsert: rest.upsert ?? false }
                );
                return res.json({
                    matchedCount: result.matchedCount,
                    modifiedCount: result.modifiedCount,
                    upsertedId: result.upsertedId?.toString() ?? null
                });
            }
            case 'deleteOne': {
                const result = await col.deleteOne(rest.filter);
                return res.json({ deletedCount: result.deletedCount });
            }
            case 'deleteMany': {
                const result = await col.deleteMany(rest.filter);
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
