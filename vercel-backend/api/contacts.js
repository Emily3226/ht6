const { getDb, requireApiKey } = require("../lib/mongodb");

module.exports = async function handler(req, res) {
  if (!requireApiKey(req, res)) return;
  const db = await getDb();
  const collection = db.collection("contacts");

  if (req.method === "GET") {
    const contacts = await collection.find({}).toArray();
    return res.status(200).json(contacts);
  }

  if (req.method === "POST") {
    // Full-list sync: the Swift app's local UserDefaults list is the source
    // of truth during editing, and pushes its whole contacts array here
    // after each add/edit/remove. Simplest correct approach for a
    // single-device app -- replace the collection wholesale rather than
    // diffing, so there's no drift between local ids and Mongo ids.
    const { contacts } = req.body || {};
    if (!Array.isArray(contacts)) {
      return res.status(400).json({ error: "contacts array is required" });
    }
    await collection.deleteMany({});
    if (contacts.length > 0) {
      await collection.insertMany(
        contacts.map((c) => ({
          clientId: c.id, // the Swift-side UUID, kept for reference
          name: c.name,
          phoneNumber: c.phoneNumber,
          carrier: c.carrier,
          priority: c.priority,
        }))
      );
    }
    return res.status(200).json({ ok: true, count: contacts.length });
  }

  res.setHeader("Allow", "GET, POST");
  return res.status(405).json({ error: "Method not allowed" });
};
