#!/bin/bash
# Unit tests for Model.js. Needs node. Run: ./test/model-test.sh

set -euo pipefail
cd "$(dirname "$0")/.."

node - <<'JS'
const assert = require('node:assert/strict')
const model = require('./Model.js')

assert.equal(model.fileKind('photo.JPG'), 'image')
assert.equal(model.fileKind('clip.webm'), 'video')
assert.equal(model.fileKind('report.pdf'), 'document')
assert.equal(model.fileKind('archive.zip'), 'misc')
assert.equal(model.formatBytes(1530), '1.53 KB')
assert.equal(model.formatBytes(2_000_000_000), '2 GB')
assert.equal(model.formatPercent(7.25), '7.3%')
assert.equal(model.usageText(1000, 2000, true), '1 KB of 2 KB')
assert.equal(model.usageText(1000, 0, false), '1 KB')

const parsed = model.parseStatus(JSON.stringify({
  ok: true, installed: true, daemonRunning: true, running: true, authenticated: true,
  email: 'me@example.com', files: [{ name: 'x.txt' }]
}))
assert.ok(parsed.installed && parsed.running && parsed.authenticated)
assert.equal(parsed.email, 'me@example.com')
assert.equal(parsed.files.length, 1)

const broken = model.parseStatus('{not json')
assert.equal(broken.ok, false)

assert.equal(
  model.fileMeta({ modifiedTs: 1000, folder: 'Docs' }, 1000 * 1000 + 3600 * 1000),
  '1h ago · Docs'
)
console.log('model tests passed')
JS
