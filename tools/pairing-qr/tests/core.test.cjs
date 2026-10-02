'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const corePath = path.join(__dirname, '../core.js');
const fixture = () => ({v:2, kind:'hermes-fleet-ts', url:'https://gateway.example.ts.net', name:'Fixture Hermes', transport:'embeddedTailscale', auth:{strategy:'usernamePassword', username:'fixture-user', password:'fixture-only-not-a-credential'}});
test('v2 username/password payload keeps existing credentials and embedded transport', () => {
  assert.ok(fs.existsSync(corePath), 'direct QR validator must exist');
  const {validatePayload} = require(corePath);
  assert.deepEqual(validatePayload(fixture()), fixture());
});

test('reject invalid and ambiguous v2 payloads with a constant secret-free error', () => {
  const {validatePayload} = require(corePath);
  const cases = [];
  const change = (key, value) => { const p=fixture(); p[key]=value; cases.push(p); };
  for (const url of ['http://gateway.example.ts.net','https://ts.net','https://evilts.net',
    'https://gateway.example.ts.net.evil.com','https://user:pass@gateway.example.ts.net',
    'https://@gateway.example.ts.net','https://gateway.example.ts.net?','https://gateway.example.ts.net#',
    'https://gateway.example.ts.net/path','https://gateway.example.ts.net/../',
    'https://gateway.example.ts.net:0','https://gateway.example.ts.net:65536',
    'https://gateway.example.ts.net:0443','https://gateway.example.ts.net.',
    'https://gateway..ts.net','https://-gateway.example.ts.net','https://gateway_.ts.net',
    'https://gateway.example.ts.net\\evil','https://%67ateway.example.ts.net',
    'https://gateway.example.ts.net\n',' https://gateway.example.ts.net',
    'https://gä teway.example.ts.net','https://gateway.example.ts.net:']) change('url',url);
  for (const [key, values] of Object.entries({v:[1,3,'2',null],kind:['wrong',null],
    transport:['systemTailscale',null],name:['', ' ', 'x'.repeat(129), 1]})) {
    for (const value of values) change(key,value);
  }
  for (const auth of [{strategy:'unknown'}, {strategy:'sessionToken',token:''},
    {strategy:'sessionToken',token:'fixture',username:'mixed'},
    {strategy:'usernamePassword',username:'fixture',password:'fixture',token:'mixed'},
    {strategy:'usernamePassword',username:'',password:'fixture'},
    {strategy:'usernamePassword',username:'fixture',password:''},
    {strategy:'usernamePassword',username:'x'.repeat(257),password:'fixture'},
    {strategy:'usernamePassword',username:'fixture',password:'x'.repeat(1025)},
    {strategy:'sessionToken',token:'x'.repeat(1025)}, null]) change('auth',auth);
  change('extra','forbidden');
  for (const key of Object.keys(fixture())) { const p=fixture(); delete p[key]; cases.push(p); }
  cases.push(null, [], 'bad');
  for (const payload of cases) assert.throws(() => validatePayload(payload), {message:'Invalid pairing details.'});
});

test('session token and normalization preserve exact supported credential contents', () => {
  const {validatePayload} = require(corePath);
  const p=fixture(); p.url='HTTPS://GATEWAY.EXAMPLE.TS.NET:443/';
  p.auth={strategy:'sessionToken',token:'fixture-token-ä-😀'};
  const actual=validatePayload(p);
  assert.equal(actual.url,'https://gateway.example.ts.net');
  assert.deepEqual(actual.auth,p.auth);
  p.url='https://gateway.example.ts.net:8443';
  assert.equal(validatePayload(p).url,p.url);
  p.auth={strategy:'usernamePassword',username:'fixture-雪',password:' fixture-ä-😀 '};
  assert.deepEqual(validatePayload(p).auth,p.auth);
});
test('bound serialized UTF-8 QR payload to 2048 bytes and reject malformed Unicode', () => {
  const {validatePayload} = require(corePath);
  const p=fixture(); p.auth.password='雪'.repeat(900);
  assert.throws(() => validatePayload(p), {message:'Invalid pairing details.'});
  p.auth.password='fixture-\ud800';
  assert.throws(() => validatePayload(p), {message:'Invalid pairing details.'});
});

test('generator output fits native v2 byte bounds and session-token semantics', () => {
  const {validatePayload} = require(corePath);
  for (const token of [' fixture-session','fixture session','fixture-session ', 'fixture\u0085session', 'tskey-fixture-only']) {
    const p=fixture(); p.auth={strategy:'sessionToken',token};
    assert.throws(()=>validatePayload(p), {message:'Invalid pairing details.'});
  }
  const p=fixture(); p.name='雪'.repeat(43);
  assert.throws(()=>validatePayload(p), {message:'Invalid pairing details.'});
  p.name='Fixture'; p.auth.username='雪'.repeat(86);
  assert.throws(()=>validatePayload(p), {message:'Invalid pairing details.'});
});
