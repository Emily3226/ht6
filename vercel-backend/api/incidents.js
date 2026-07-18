const { getDb, requireApiKey } = require("../lib/mongodb");

module.exports = async function handler(req, res) {
  if (!requireApiKey(req, res)) return;
  const db = await getDb();
  const collection = db.collection("incidents");

  if (req.method === "GET") {
    const incidents = await collection.find({}).sort({ date: -1 }).limit(200).toArray();
    return res.status(200).json(incidents);
  }

  if (req.method === "POST") {
    const { hazardType, direction, urgency, latitude, longitude } = req.body || {};
    if (!hazardType || !direction || !urgency) {
      return res.status(400).json({ error: "hazardType, direction, and urgency are required" });
    }
    const doc = {
      hazardType,
      direction,
      urgency,
      latitude: typeof latitude === "number" ? latitude : null,
      longitude: typeof longitude === "number" ? longitude : null,
      date: new Date(),
    };
    const result = await collection.insertOne(doc);
    return res.status(201).json({ ...doc, _id: result.insertedId });
  }

  res.setHeader("Allow", "GET, POST");
  return res.status(405).json({ error: "Method not allowed" });
};
