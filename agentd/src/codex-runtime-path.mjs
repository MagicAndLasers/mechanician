// Put the Codex primary runtime's bundled binaries on the app-server's PATH.
//
// Two of the runtime plugins — `documents` and `pdf` — shell out to tools that are not on a normal
// Mac: `soffice` (LibreOffice headless), `pdftoppm` and `pdfinfo` (poppler), `heif-convert`. The
// runtime ships all of them, and the ChatGPT desktop app puts them on PATH when it spawns codex.
// Mechanician spawns codex itself, so it did not, and those two plugins installed and then failed
// on their first command.
//
// Only the BINARIES need this. The plugins resolve their own Python through their own helper
// (`runtime_tools.py` builds the path from `Path.home()`), so Mechanician must not prepend a Python
// to PATH: that would shadow the user's interpreter in every shell command the agent runs, to fix a
// problem the plugins do not have.
//
// The runtime is downloaded by the ChatGPT app into ~/.cache, which is shared and CODEX_HOME
// independent — so if it is there at all, it is there for us too. If it is not, this contributes
// nothing and nothing breaks.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

export function runtimeDependencyRoot(home = os.homedir()) {
  return path.join(home, '.cache', 'codex-runtimes', 'codex-primary-runtime', 'dependencies')
}

function existingDirectory(candidate) {
  try {
    return fs.statSync(candidate).isDirectory() ? candidate : null
  } catch {
    return null
  }
}

/**
 * PATH for the codex app-server, with the runtime's binaries woven in.
 *
 * `override` goes FIRST and `fallback` goes LAST, which is the runtime's own naming and its own
 * intent: an overriding `soffice` must beat whatever LibreOffice the user has installed, because
 * the plugins are written against this specific headless build; a fallback `git` must only be
 * reached when the user has none.
 *
 * Idempotent — re-running never duplicates an entry, so a restart cannot grow PATH without bound.
 */
export function codexRuntimePATH(basePATH, { home = os.homedir() } = {}) {
  const root = runtimeDependencyRoot(home)
  const override = existingDirectory(path.join(root, 'bin', 'override'))
  const fallback = existingDirectory(path.join(root, 'bin', 'fallback'))
  if (!override && !fallback) return basePATH || ''

  const existing = (basePATH || '').split(path.delimiter).filter(Boolean)
  const without = existing.filter((entry) => entry !== override && entry !== fallback)
  return [
    ...(override ? [override] : []),
    ...without,
    ...(fallback ? [fallback] : []),
  ].join(path.delimiter)
}

/// Which runtime tools this actually supplies, for logging. Naming them makes a silent capability
/// change visible in the log rather than something you discover from a plugin failing.
export function codexRuntimeTools(home = os.homedir()) {
  const root = runtimeDependencyRoot(home)
  const names = []
  for (const kind of ['override', 'fallback']) {
    try {
      names.push(...fs.readdirSync(path.join(root, 'bin', kind)))
    } catch { /* absent is normal */ }
  }
  return names.sort()
}
