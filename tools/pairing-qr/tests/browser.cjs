/* Synthetic fixtures only. Screenshot bytes stay in memory; never test real credentials. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {execFileSync} = require('node:child_process');
const {chromium} = require('playwright-core');
const jsQR = require('jsqr');
const {PNG} = require('pngjs');
const root = path.resolve(__dirname,'../../..');
const output = process.env.FLEET_QR_TEST_DIR;
assert.ok(output, 'Set FLEET_QR_TEST_DIR to a task-owned scratch directory');
fs.mkdirSync(output,{recursive:true});
const home=fs.mkdtempSync(path.join(output,'fixture-home-'));
const endpoint=process.env.FLEET_QR_CDP || 'http://127.0.0.1:9222';
assert.match(endpoint,/^http:\/\/127\.0\.0\.1:\d+\/?$/);
const fixture={v:2,kind:'hermes-fleet-ts',url:'https://gateway.example.ts.net',name:'Fixture Hermes',transport:'embeddedTailscale',auth:{strategy:'usernamePassword',username:'fixture-user',password:'fixture-only-雪-😀'}};
let browser, context;
(async () => {
  try {
    const file=execFileSync('python3',[path.join(root,'scripts/fleet-pairing-qr'),'--prepare-only','--url',fixture.url,'--name',fixture.name,'--username',fixture.auth.username],{env:{...process.env,HOME:home},encoding:'utf8'}).trim();
    const before=fs.readFileSync(file);
    browser=await chromium.connectOverCDP(endpoint,{timeout:120000});
    context=await browser.newContext({offline:true,acceptDownloads:false,serviceWorkers:'block',viewport:{width:1100,height:1400}});
    const page=await context.newPage();
    const requests=[],errors=[],messages=[],failedRequests=[];
    page.on('requestfailed',r=>failedRequests.push({type:r.resourceType(),failure:r.failure()?.errorText}));
    page.on('request',r=>{if (!r.url().startsWith('file:')) requests.push(r.resourceType());});
    page.on('pageerror',()=>errors.push('pageerror'));
    page.on('console',m=>messages.push(m.text()));
    await page.goto(pathToFileURL(file).href);
    assert.equal(await page.locator('#password').count(),1,'private password form must exist');
    assert.equal(await page.locator('#password').getAttribute('type'),'password');
    // Evidence contains only the untouched form, never a credential or QR.
    await page.screenshot({path:path.join(output,'blank-form.png'),fullPage:true});
    await page.locator('#password').fill(fixture.auth.password);
    await page.locator('#ack').check();
    await page.locator('#generate').click();
    assert.equal(await page.locator('#qr').isVisible(),true,'a scannable QR must render');
    const pixels=PNG.sync.read(await page.locator('#qr').screenshot());
    const decoded=jsQR(new Uint8ClampedArray(pixels.data),pixels.width,pixels.height);
    assert.ok(decoded,'independent decoder must recognize actual screenshot');
    assert.ok(JSON.stringify(JSON.parse(decoded.data))===JSON.stringify(fixture),'decoded schema and credential must match fixture exactly');
    assert.equal(await page.locator('#password').inputValue(),'','input must be cleared after render');
    assert.equal(await page.locator('body').innerText().then(t=>t.includes(fixture.auth.password)),false);
    assert.deepEqual(fs.readFileSync(file),before,'runtime credential must not be written to HTML');
    assert.deepEqual(requests,[],'no non-file network requests');
    assert.deepEqual(errors,[],'no JavaScript errors');
    assert.equal(messages.some(x=>x.includes(fixture.auth.password)),false,'no credential console output');
    assert.deepEqual(messages,[],'no browser warnings or logs');
    console.log('PASS browser: offline username/password screenshot decoded exactly; no network/log/disk credential output');
    assert.equal(await page.locator('#strategy').count(),1,'existing session-token selector must exist');
    await page.locator('#strategy').selectOption('sessionToken');
    const tokenFixture={...fixture,auth:{strategy:'sessionToken',token:'fixture-session-only-雪-😀'}};
    assert.equal(await page.locator('#token').getAttribute('type'),'password');
    await page.locator('#token').fill(tokenFixture.auth.token);
    await page.locator('#generate').click();
    const tokenPixels=PNG.sync.read(await page.locator('#qr').screenshot());
    const tokenDecoded=jsQR(new Uint8ClampedArray(tokenPixels.data),tokenPixels.width,tokenPixels.height);
    assert.ok(tokenDecoded,'session token screenshot must decode');
    assert.ok(JSON.stringify(JSON.parse(tokenDecoded.data))===JSON.stringify(tokenFixture),'session-token payload must match exactly without mixed credentials');
    assert.equal(await page.locator('#token').inputValue(),'');
    assert.deepEqual(requests,[]); assert.deepEqual(errors,[]); assert.deepEqual(messages,[]);
    assert.deepEqual(fs.readFileSync(file),before);
    console.log('PASS browser: offline existing session-token screenshot decoded exactly');
    assert.equal(await page.locator('#clear').count(),1,'explicit clear control must exist');
    await page.locator('#clear').click();
    async function assertCleared() {
      assert.equal(await page.locator('#qr').isVisible(),false,'QR must be hidden');
      assert.equal(await page.locator('#qr').evaluate(c=>c.width),0,'canvas pixels must be discarded');
      for (const id of ['url','name','username','password','token']) assert.equal(await page.locator('#'+id).inputValue(),'','clear must discard all form values');
      assert.equal(await page.locator('#ack').isChecked(),false);
    }
    async function renderAgain() {
      await page.locator('#url').fill(fixture.url); await page.locator('#name').fill(fixture.name);
      await page.locator('#strategy').selectOption('usernamePassword');
      await page.locator('#username').fill(fixture.auth.username); await page.locator('#password').fill(fixture.auth.password);
      await page.locator('#ack').check(); await page.locator('#generate').click();
      assert.equal(await page.locator('#qr').isVisible(),true);
    }
    await assertCleared();
    await renderAgain(); await page.locator('#url').fill('https://other.example.ts.net');
    assert.equal(await page.locator('#qr').isVisible(),false,'editing target must invalidate old QR');
    await renderAgain(); await page.evaluate(()=>window.dispatchEvent(new PageTransitionEvent('pagehide'))); await assertCleared();
    await renderAgain(); await page.evaluate(()=>{Object.defineProperty(document,'hidden',{configurable:true,value:true}); document.dispatchEvent(new Event('visibilitychange'));}); await assertCleared();
    await page.evaluate(()=>{delete document.hidden;});
    await renderAgain(); await page.goto('about:blank'); await page.goBack(); await assertCleared();
    await renderAgain(); await page.locator('#url').fill('https://gateway.example.ts.net?forbidden');
    await page.locator('#password').fill(fixture.auth.password); await page.locator('#generate').click();
    assert.equal(await page.locator('#qr').isVisible(),false,'invalid target must never render');
    assert.equal(await page.locator('#password').inputValue(),'','failure must clear credentials');
    assert.equal(await page.locator('#status').innerText().then(t=>t.includes(fixture.auth.password)),false);
    await page.locator('#clear').click();
    assert.deepEqual(requests,[]); assert.deepEqual(errors,[]); assert.deepEqual(messages,[]);
    console.log('PASS browser: clear, target edits, pagehide, hidden tab, navigation/back and validation failure discard sensitive state');
    await renderAgain(); await page.evaluate(()=>{location.hash='test-only';});
    assert.equal(await page.locator('#generate').isDisabled(),true,'same-document fragment navigation must disable rendering');
    await assertCleared();
    for (const suffix of ['?test-only=1','#test-only','?','#']) {
      await page.goto(pathToFileURL(file).href+suffix);
      assert.equal(await page.locator('#generate').isDisabled(),true,'only an unadorned local file may render');
      assert.equal(await page.locator('#password').isDisabled(),true,'unsafe context must refuse credential entry');
    }
    const remotePage=await context.newPage();
    await remotePage.route('https://fixture.invalid/',route=>route.fulfill({body:before,contentType:'text/html'}));
    await remotePage.goto('https://fixture.invalid/');
    assert.equal(await remotePage.locator('#generate').isDisabled(),true,'HTTP-hosted copies must refuse rendering');
    await remotePage.close();
    await page.goto(pathToFileURL(file).href);
    await page.evaluate(() => {
      window.testViolations=[];
      document.addEventListener('securitypolicyviolation', e=>window.testViolations.push(e.effectiveDirective));
      const injected=document.createElement('script'); injected.textContent='window.injectedRan=true'; document.body.append(injected);
      const foreign=document.createElement('script'); foreign.src='https://blocked.invalid/test.js'; document.body.append(foreign);
      fetch('https://blocked.invalid/test').catch(()=>{});
      const form=document.createElement('form'); form.action='https://blocked.invalid/submit'; form.method='post'; document.body.append(form); form.submit();
    });
    await page.waitForFunction(()=>window.testViolations.includes('connect-src') && window.testViolations.includes('form-action') && window.testViolations.includes('script-src-elem'));
    assert.equal(await page.evaluate(()=>window.injectedRan===true),false,'unhashed inline script must be blocked');
    assert.equal(page.url(),pathToFileURL(file).href,'outgoing form must not navigate');
    // Chromium reports the attempted script as a request event, then fails it
    // with reason `csp` before network I/O (not ERR_INTERNET_DISCONNECTED).
    assert.deepEqual(requests,['script']);
    assert.deepEqual(failedRequests,[{type:'script',failure:'csp'}]);
    assert.deepEqual(errors,[]);
    console.log('PASS browser: file-only guard and enforced CSP block inline/remote scripts, connections and form submission');
  } finally {
    if(context) await context.close();
    if(browser) await browser.close(); // Disconnect CDP client, not the existing Chrome process.
    fs.rmSync(home,{recursive:true,force:true});
  }
})().catch(error => { console.error('FAIL browser: '+error.message.split('\n')[0]); process.exitCode=1; });
