// Pure conflict logic. HubSpot has per-property history; the existing Supabase
// schema only has per-record export timestamps. This is a conservative fallback,
// not exact per-field latest-write-wins on the Supabase side.
export type Direction = "pull" | "push";
export type Decision = { action: "update" | "skip"; reason: string };

function present(value: unknown): boolean {
  return value !== null && value !== undefined &&
    String(value).trim() !== "";
}

export function decide(
  direction: Direction,
  localValue: unknown,
  remoteValue: unknown,
  localRecordTimestamp: unknown,
  remotePropertyTimestamp: unknown,
): Decision {
  const local = present(localValue) ? String(localValue).trim() : "";
  const remote = present(remoteValue) ? String(remoteValue).trim() : "";
  const source = direction === "pull" ? remote : local;
  const destination = direction === "pull" ? local : remote;
  if (!source) return { action: "skip", reason: "source_empty_no_deletes" };
  if (source === destination) return { action: "skip", reason: "already_equal" };
  if (!destination) return { action: "update", reason: "fill_empty_destination" };

  const localTs = Date.parse(String(localRecordTimestamp ?? ""));
  const remoteTs = Date.parse(String(remotePropertyTimestamp ?? ""));
  if (!Number.isFinite(localTs) || !Number.isFinite(remoteTs)) {
    return { action: "skip", reason: "no_reliable_comparison" };
  }
  if (localTs === remoteTs) {
    return { action: "skip", reason: "timestamp_tie" };
  }
  if (direction === "pull" && remoteTs > localTs) {
    return { action: "update", reason: "hubspot_property_newer_than_supabase_record" };
  }
  if (direction === "push" && localTs > remoteTs) {
    return { action: "update", reason: "supabase_record_newer_than_hubspot_property" };
  }
  return { action: "skip", reason: "destination_may_be_newer" };
}
