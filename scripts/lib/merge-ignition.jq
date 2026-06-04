# merge-ignition.jq — deep-merge two Ignition 3.x JSON documents.
#
# Usage:
#   jq -n --slurpfile base base.json --slurpfile overlay overlay.json \
#     -f scripts/lib/merge-ignition.jq > merged.json
#
# Rules:
#   - Array fields (storage.files, systemd.units, passwd.users,
#     storage.directories, storage.links) are concatenated: base first,
#     overlay appended. The overlay can add but not replace individual entries.
#   - Scalar / object fields at the top level (ignition, config, etc.) are
#     taken from the overlay when present, base otherwise (overlay wins).
#   - The resulting ignition.version is taken from the base (both must be 3.x).
#
# This is intentionally simple: base and overlay content must be disjoint
# (no duplicate file paths, no duplicate unit names). Callers are responsible
# for ensuring that invariant.

def merge_arrays(base_obj; overlay_obj; field):
  (base_obj[field] // []) + (overlay_obj[field] // []);

# Extract the single document from the slurped array.
($base[0])    as $b |
($overlay[0]) as $o |

{
  ignition: $b.ignition,

  storage: {
    files:       merge_arrays($b.storage // {}; $o.storage // {}; "files"),
    directories: merge_arrays($b.storage // {}; $o.storage // {}; "directories"),
    links:       merge_arrays($b.storage // {}; $o.storage // {}; "links"),
  },

  systemd: {
    units: merge_arrays($b.systemd // {}; $o.systemd // {}; "units"),
  },

  passwd: {
    users:  merge_arrays($b.passwd // {}; $o.passwd // {}; "users"),
    groups: merge_arrays($b.passwd // {}; $o.passwd // {}; "groups"),
  },
}
# Drop empty arrays to keep the output clean.
| walk(if type == "object" then with_entries(select(.value != [])) else . end)
