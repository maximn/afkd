#!/usr/bin/env node
// Tests for check-pins.mjs. A guard that cannot fail is the same false
// confidence it was written to remove, so every rule gets a case that breaks
// the real Dockerfile in a plausible way and asserts the checker notices.
//
// Run with `node scripts/check-pins.test.mjs`; CI runs it alongside the check.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { check } from './check-pins.mjs'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const DOCKERFILE = readFileSync(join(root, 'Dockerfile'), 'utf8')
const RENOVATE = JSON.parse(readFileSync(join(root, 'renovate.json'), 'utf8'))

let failed = 0

// Asserts the mutated Dockerfile trips a rule whose message contains `expect`.
const rejects = (name, mutate, expect, renovate = RENOVATE) => {
  const { problems } = check(mutate(DOCKERFILE), renovate)
  const hit = problems.find((p) => p.what.includes(expect))
  if (hit) return console.log(`  ✓ rejects ${name}`)
  failed++
  console.error(`  ✗ rejects ${name}`)
  console.error(`      expected a problem containing: ${expect}`)
  console.error(`      got: ${problems.map((p) => p.what).join(' | ') || '(none)'}`)
}

const accepts = (name, mutate = (s) => s, renovate = RENOVATE) => {
  const { problems } = check(mutate(DOCKERFILE), renovate)
  if (problems.length === 0) return console.log(`  ✓ accepts ${name}`)
  failed++
  console.error(`  ✗ accepts ${name}`)
  console.error(`      unexpected: ${problems.map((p) => `${p.line}: ${p.what}`).join(' | ')}`)
}

console.log('check-pins:')

// The real files must pass, or every case below is meaningless.
accepts('the Dockerfile as committed')

rejects('an ARG with no annotation',
  (s) => `${s}\nARG NEWTOOL_VERSION=1.0.0\n`,
  "no '# renovate:' annotation")

rejects('an annotation with no ARG under it',
  (s) => `${s}\n# renovate: datasource=npm depName=orphan\nRUN echo hi\n`,
  'not followed by an ARG')

// The subtle one: reads fine, invisible to Renovate. This is the shape of the
// bug that went unnoticed for five months.
rejects('an annotation whose keys are in the wrong order',
  (s) => s.replace('# renovate: datasource=npm depName=@anthropic-ai/claude-code',
    '# renovate: depName=@anthropic-ai/claude-code datasource=npm'),
  'never bump it')

rejects('an unpinned global npm install',
  (s) => `${s}\nRUN npm install -g some-new-tool\n`,
  'without a version')

// The Dockerfile's one global install spells the flag out, which rule 4 used to
// look straight past: dropping this pin passed Lint.
rejects('the corepack install with its pin removed',
  (s) => s.replace('"corepack@${COREPACK_VERSION}"', 'corepack'),
  "'corepack' is installed without a version")

rejects('an unpinned install spelled --global',
  (s) => `${s}\nRUN npm install --global some-new-tool\n`,
  "'some-new-tool' is installed without a version")

rejects('an unpinned install with the flag after the package',
  (s) => `${s}\nRUN npm install some-new-tool -g\n`,
  "'some-new-tool' is installed without a version")

rejects('an unpinned install behind an option that takes a value',
  (s) => `${s}\nRUN npm install -g --prefix /usr/local some-new-tool\n`,
  "'some-new-tool' is installed without a version")

rejects('an unpinned install after a pinned one in the same RUN',
  (s) => `${s}\nRUN npm install -g "pkg@1.0.0" && npm install --global some-new-tool\n`,
  "'some-new-tool' is installed without a version")

accepts('a pinned install behind an option that takes a value',
  (s) => `${s}\nRUN npm install -g --prefix /usr/local "pkg@1.0.0"\n`)

accepts('a pinned install with an option written as --key=value',
  (s) => `${s}\nRUN npm install --global --prefix=/usr/local "pkg@1.0.0"\n`)

accepts('an npm install that is not global',
  (s) => `${s}\nRUN npm install --prefix /app some-dep\n`)

// apt pins exact versions only for packages from repos that keep their old
// releases (Claude Code's does). A version typed in by hand is one Renovate
// cannot see, so it has to come from an annotated ARG like every other pin.
rejects('an apt package pinned to a literal version',
  (s) => `${s}\nRUN apt-get update && apt-get install -y --no-install-recommends some-tool=1.2.3-1\n`,
  'apt package')

accepts('an apt package pinned through an ARG',
  (s) => `${s}\nRUN apt-get update && apt-get install -y "some-tool=\${SOME_TOOL_VERSION}-1"\n`)

rejects('a "latest" release URL',
  (s) => `${s}\nRUN curl -fsSL https://github.com/o/r/releases/latest/download/x -o /usr/local/bin/x\n`,
  '"latest" release URL')

rejects('a download that pins nothing',
  (s) => `${s}\nRUN curl -fsSL https://example.com/tool -o /usr/local/bin/tool\n`,
  'without interpolating')

rejects('an untagged base image',
  (s) => s.replace(/^FROM \S+/m, 'FROM debian:latest'),
  'untagged or :latest')

// A tag can be re-pushed; only the digest names exact bytes. Renovate keeps
// tag and digest moving together, so requiring both costs nothing.
rejects('a base image pinned by tag alone',
  (s) => s.replace(/^FROM (\S+?)@sha256:\w+/m, 'FROM $1'),
  'no digest')

rejects('a COPY --from image pinned by tag alone',
  (s) => s.replace(/(COPY --from=\S+?)@sha256:\w+/, '$1'),
  'no digest')

rejects('an untagged COPY --from image',
  (s) => `${s}\nCOPY --from=ghcr.io/o/tool /usr/local/bin/tool /usr/local/bin/tool\n`,
  'untagged or :latest')

// A build stage named earlier in the file is not an image reference.
accepts('a COPY --from naming a build stage',
  (s) => s.replace(/^FROM (\S+)/m, 'FROM $1 AS base') + '\nCOPY --from=base /etc/hostname /tmp/x\n')

// The digest-pin shape: same rules, different manager. Worth its own cases
// because a _REF pin is matched by a second customManager, and an ARG that
// only the first manager sees is exactly the silent-staleness bug again.
rejects('a _REF ARG with no annotation',
  (s) => `${s}\nARG NEWREPO_REF=0123456789abcdef0123456789abcdef01234567\n`,
  "no '# renovate:' annotation")

rejects('a _REF pin no customManager matches',
  (s) => s.replace('# renovate: datasource=git-refs depName=https://github.com/ohmyzsh/ohmyzsh',
    '# renovate: depName=https://github.com/ohmyzsh/ohmyzsh datasource=git-refs'),
  'never bump it')

rejects('renovate.json with the customManager removed',
  (s) => s,
  'no regex customManager',
  { ...RENOVATE, customManagers: [] })

// The escape hatch has to work, or the next unversioned artifact gets the
// rule deleted instead of annotated.
accepts('a marked-ignore block that downloads without a version',
  (s) => `${s}\n# pin-check: ignore - test fixture\nRUN curl -fsSL https://example.com/x -o /x\n`)

// Docker strips comment lines inside a continuation before parsing, so prose
// written between two escaped lines is not an argument. The checker joined it
// in and read every word of the comment as a package name.
accepts('a comment inside a RUN continuation',
  (s) => `${s}\nRUN npm install -g \\\n# a note about why, mid-block\n      "pkg@1.0.0"\n`)

console.log(failed === 0 ? '\nall passed' : `\n${failed} failed`)
process.exit(failed === 0 ? 0 : 1)
