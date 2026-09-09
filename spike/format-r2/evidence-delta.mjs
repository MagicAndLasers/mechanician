export function deltaCounts(current, prior) {
  return Object.fromEntries(
    [...new Set([...Object.keys(current), ...Object.keys(prior)])].sort().map((key) => [
      key, (current[key] ?? 0) - (prior[key] ?? 0),
    ]),
  )
}

/// Versioned evidence must compare like-for-like nested inventories. Fail closed when a predecessor
/// does not expose the expected shape; treating a missing nested object as an empty baseline makes
/// every current total look like newly covered evidence.
export function evidenceDeltaFromPredecessor({
  observedSidecarDispositions,
  captureDispositions,
  separatelyReviewedProductionSidecarPaths,
}, predecessor) {
  const priorObserved = predecessor?.reviewedSidecarInventory?.observedCorpus?.dispositions
  const priorCapture = predecessor?.reviewedCaptureSurface?.totalDispositions
  const priorProductionPaths =
    predecessor?.reviewedSidecarInventory?.reviewedProductionSchemaOnly?.paths
  if (!priorObserved || !priorCapture || !Number.isInteger(priorProductionPaths)) {
    throw new Error('predecessor evidence does not expose the required nested inventory counters')
  }
  return {
    observedSidecarDispositions: deltaCounts(observedSidecarDispositions, priorObserved),
    captureDispositions: deltaCounts(captureDispositions, priorCapture),
    separatelyReviewedProductionSidecarPaths:
      separatelyReviewedProductionSidecarPaths - priorProductionPaths,
  }
}
