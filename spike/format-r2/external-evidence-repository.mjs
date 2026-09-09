import fs from 'node:fs'
import path from 'node:path'

export const FORMAT_EVIDENCE_REPOSITORY_ENV =
  'MECHANICIAN_FORMAT_EVIDENCE_REPOSITORY'

const EVIDENCE_DIRECTORY_COMPONENTS = Object.freeze([
  'docs', 'mechanician', 'agent-document-format',
])

function configuredPath(environment) {
  const value = environment[FORMAT_EVIDENCE_REPOSITORY_ENV]
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(
      `${FORMAT_EVIDENCE_REPOSITORY_ENV} must be set to the absolute path of the external evidence checkout`,
    )
  }
  if (!path.isAbsolute(value)) {
    throw new Error(`${FORMAT_EVIDENCE_REPOSITORY_ENV} must be an absolute path`)
  }
  return value
}

export function resolveFormatEvidenceRepository(environment = process.env) {
  const configured = configuredPath(environment)
  let repositoryRoot
  try {
    repositoryRoot = fs.realpathSync(configured)
  } catch {
    throw new Error(
      `${FORMAT_EVIDENCE_REPOSITORY_ENV} does not resolve to an existing checkout: ${configured}`,
    )
  }
  if (!fs.statSync(repositoryRoot).isDirectory()) {
    throw new Error(`${FORMAT_EVIDENCE_REPOSITORY_ENV} must name a directory`)
  }

  const evidenceDirectory = path.join(repositoryRoot, ...EVIDENCE_DIRECTORY_COMPONENTS)
  try {
    if (!fs.statSync(evidenceDirectory).isDirectory()) throw new Error('not a directory')
  } catch {
    throw new Error(
      `${FORMAT_EVIDENCE_REPOSITORY_ENV} does not contain ${EVIDENCE_DIRECTORY_COMPONENTS.join('/')}`,
    )
  }
  return { repositoryRoot, evidenceDirectory }
}

export function optionalFormatEvidenceRepository(environment = process.env) {
  const value = environment[FORMAT_EVIDENCE_REPOSITORY_ENV]
  if (typeof value !== 'string' || value.trim() === '') return null
  return resolveFormatEvidenceRepository(environment)
}
