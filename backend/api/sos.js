const { MongoClient } = require('mongodb');

// Sends the SOS messages server-side via Resend (email → each contact's
// carrier SMS gateway address, e.g. 6135551234@txt.bell.ca) and logs the
// event to Atlas. The Resend key lives in Vercel env vars (RESEND_API_KEY,
// RESEND_FROM_EMAIL) so it never ships in the app.
//
// IMPORTANT: Resend can only send from a VERIFIED DOMAIN. Until the team
// verifies one (Resend dashboard → Domains → add DNS records), the only
// allowed from-address is onboarding@resend.dev, which Resend restricts to
// delivering ONLY to the Resend account owner's own email — carrier
// gateways will be rejected. Once a domain is verified, set
// RESEND_FROM_EMAIL=sos@<that-domain> and everything below just works.
// Failures are returned per-recipient so the app can say exactly why a
// contact didn't get the text — no more silent SOS failures.

let _client = null;

async function getDb() {
    if (!_client) {
        _client = new MongoClient(process.env.MONGODB_URI);
        await _client.connect();
    }
    return _client.db('cane_os');
}

async function sendViaResend(to, subject, text) {
    const key = process.env.RESEND_API_KEY;
    const from = process.env.RESEND_FROM_EMAIL || 'onboarding@resend.dev';
    if (!key) throw new Error('RESEND_API_KEY not configured on the server');

    const resp = await fetch('https://api.resend.com/emails', {
        method: 'POST',
        headers: {
            Authorization: `Bearer ${key}`,
            'Content-Type': 'application/json',
        },
        // Carrier SMS gateways generally render the plain-text body (and
        // often strip the subject), so keep the body minimal.
        body: JSON.stringify({ from, to: [to], subject, text }),
    });
    const json = await resp.json();
    if (!resp.ok) {
        throw new Error(json.message || `Resend error ${resp.status}`);
    }
    return json.id;
}

module.exports = async (req, res) => {
    if (req.method !== 'POST') {
        return res.status(405).json({ error: 'Method not allowed' });
    }

    const apiKey = req.headers['x-api-key'] || req.headers['api-key'] || req.headers['apikey'];
    if (!apiKey || apiKey !== process.env.API_KEY) {
        return res.status(401).json({ error: 'Unauthorized' });
    }

    const { contacts, latitude, longitude, hazardType, direction, urgency } = req.body;
    if (!Array.isArray(contacts) || contacts.length === 0) {
        return res.status(400).json({ error: 'contacts (gateway addresses) is required' });
    }

    const link = `https://maps.apple.com/?ll=${latitude},${longitude}`;
    const hazardNote = hazardType && hazardType !== 'manual_sos'
        ? ` Detected hazard: ${String(hazardType).replace(/_/g, ' ')} (${urgency || 'high'} urgency).`
        : '';
    const text = `CaneOS SOS — I need help.${hazardNote} My location: ${link}`;

    // Until a verified domain exists, Resend only delivers to the account
    // owner's inbox — so always CC the fallback address (SOS_FALLBACK_EMAIL)
    // alongside the carrier gateways. That guarantees at least one real,
    // immediately-visible message per SOS; the gateway sends start working
    // automatically once a domain is verified, with no code change.
    const fallback = process.env.SOS_FALLBACK_EMAIL;
    const recipients = [...contacts];
    if (fallback && !recipients.includes(fallback)) recipients.push(fallback);

    const results = await Promise.allSettled(
        recipients.map(address => sendViaResend(address, 'SOS', text))
    );
    const failures = results
        .map((result, i) => ({ result, to: recipients[i] }))
        .filter(({ result }) => result.status === 'rejected')
        .map(({ result, to }) => ({ to, error: result.reason.message }));
    const sent = recipients.length - failures.length;

    // Best-effort event log — delivery outcome above is what matters.
    try {
        const db = await getDb();
        await db.collection('sos_events').insertOne({
            contacts, latitude, longitude,
            hazardType: hazardType ?? 'manual_sos',
            direction: direction ?? '-',
            urgency: urgency ?? 'high',
            sent, failures,
            createdAt: new Date(),
        });
    } catch (err) {
        console.error('[caneos-sos] log failed:', err.message);
    }

    if (sent === 0) {
        return res.status(502).json({
            error: `No SOS messages could be sent. ${failures.map(f => `${f.to}: ${f.error}`).join(' | ')}`,
            failures,
        });
    }
    return res.json({ sent, failures });
};
