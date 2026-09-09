// The persisted-sidecar adapter graduated into the production source tree when the first
// inspectable experimental Conversation Record exporter shipped. Keep this forwarding module so
// the dated R2 evidence harness continues to run against the exact implementation being dogfooded.
export {
  CANONICAL_FORMAT,
  canonicalFromSidecar,
} from '../../agentd/src/convrec/canonical-from-sidecar.mjs'
