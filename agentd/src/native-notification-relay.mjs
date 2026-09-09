import fs from 'node:fs'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'

export const NATIVE_NOTIFICATION_ARGUMENT = '--deliver-background-notification'
export const NOTIFICATION_REQUEST_DIRECTORY = 'notification-requests'

function writeRequest(file, payload) {
  let descriptor = null
  try {
    descriptor = fs.openSync(file, 'wx', 0o600)
    fs.writeFileSync(descriptor, JSON.stringify(payload), 'utf8')
    fs.fsyncSync(descriptor)
    fs.closeSync(descriptor)
    descriptor = null
  } catch (error) {
    if (descriptor !== null) {
      try { fs.closeSync(descriptor) } catch {}
    }
    try { fs.unlinkSync(file) } catch {}
    throw error
  }
}

/// Ask the signed Mechanician executable to post a native notification. Only the path to a bounded
/// 0600 JSON request appears in argv, so agent output is not exposed in the process table. The
/// helper consumes the request; this callback is a cleanup backstop if launch fails.
export function relayNativeNotification({
  executable,
  ambientDirectory,
  payload,
  environment = process.env,
  launch = execFile,
  logger = () => {},
}) {
  if (!executable || !path.isAbsolute(executable)) {
    logger('native notification relay unavailable — no Mechanician executable configured')
    return false
  }
  try {
    fs.accessSync(executable, fs.constants.X_OK)
    const directory = path.join(ambientDirectory, NOTIFICATION_REQUEST_DIRECTORY)
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 })
    fs.chmodSync(directory, 0o700)
    const request = path.join(directory, `${randomUUID()}.json`)
    writeRequest(request, payload)
    launch(
      executable,
      [NATIVE_NOTIFICATION_ARGUMENT, request],
      { env: environment, timeout: 15_000 },
      (error) => {
        try { fs.unlinkSync(request) } catch {}
        if (error) logger(`native notification relay failed: ${error.message || error}`)
      })
    return true
  } catch (error) {
    logger(`native notification relay failed: ${error.message || error}`)
    return false
  }
}
