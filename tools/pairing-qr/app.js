/* Credentials exist only in transient form/QR memory, never in the file. */
(function() {
  'use strict';
  const byId = id => document.getElementById(id);
  const canvas = byId('qr');
  function hideQR() {
    canvas.hidden = true; canvas.width = canvas.height = 0;
    byId('status').textContent = '';
  }
  function clearAll() {
    hideQR();
    for (const id of ['url','name','username','password','token']) byId(id).value = '';
    byId('ack').checked = false;
  }
  function privateContext() {
    return location.protocol === 'file:' && !/[?#]/.test(location.href) && window.top === window.self;
  }
  function disableUnsafeContext() {
    clearAll();
    for (const control of byId('pairing').elements) control.disabled = true;
    byId('status').textContent = 'Open the private local file using the Fleet launcher, without a query or fragment.';
  }
  if (!privateContext()) { disableUnsafeContext(); return; }
  window.addEventListener('hashchange', disableUnsafeContext);
  byId('clear').addEventListener('click', clearAll);
  byId('pairing').addEventListener('input', hideQR);
  window.addEventListener('pagehide', clearAll);
  window.addEventListener('beforeunload', clearAll);
  hideQR();
  window.addEventListener('pageshow', event => {
    if (event.persisted || performance.getEntriesByType('navigation')[0]?.type === 'back_forward') clearAll();
    byId('password').value = byId('token').value = '';
  });
  document.addEventListener('visibilitychange', () => { if (document.hidden) clearAll(); });
  byId('strategy').addEventListener('change', () => {
    const token = byId('strategy').value === 'sessionToken';
    byId('token-fields').hidden = !token;
    byId('password-fields').hidden = token;
    byId('password').value = byId('token').value = '';
    canvas.hidden = true; canvas.width = canvas.height = 0;
    byId('status').textContent = '';
  });
  byId('pairing').addEventListener('submit', event => event.preventDefault());
  byId('generate').addEventListener('click', () => {
    canvas.hidden = true;
    canvas.width = canvas.height = 0;
    byId('status').textContent = '';
    try {
      if (!privateContext() || !byId('ack').checked) throw new Error();
      const payload = FleetPairing.validatePayload({v:2, kind:'hermes-fleet-ts',
        url:byId('url').value, name:byId('name').value, transport:'embeddedTailscale',
        auth:byId('strategy').value === 'sessionToken'
          ? {strategy:'sessionToken',token:byId('token').value}
          : {strategy:'usernamePassword',username:byId('username').value,password:byId('password').value}});
      const code = qrcode(0, 'M');
      code.addData(JSON.stringify(payload), 'Byte');
      code.make();
      const size = code.getModuleCount(), scale = 6, border = 4;
      canvas.width = canvas.height = (size + border * 2) * scale;
      const context = canvas.getContext('2d');
      context.fillStyle = '#fff'; context.fillRect(0,0,canvas.width,canvas.height);
      context.fillStyle = '#000';
      for (let row=0; row<size; row++) for (let col=0; col<size; col++) {
        if (code.isDark(row,col)) context.fillRect((col+border)*scale,(row+border)*scale,scale,scale);
      }
      canvas.hidden = false;
      byId('status').textContent = 'Scan privately in Fleet. This QR is reusable.';
    } catch (_) {
      canvas.width = canvas.height = 0;
      byId('status').textContent = 'Could not display QR. Check the origin, fields, length limits and acknowledgement.';
    } finally {
      byId('password').value = byId('token').value = '';
    }
  });
})();
