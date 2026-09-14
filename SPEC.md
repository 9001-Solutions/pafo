# pafo - protocol and behavior spec

pafo is an Ashita v4 addon that records drop observations (mob kills,
battlefield crates, steal/despoil attempts) and submits them to PSXI's
community drop-rate aggregator. This document is the contract between the
addon and the PSXI backend. The backend implementation validates against
this spec; changes land here first.

Status: draft v1 (2026-09-02). Protocol version: 1.

## 1. Scope

The addon captures, on supported servers:

1. Mob kills and the resulting treasure pool contents, with Treasure
   Hunter attribution.
2. Battlefield clears (BCNM/ENM/KSNM/ISNM) and the complete armoury crate
   contents, including gil. No TH (TH does not affect battlefields).
3. Steal and Despoil attempts and outcomes. No TH.

Out of scope for v1: gathering, digging, fishing, chests/coffers, any
form of leaderboard or public attribution.

The addon never sends packets to game servers and never automates play.
It passively observes incoming packets/log lines and talks only to the
PSXI backend over HTTPS.

## 2. Startup and configuration

On load, the addon fetches the config endpoint:

    GET {PSXI_BASE}/api/pafo/config

Response:

    {
      "protocol": 1,
      "ingest_url": "https://...",
      "batch": { "flush_seconds": 60, "max_events": 25 },
      "servers": [
        {
          "slug": "horizon",
          "name": "HorizonXI",
          "enabled": true,
          "max_th": 4,
          "th_plus_item_ids": [<Nanaa's Lucky Charm>, <Assassin's Armlets>, <Assassin's Armlets +1>],
          "hosts": ["play.horizonxi.com"]
        },
        ...
      ]
    }

- `ingest_url` is authoritative and may change between sessions; the
  addon must never hardcode the ingest host.
- The active server is auto-detected: the addon reads `--server <host>`
  from the game process command line (private servers boot the client
  inside xiloader or a fork of it, which takes that flag) and matches the
  host against each server's optional `hosts` list, exactly or as a
  subdomain. `hosts` comes from PSXI's `servers.host` column (the same
  host the AH scanner connects to); the addon has no built-in list.
  There is no manual override, and the server is never taken from saved
  settings, so a report cannot be filed under a server the client is not
  connected to. If nothing is detected, the addon records nothing.
- If the active server has `enabled: false`, the addon records nothing
  and says so once per session.
- Config is cached locally and refreshed at most once per session; on
  fetch failure the cached copy is used.

## 3. Authentication

Submissions require a pafo token (ingest-scoped; never the user's main
PSXI API token).

`/pafo login` runs PSXI's shared addon device flow (the same one the psxi
addon uses, selected by `kind`):

1. `POST {PSXI_BASE}/auth/device` with body `{ "kind": "pafo" }` ->
   `{ device_code, user_code, verify_url, interval, expires_in }`.
   `device_code` is the opaque poll secret; `user_code` is the short
   human code (format `ABCD-EFGH`).
2. Open the system browser at `{verify_url}` and print the URL and
   `user_code` to chat. The user signs in and types the code by hand;
   the page does not accept a prefilled code (a prefill link would let
   anyone who started a device flow phish a signed-in user into
   approving it).
3. Poll `POST {PSXI_BASE}/auth/token` with `{ "device_code": "..." }`
   every `interval` seconds (interval is always > 0):
   - `200 { "error": "authorization_pending" }` - keep polling. An
     expired or unknown code answers the same way; give up when
     `expires_in` has elapsed.
   - `200 { "token": "pafo_..." }` - store the token (the row is
     consumed; it is returned exactly once), confirm in chat.
   Any non-200 is a hard failure: stop and tell the user to retry.

