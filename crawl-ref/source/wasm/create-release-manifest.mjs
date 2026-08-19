#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { lstat, readFile, readdir, writeFile } from 'node:fs/promises'
import { relative, resolve, sep } from 'node:path'

const usage = () => {
  console.error('usage: node wasm/create-release-manifest.mjs SITE_DIR ENGINE_COMMIT CRAWL_VERSION CRAWL_BASE')
  process.exit(2)
}

if (process.argv.length !== 6) usage()

const siteDir = resolve(process.argv[2])
const engineCommit = process.argv[3]
const crawlVersion = process.argv[4]
const crawlBase = process.argv[5]

if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i.test(engineCommit)) {
  throw new Error(`invalid engine commit: ${engineCommit}`)
}
if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i.test(crawlBase)) {
  throw new Error(`invalid Crawl base commit: ${crawlBase}`)
}
if (!/^v?[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:-[A-Za-z]+[0-9]+)?(?:-[0-9]+-g[0-9a-f]+)?$/i.test(crawlVersion)) {
  throw new Error(`invalid Crawl version: ${crawlVersion}`)
}

const files = []

const gamedataDir = resolve(siteDir, 'gamedata/local')
const gamedataEntries = await readdir(gamedataDir, { withFileTypes: true })
const gamedataFiles = gamedataEntries
  .filter(entry => entry.isFile() && (entry.name.endsWith('.js') || entry.name.endsWith('.png')))
  .map(entry => entry.name)
  .sort((a, b) => a < b ? -1 : a > b ? 1 : 0)
if (gamedataFiles.length === 0) throw new Error('site package has no local gamedata files')
await writeFile(
  resolve(gamedataDir, 'manifest.json'),
  `${JSON.stringify({ files: gamedataFiles })}\n`,
  { flag: 'wx' },
)

async function walk(directory) {
  const entries = await readdir(directory, { withFileTypes: true })
  entries.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)

  for (const entry of entries) {
    const path = resolve(directory, entry.name)
    const name = relative(siteDir, path).split(sep).join('/')
    const stat = await lstat(path)

    if (stat.isSymbolicLink()) {
      throw new Error(`site package may not contain symlinks: ${name}`)
    }
    if (stat.isDirectory()) {
      await walk(path)
      continue
    }
    if (!stat.isFile()) {
      throw new Error(`site package contains a non-file entry: ${name}`)
    }
    if (name === 'release.json') continue

    const contents = await readFile(path)
    files.push({
      path: name,
      bytes: contents.byteLength,
      sha256: createHash('sha256').update(contents).digest('hex'),
    })
  }
}

await walk(siteDir)
files.sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0)

const versionPath = resolve(siteDir, 'offline/version.json')
const version = JSON.parse(await readFile(versionPath, 'utf8'))
if (!/^[0-9a-f]{12}$/.test(version.build ?? '')) {
  throw new Error('offline/version.json has no valid 12-character build id')
}
if (typeof version.version !== 'string' || version.version.length === 0) {
  throw new Error('offline/version.json has no game version')
}

const required = [
  'offline/crawl.js',
  'offline/crawl.wasm.gz',
  'offline/crawl.data.gz',
  'offline/prewarm/manifest.json',
  'offline/prewarm/prewarm.bin.gz',
  'offline/version.json',
  'gamedata/local/manifest.json',
]
const packaged = new Set(files.map(file => file.path))
for (const name of required) {
  if (!packaged.has(name)) throw new Error(`site package is missing ${name}`)
}

const manifest = {
  schema: 1,
  build: version.build,
  version: version.version,
  crawlVersion,
  crawlBase: crawlBase.toLowerCase(),
  engineCommit: engineCommit.toLowerCase(),
  files,
}

await writeFile(
  resolve(siteDir, 'release.json'),
  `${JSON.stringify(manifest, null, 2)}\n`,
  { flag: 'wx' },
)
