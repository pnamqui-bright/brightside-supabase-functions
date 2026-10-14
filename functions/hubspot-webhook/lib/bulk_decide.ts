/** Record-level conflict gate for the manual bulk-only sync. No per-field timestamps. */
export type Direction = "pull" | "push";
export type Pair = { property: string; local: string; remote: string; pushOnly?: boolean; invalid?: boolean };
export type Evaluation = {
  status: "eligible" | "conflict" | "equal";
  reason: string;
  pull: Pair[];
  push: Pair[];
};

export function populated(value: unknown): string {
  return value === null || value === undefined ? "" : String(value).trim();
}
export function changedAfter(modifiedAt: string, baseline: string): boolean {
  const current = Date.parse(modifiedAt);
  const prior = Date.parse(baseline);
  // Missing/invalid evidence is NOT treated as evidence of no change.
  return Number.isFinite(current) && Number.isFinite(prior) && current > prior;
}

export function evaluate(
  pairs: Pair[], localUpdatedAt: string, remoteUpdatedAt: string,
  lastSyncedAt: string, force: Direction | null = null,
): Evaluation {
  const valid = pairs.filter((p) => !p.invalid);
  const divergent = valid.filter((p) => p.local && p.remote && p.local !== p.remote && !p.pushOnly);
  const complete = !!lastSyncedAt && Number.isFinite(Date.parse(lastSyncedAt));
  const localValid = Number.isFinite(Date.parse(localUpdatedAt));
  const remoteValid = Number.isFinite(Date.parse(remoteUpdatedAt));
  const localChanged = complete && changedAfter(localUpdatedAt, lastSyncedAt);
  const remoteChanged = complete && changedAfter(remoteUpdatedAt, lastSyncedAt);
  const wholeRecordConflict = complete && (!localValid || !remoteValid || (localChanged && remoteChanged));
  const initialConflict = !complete && divergent.length > 0;
  const unexplainedDrift = complete && !localChanged && !remoteChanged && divergent.length > 0;
  if (!force && (wholeRecordConflict || initialConflict || unexplainedDrift)) {
    return { status: "conflict", reason: !complete ? "no_sync_baseline_conflict"
      : wholeRecordConflict ? (localValid && remoteValid ? "both_sides_changed_since_last_sync" : "missing_modification_timestamp")
      : "unexplained_divergence_since_last_sync", pull: [], push: [] };
  }
  const pull: Pair[] = [];
  const push: Pair[] = [];
  for (const field of valid) {
    if (field.local === field.remote) continue;
    if (field.pushOnly) {
      if (field.local && (!force || force === "push")) push.push(field);
      continue;
    }
    if (force === "pull") {
      if (field.remote) pull.push(field);
    } else if (force === "push") {
      if (field.local) push.push(field);
    } else {
      // Filling an empty destination is safe independently of timestamps.
      if (!field.local && field.remote) pull.push(field);
      else if (!field.remote && field.local) push.push(field);
      else if (complete && remoteChanged && !localChanged) pull.push(field);
      else if (complete && localChanged && !remoteChanged) push.push(field);
    }
  }
  return {
    status: pull.length || push.length ? "eligible" : "equal",
    reason: pull.length || push.length ? "safe_bulk_changes" : "already_equal",
    pull, push,
  };
}
