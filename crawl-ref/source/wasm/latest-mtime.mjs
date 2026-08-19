#!/usr/bin/env node

import { lstat, readdir } from 'node:fs/promises'
import { resolve } from 'node:path'

if (process.argv.length < 3) {
  console.error('usage: node wasm/latest-mtime.mjs PATH...')
  process.exit(2)
}

let latest = null

async function walk(path) {
  const stat = await lstat(path)

  if (stat.isSymbolicLink()) return
  if (stat.isFile()) {
    latest = Math.max(latest ?? 0, Math.floor(stat.mtimeMs / 1000))
    return
  }
  if (!stat.isDirectory()) return

  const entries = await readdir(path)
  for (const entry of entries) await walk(resolve(path, entry))
}

for (const path of process.argv.slice(2)) await walk(resolve(path))

if (latest === null) throw new Error('input paths contain no regular files')
console.log(latest)
