# High availability design (0.3.0 blueprint)

This is the design of record for multi-node barrel_xet, the 0.3.0
milestone. Read it when you want to know how clustering will work and why
the pieces are shaped the way they are. Nothing here is implemented in
0.2.0: this milestone shipped single-node hardening and the seams that make
the design below tractable. Treat it as a decision document, reviewed like
any code change; the implementation lands task by task in 0.3.0.

## Goal and non-goals

The goal is a cluster that keeps serving reads and writes when one node is
lost, with no data loss for anything the client saw acknowledged. Content
addressing does most of the hard work: xorbs and files are named by their
hash, so the same upload to two nodes produces the same bytes under the
same key. Replication is therefore about propagating *metadata* and making
*blobs* reachable, not about reconciling conflicting writes.

Non-goals for 0.3.0: geo-distribution with partition tolerance as a
first-class mode, per-tenant sharding, and online resharding. The first
cluster targets a single failure domain (one region, low-latency links).

## The two tiers

A CAS node is two independent stores behind behaviours:

- `xet_metadata` (`src/xet_metadata.erl`): files, xorb layouts, the dedup
  chunk index, the key ring, the URL secret, aggregate counters. Small,
  write-ordered, consistency-critical.
- `xet_blob_store` (`src/xet_blob_store.erl`): the serialized xorb bytes.
  Large, immutable, content-addressed, reachable by hash.

They fail over differently and are designed separately.

## Metadata replication: the decision

Three options were weighed against the actual behaviour callbacks.

**A. An operation log at the `xet_metadata` behaviour level (chosen).**
Every mutation is already one of a small, closed set of callbacks:
`register_xorb`, `register_files`, `put_key_ring`, `put_url_secret`,
`delete_file`, `delete_xorb`. The registers are idempotent and
content-addressed: replaying `register_xorb` for a hash that exists is a
no-op, and two nodes that both register the same xorb converge. So a
replicated append-only op-log, applied in order on each node, reaches the
same state everywhere without conflict resolution. Deletes are the only
non-commutative case and are handled with tombstones (below).

**B. A natively replicated backend behind the behaviour** (a distributed
KV, or rocksdb with an external replication sidecar). Rejected as the
primary path: it moves the consistency contract out of our code into an
operational dependency, and the behaviour is small enough that owning the
op-log is cheaper than operating a second clustered database.

**C. Consensus (ra/khepri) for the metadata tier.** Not a dependency today
(verified: no `ra`/`khepri` in `rebar.config`). Strong ordering is
attractive, but full Raft on the write path taxes the common case
(idempotent, commuting registers) for a guarantee only deletes and the key
ring actually need. The design uses consensus narrowly (see membership),
not as the metadata store.

Decision: op-log replication at the behaviour boundary, with a small
consensus-backed control plane for membership and the few
linearizability-sensitive keys.

## Op-log model

Each node owns a local `xet_metadata` (rocksdb) as its materialized state,
plus a durable, ordered op-log. A write:

1. Appends the op to the log with a per-origin sequence number.
2. Applies it locally (the existing sync batch).
3. Ships it to peers, which apply it idempotently in origin order.

Properties that make this safe:

- **Registers commute.** `register_xorb`/`register_files` are keyed by
  content hash; order among distinct hashes does not matter, and re-apply
  is a no-op. Peers can apply logs from different origins interleaved.
- **Deletes need tombstones.** `delete_file`/`delete_xorb` do not commute
  with a concurrent re-register of the same hash. Model a delete as a
  tombstone carrying the origin sequence; a later register with a higher
  sequence wins (re-upload self-heals), a stale delete replayed after a
  register is dropped. Tombstones are reaped after the GC grace window.
- **Counters are derived, not shipped.** The aggregate counters
  (`bytes_on_disk`, `xorbs`, `files`) are recomputed from applied ops per
  node, never replicated as deltas, so a replayed op cannot double-count.

The op-log is the same shape the backup story already implies: `checkpoint`
gives a consistent metadata snapshot, and a new node bootstraps from a
peer's checkpoint plus the log tail since that checkpoint.

## Blob tier

Blob availability is per backend, because the backends already differ:

- **S3 / Garage: shared and done.** All nodes point at one bucket; a blob
  written by any node is readable by all, and reconstruction already hands
  clients presigned bucket URLs directly. For clusters this is the
  recommended and lowest-effort backend. The only cross-node concern is the
  commit-order invariant (blob first, then metadata), which already holds.
- **Filesystem: replicate or restrict.** A node-local `xet_store_fs` is not
  shared. Two paths for 0.3.0: (a) document the FS backend as single-node
  only and require S3 for clusters, or (b) add a blob replication pass that
  ships newly written xorbs to peers (pull on miss plus background
  anti-entropy, keyed by hash, so it is a safe read-repair). Recommendation:
  ship (a) first (S3-for-clusters), design (b) as a follow-on so FS
  clusters are possible but not the default.

Because blobs are immutable and content-addressed, blob replication is
never a conflict: a node that lacks a blob fetches it by hash from any peer
that has it, and the bytes are self-verifying.

## Dedup key ring and URL secret

