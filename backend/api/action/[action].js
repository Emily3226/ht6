// /api/action/<name> is the same handler as /api/db — Vercel's file-based
// routing fills req.query.action from the path segment.
module.exports = require('../db.js');