The token starts with `pafo_` and is ingest-scoped - it cannot call any
other PSXI API. It is stored in the addon's local settings. `/pafo
logout` deletes it. A 401 from ingest means the token was revoked: stop
submitting, keep the queue, tell the user to `/pafo login` again.

## 4. Event capture

### 4.1 Common envelope

Events are batched and POSTed to `ingest_url`:

    POST {ingest_url}/ingest
    Authorization: Bearer <pafo token>

    {
      "protocol": 1,
      "addon_version": "x.y.z",
      "server_slug": "horizon",
      "reporter": { "char_name": "...", "job": "THF", "sub": "NIN",
                    "level": 75 },
      "events": [ ... ]
    }

Reporter identity is used by PSXI for abuse handling only and is never
displayed publicly.

Every event carries:

- `id`: client-generated unique id (16+ random hex chars). Idempotency
  key; the backend ACKs duplicates without reprocessing, so resending a
  queued batch is always safe.
- `type`: `"kill" | "battlefield" | "steal" | "despoil"`.
- `ago`: whole seconds elapsed between the observation and the moment the
  batch is sent. The addon never sends absolute clock time; the backend
  reconstructs timestamps from its own receive time minus `ago`.
- `zone_id`: FFXI zone id at observation time.

### 4.2 Kill events

Emitted when a mob the player's party/alliance has claim on dies and its
treasure pool entries (if any) are observed.

    {
      "id": "...", "type": "kill", "ago": 12, "zone_id": 103,
      "mob": { "actor_id": 17187073, "name": "Valkurm Emperor" },
      "drops": [ { "item_id": 17061, "count": 1 }, ... ],
      "th": { "min": 2, "exact": false, "source": "level_inferred" }
    }

- `actor_id`: the mob's zone-local actor/server id as seen on the wire.
  Used server-side to merge reports of the same kill from multiple party
  members. Send it raw; do not normalize.
- `drops`: complete treasure-pool additions attributed to this kill,
  with multiplicity. An empty array is a valid and REQUIRED observation
  (kills with no drops are the denominator).
- A kill observed without certainty that the full pool was seen (zoned
  mid-pool, addon loaded mid-fight) must be discarded, not sent partial.
- `th`: see section 5.

### 4.3 Battlefield events

Emitted when an armoury crate is opened (or the battlefield loot list is
otherwise fully observed) after a battlefield win.

    {
      "id": "...", "type": "battlefield", "ago": 30, "zone_id": 144,
      "battlefield": { "name": "3, 2, 1...", "entry_zone_id": 144 },
      "crate_actor_id": 17223681,
      "items": [ { "item_id": 17316, "count": 2 }, ... ],
      "gil": 12000,
      "partial": false
    }

- `name`: the battlefield name string as presented by the client
  (menu/entry text), verbatim; the backend normalizes.
- `crate_actor_id`: the armoury crate's actor id, when a crate was
  observed. REQUIRED whenever available: battlefield zones host several
  simultaneous arenas, and the crate id is what stops two parties'
  concurrent runs of the same fight from being merged into one. Omit
  only when no crate spawned (gil-only or loot-list-only observations).
- `partial: true` when the addon cannot guarantee it saw the complete
  crate (disconnect, zoned early). Partial events count for the items
  they contain and are excluded from absence statistics; when in doubt,
  send partial rather than dropping the event (unlike kills, crate
  observations are expensive to come by).
- `gil: 0` when no gil was seen; omit nothing.
- No `th` field. Ever.

### 4.4 Steal / despoil events

The player's own attempts are emitted per attempt, including failures.
Other players' steals and despoils are emitted only when they succeed
(`result: "item"`): the item is what identifies a monster's steal table,
their failures would only inflate attempt counts, and several reporters
can see the same steal.

    {
      "id": "...", "type": "steal", "ago": 2, "zone_id": 103,
      "mob": { "actor_id": 17187100, "name": "Goblin Thug" },
      "result": "item" | "failed" | "nothing_left",
      "item_id": 4357
    }

- `result: "item"` requires `item_id`; the other results omit it.
- `failed` = the attempt whiffed (counts as a trial server-side).
- `nothing_left` = the client message indicating the mob has nothing to
  steal (excluded from trial counts server-side; still send it).
- `type: "despoil"` has the identical shape.
- An active quest can swap a monster's steal result for a quest item. The
  addon cannot see anyone's quest state, so such items arrive as ordinary
  steals; consumers should treat a rarely seen steal item next to a
  common one as suspect rather than as part of the steal table.

## 5. Treasure Hunter attribution

Applies to kill events only. Constraint that shapes everything: on
75-era servers (Horizon, Phoenix) TH caps at 4 and there is NO log
messaging for TH procs or tiers. Attribution is pure inference from
observed party composition, actions, and (for the player only) gear.

`th` object: `min` (integer >= 0), `exact` (bool), `source` (string).
The tier submitted describes the highest TH applied to the mob during
the fight, per these rules, evaluated over everyone observed directly
acting on the mob (any hostile action: melee, ranged, spell, JA):

1. No THF main or sub acted on the mob: `{min: 0, exact: true,
   source: "none"}`.
2. Highest THF involvement is a THF subjob, or a main THF below 45:
   `{min: 1, exact: true, source: "sub_or_lowlevel"}`.
3. Main THF level 45-74 acted on the mob: `{min: 2, exact: true,
   source: "level_inferred"}`.
4. Main THF level 75 acted on the mob:
   - The player themself is that THF: inspect own equipment for the
     active server's `th_plus_item_ids` (from config; PSXI derives it
     from the Treasure Hunter item mod with the server preset applied).
     Distinct TH+1 sources equipped: Assassin's Armlets and Assassin's
     Armlets +1 are ONE source (the hands slot); the charm/knife item is
     another. Tier =
     2 + source count: none -> `{min: 2, exact: true}`, one ->
     `{min: 3, exact: true}`, both -> `{min: 4, exact: true}`; source
     `"gear_detected"`. Gear is read at time of action, not at kill.
   - Another player is that THF: prompt (4.x below). Answered ->
     `{min: N, exact: true, source: "user_prompted"}`. Unanswered ->
     `{min: 2, exact: false, source: "unknown"}` ("TH2+ (unknown)").
5. Multiple qualifying THFs: take the highest resolved tier; if an
   unresolved THF (4 or 6) could exceed the best exact tier, report the
   best exact value as `min` with `exact: false` (e.g. self TH3 exact
   plus an unanswered 75 THF -> `{min: 3, exact: false}`). When the
   best exact tier is no higher than the unresolved floor (2 for a 75
   THF, 1 for an anonymous THF), report the floor as `unknown`.
6. Anonymous party members (`/anon`) arrive with main job, sub job and
   levels all 0, so rules 1-5 cannot see them. Their actions instead
   prove a TH floor, kept per character for the session (survives
   zoning; the highest floor seen wins):
   - Evisceration (WS 25): floor 0. Any job with dagger 230 (RDM, BRD)
     can use it, so it only marks the member as a possible THF.
   - Sneak Attack (JA 44) or Trick Attack (JA 76): floor 1. These need
     THF as main or sub, and any such job has at least TH1.
   - Accomplice (JA 84) or Collaborator (JA 236): floor 2. THF main
     only, level 65+, so TH2 is guaranteed.
   A hinted member follows the prompt path with the buttons starting at
   the floor (a floor of 0 adds a "None" answer meaning not a THF).
   Answered N > 0 -> `{min: N, exact: true, source: "user_prompted"}`,
   with N raised to the floor if lower. Answered "None" -> the member
   contributes nothing. Unanswered -> `{min: floor, exact: false,
   source: "unknown"}`. A hint is ignored as soon as the member's job
   becomes visible.

Source ranking used by the backend when merging multiple reports of one
kill (highest wins): `gear_detected` > `user_prompted` >
`level_inferred` > `sub_or_lowlevel` > `unknown`. A report can only
tighten (raise `min`, set `exact`), never loosen.

### 5.1 The TH prompt

When a not-previously-seen level 75 THF (not the player) first acts on a
mob the addon will report, show a small non-blocking prompt: "Does
<name> have TH2, TH3, or TH4?" with a dismiss option. For an anonymous
member flagged by rule 6 the choices start at the proven floor (for
example "Does <name> have TH1, TH2, TH3, TH4, or none?" after
Evisceration only) and a note says which ability was seen.

- The answer is cached per (server, character name) in local settings
  and reused for all future kills until invalidated.
- Kills observed while the prompt is unanswered are submitted as
  TH2+ unknown immediately; they are NOT held back. (The backend may
  support reattribution later; the addon does not resubmit.)
- Invalidation: `/pafo th reset <name>` clears one entry; `/pafo th
  reset` clears all; the addon's config UI lists cached answers with
  per-entry removal. Cached answers survive reloads.
- A character previously answered who is later seen below 75 (delevel)
  falls back to the level rules; the cache entry is kept but unused
  below 75.

## 6. Batching, queue, retry

- Events accumulate in an in-memory queue, flushed when EITHER
  `batch.flush_seconds` elapse since the oldest queued event OR
  `batch.max_events` are queued, whichever comes first. No flush when
  the queue is empty.
- The queue persists to disk on flush failure, zone, and addon unload;
  it is drained on next load. `ago` values must be computed from the
  original observation time, so persisted events store their own
  observation timestamps locally (local clock is fine; only deltas are
  transmitted).
- Retry with exponential backoff (base 30s, cap 15 min) on network
  errors and 5xx. On 429, respect Retry-After if present, else back off
  as above.
- Terminal per-batch errors: 401 (token revoked - stop, keep queue,
  prompt re-login), 403 with `server_disabled` (drop queued events for
  that server, notify once), 400 with per-event rejections (drop only
  the rejected events, log locally).
- Ingest response: `200 { accepted, duplicates, rejected: [{index,
  reason}] }`. Anything accepted or duplicate is removed from the queue.
- Disk queue cap: 5000 events; oldest dropped first past the cap
  (with one chat warning).

## 7. Commands

    /pafo login        - device-flow account link (section 3)
    /pafo logout       - forget the token
    /pafo th reset [name] - clear cached TH answers (section 5.1)
    /pafo status       - queue depth, link state, server, config age
    /pafo off | on     - pause/resume capture (state persists)

## 8. Privacy

- Public PSXI pages show only aggregate counts ("N kills from M
  contributors"). No character names, no per-user stats.
- The reporter block (section 4.1) and TH prompt answers name other
  players' characters; both are used server-side solely for dedup,
  attribution quality, and abuse handling. They are never exposed.
- The addon sends nothing until an account is linked and a supported
  server is detected, and nothing at all while `/pafo off`.

## 9. Versioning

- `protocol` is bumped only on breaking envelope/event changes; the
  backend rejects unknown versions with a machine-readable error and
  the addon tells the user to update.
- Additive fields may appear in any response without a protocol bump;
  the addon must ignore unknown fields.
- `addon_version` is informational (abuse triage, cohort debugging).

## 10. Spec changelog

- 2026-09-14: anonymous party members get a TH floor from ability use
  (Evisceration 0, Sneak/Trick Attack 1, Accomplice/Collaborator 2);
  their prompt starts at that floor and unanswered kills report
  `{min: floor, exact: false, source: "unknown"}`.
- 2026-09-11a: other players' successful steals and despoils are
  recorded (item only, no failures); quest-swapped steal items noted.
- 2026-09-10d: `/pafo server` removed. The active server comes only from
  detection and is not read back from saved settings.
- 2026-09-10c: `th_plus_item_ids` is derived server-side from item data.
  The earlier hand-written list named Rogue's Armlets (no TH) instead of
  Assassin's Armlets, so self-reported TH read one tier low.
- 2026-09-10b: servers gained an optional `hosts` array; the addon
  auto-detects the active server from the loader's `--server` flag.
- 2026-09-10: `/link` no longer takes a `?code=` prefill. The addon
  opens the bare `verify_url` and the user types `user_code`.
- 2026-09-02b: auth switched to PSXI's existing shared device flow
  (`POST /auth/device` with `kind: "pafo"`, poll `POST /auth/token` with
  `device_code`; 200 + `authorization_pending` while waiting). The
  previous draft's `/api/pafo/device` + `poll_secret` endpoints do not
  exist. Token prefix is `pafo_`.
- 2026-09-02a: battlefield events gained `crate_actor_id` (required when
  a crate is observed) so simultaneous runs in adjacent arenas do not
  merge.

## 11. Non-goals (v1)

- No packet transmission to game servers, no automation, no in-game UI
  beyond the prompt/status lines and the small config window.
- No local drop-rate display (the website is the display surface).
- No capture of fishing, gathering, or chests/coffers.
