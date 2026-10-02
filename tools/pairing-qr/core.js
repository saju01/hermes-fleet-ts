/* Fleet direct QR v2 validation. No credentials are retained by this module. */
(function(root) {
  'use strict';
  function invalid() { throw new Error('Invalid pairing details.'); }
  function keys(value, expected) {
    if (!value || typeof value !== 'object' || Array.isArray(value) ||
        Object.keys(value).sort().join(',') !== expected.slice().sort().join(',')) invalid();
  }
  function text(value, max) {
    if (typeof value !== 'string' || !value.trim() || value.length > max ||
        /[\u0000-\u001f\u007f]/u.test(value)) invalid();
    try { encodeURIComponent(value); } catch (_) { invalid(); }
    return value;
  }
  function origin(value) {
    text(value, 2048);
    // Reject lossy URL-parser repairs, userinfo, paths, empty query/fragment,
    // encoded host labels, non-ASCII hosts and ambiguous leading-zero ports.
    const match = /^https:\/\/([a-z0-9.-]+)(?::([1-9][0-9]{0,4}))?\/?$/i.exec(value);
    if (!match || match[1].length > 253 || !match[1].toLowerCase().endsWith('.ts.net') ||
        match[1].split('.').some(label => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label)) ||
        (match[2] && Number(match[2]) > 65535)) invalid();
    return new URL(value).origin;
  }
  function validatePayload(payload) {
    keys(payload, ['v','kind','url','name','transport','auth']);
    if (payload.v !== 2 || payload.kind !== 'hermes-fleet-ts' || payload.transport !== 'embeddedTailscale') invalid();
    const auth = payload.auth;
    if (auth && auth.strategy === 'usernamePassword') {
      keys(auth, ['strategy','username','password']);
      text(auth.username, 256); text(auth.password, 1024);
      if (new TextEncoder().encode(auth.username).length > 256) invalid();
    } else if (auth && auth.strategy === 'sessionToken') {
      keys(auth, ['strategy','token']); text(auth.token, 1024);
      if (auth.token.startsWith('tskey-') || /[\s\p{White_Space}]/u.test(auth.token)) invalid();
    } else invalid();
    const result = {v:2, kind:'hermes-fleet-ts', url:origin(payload.url), name:text(payload.name,128),
      transport:'embeddedTailscale', auth:{...auth}};
    if (new TextEncoder().encode(result.name).length > 128 ||
        new TextEncoder().encode(JSON.stringify(result)).length > 2048) invalid();
    return result;
  }
  const api = {validatePayload};
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.FleetPairing = Object.freeze(api);
})(globalThis);