Two pieces of shared secret state must be identical cluster-wide, or the
cluster silently misbehaves:

- **The chunk hash key ring** (`xet_keys`, persisted via
  `get_key_ring`/`put_key_ring`). Dedup responses hash chunk boundaries
  under this key; if two nodes use different keys, a client's dedup probe
  against node A does not match data stored under node B's key, and dedup
  quietly stops working across nodes. The ring must be a single
  cluster-wide value with coordinated rotation: it is exactly the kind of
  rarely-written, must-be-linearizable key that belongs in the
  consensus-backed control plane, not in the commuting op-log.
- **The URL secret** (`get_url_secret`/`put_url_secret`). Single-node
  0.2.0 generates and persists it per node. In a cluster a signed `/data`
  URL issued by one node must verify on another, so the secret must be
  explicit and identical everywhere: `BARREL_XET_URL_SECRET` becomes
  required for FS clusters (S3 clusters do not sign `/data` URLs). Fail
  the boot if a cluster member has no explicit secret.

## Membership and transport

0.2.0 binds Erlang distribution to loopback
(`inet_dist_use_interface {127,0,0,1}` in `vm.args.src`) and ships no
cookie, which is correct for a single node but blocks clustering. 0.3.0:

- Bind distribution to a real interface, keep it on a private network, and
  set a shared cookie out of band (or move to TLS distribution). The
  hardening guide already treats the dist port as trusted-network only;
  clustering makes that a hard requirement.
- Run a small consensus group (candidate: `ra`) as the control plane for
  membership, the key ring, and delete-tombstone ordering. Keep it off the
  bulk write path; it coordinates the few values that need a total order.
- Node discovery via static config first (list of peers), matching the
  existing `livery_client_discover_static` posture on the client side.

## Failover semantics

- **Reads** survive any single node: with S3 blobs, every node can serve
  every read once it has applied the file's metadata op. During the brief
  window before an op propagates, a read on a lagging node returns
  not-found, which clients already retry.
- **Writes** survive a node loss because the op-log is replicated before
  ack: acknowledge a write only after it is durably logged on a quorum of
  metadata replicas. A node that dies mid-upload leaves an orphan blob (no
  committed metadata), reclaimed by the existing GC orphan sweep.
- **Split brain** is bounded by the control plane: registers keep
  committing on both sides of a partition (they commute and re-merge on
  heal), while deletes and key-ring rotation require the consensus quorum
  and stall on the minority side rather than diverge.

## Garbage collection in a cluster

GC stays single-writer to avoid a node sweeping a blob another node just
referenced:

- One node holds the GC role (granted by the control plane, released on
  failure). Only it runs mark-and-sweep and the orphan pass.
- The grace window becomes cluster-wide: a candidate is collectable only if
  it is unreferenced in the merged metadata *and* older than grace *and*
  no op-log has referenced it since mark start on any origin. The existing
  `xet_gc_guard` registration guard generalizes to "referenced since mark"
  across the replicated log.
- Blob deletes still happen after the metadata delete commits, so a
  half-swept node re-heals from peers.

## Client endpoint balancing

The client already has the layers: `livery_client_balance`,
`livery_client_discover`, and a circuit breaker
(`livery_client_circuit_store`). 0.3.0 wires `xet_client` to take a list of
endpoints and balance across them, with the circuit breaker shedding a
failed node. Because any node serves any read (shared or replicated blobs)
and dedup is key-ring-consistent, the client needs no affinity: it can
spray requests and retry elsewhere on 5xx, which it does today for a single
endpoint.

## Rollout and upgrade

- **Bootstrap** a new node from a peer checkpoint plus the log tail, then
  admit it to the membership group.
- **Rolling upgrade**: drain one node at a time (the 0.2.0 graceful-drain
  path already refuses new connections and finishes in-flight requests),
  upgrade, rejoin, let it catch up on the log before draining the next.
  The op-log schema carries a version so a mixed-version cluster applies
  ops it understands and rejects ones it does not, rather than corrupting
  state.
- **Schema changes** to metadata values stay additive under the existing
  1-byte version envelope, so a lagging node reads a newer node's records.

## Open questions for implementation

- Op-log transport and durability: reuse rocksdb (a dedicated CF as the
  log) versus a purpose-built segment log; retention past the last common
  checkpoint.
- Whether `ra` is worth the dependency for the narrow control plane, or a
  simpler leader-lease over Erlang distribution suffices for the first
  cluster.
- Quorum size and write-latency budget for the acknowledged-write path.
- FS blob replication (anti-entropy cadence, read-repair) versus shipping
  S3-only clustering in 0.3.0 and FS clustering later.

## 0.3.0 milestones (proposed)

1. Op-log CF + replay, single-origin (no network): local durability and
   idempotent re-apply, proven by restart-from-log tests.
2. Peer transport + apply, static membership, registers only.
3. Delete tombstones and the consensus-backed control plane (membership,
   key ring, URL secret).
4. Cluster GC role and cluster-wide grace.
5. Client multi-endpoint balancing.
6. FS blob replication (or the documented S3-only decision) and the
   bootstrap/upgrade runbook.
