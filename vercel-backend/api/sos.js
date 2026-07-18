const { Resend } = require("resend");
const { getDb, requireApiKey } = require("../lib/mongodb");

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).json({ error: "Method not allowed" });
  }
  if (!requireApiKey(req, res)) return;

  const { contacts, latitude, longitude, hazardType, direction, urgency } = req.body || {};

  if (!Array.isArray(contacts) || contacts.length === 0) {
    return res.status(400).json({ error: "contacts array is required" });
  }
  if (typeof latitude !== "number" || typeof longitude !== "number") {
    return res.status(400).json({ error: "latitude and longitude are required" });
  }

  const resendApiKey = process.env.RESEND_API_KEY;
  const fromEmail = process.env.RESEND_FROM_EMAIL;
  if (!resendApiKey || !fromEmail) {
    return res.status(500).json({ error: "RESEND_API_KEY / RESEND_FROM_EMAIL not set on the server." });
  }

  const resend = new Resend(resendApiKey);
  const locationLink = `https://maps.apple.com/?ll=${latitude},${longitude}`;
  const message = `I need help. My location: ${locationLink}`;

  // contacts[i].smsGatewayAddress is computed client-side the same way
  // SOSManager.swift already does it (e.g. "6135551234@txt.bell.ca").
  const results = await Promise.allSettled(
    contacts.map((address) =>
      resend.emails.send({
        from: fromEmail,
        to: [address],
        subject: "SOS",
        text: message,
      })
    )
  );

  const failures = results
    .map((r, i) => (r.status === "rejected" ? { address: contacts[i], error: String(r.reason) } : null))
    .filter(Boolean);

  // Log the incident to Mongo regardless of partial email failures, so
  // History reflects that an SOS was triggered even if a gateway hiccuped.
  let incidentId = null;
  try {
    const db = await getDb();
    const doc = {
      hazardType: hazardType || "manual_sos",
      direction: direction || "-",
      urgency: urgency || "high",
      latitude,
      longitude,
      date: new Date(),
      alertedContacts: contacts.length,
      alertFailures: failures.length,
    };
    const result = await db.collection("incidents").insertOne(doc);
    incidentId = result.insertedId;
  } catch (err) {
    console.error("Failed to log SOS incident to Mongo:", err);
    // Don't fail the whole request over this -- the alert itself matters more.
  }

  if (failures.length === contacts.length) {
    return res.status(502).json({ error: "All SOS alerts failed to send", failures, incidentId });
  }

  return res.status(200).json({
    ok: true,
    sent: contacts.length - failures.length,
    failed: failures.length,
    failures,
    incidentId,
  });
};
