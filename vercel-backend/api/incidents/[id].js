const { ObjectId } = require("mongodb");
const { getDb, requireApiKey } = require("../../lib/mongodb");

module.exports = async function handler(req, res) {
  if (!requireApiKey(req, res)) return;
  const { id } = req.query;

  let objectId;
  try {
    objectId = new ObjectId(id);
  } catch {
    return res.status(400).json({ error: "Invalid id" });
  }

  if (req.method === "DELETE") {
    const db = await getDb();
    const result = await db.collection("incidents").deleteOne({ _id: objectId });
    if (result.deletedCount === 0) {
      return res.status(404).json({ error: "Not found" });
    }
    return res.status(204).end();
  }

  res.setHeader("Allow", "DELETE");
  return res.status(405).json({ error: "Method not allowed" });
};
