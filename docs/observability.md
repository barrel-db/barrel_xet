# Observability

This guide covers the metrics, logs, and traces the CAS server emits, and
how to collect them. Use it when you set up monitoring for a deployment.

## Metrics

The server records metrics into the `instrument` registry. Two ways to
collect them, sharing the same registry:

- **Prometheus** scrapes `GET /metrics`.
- **OTLP** push exports on an interval to a collector.

### Prometheus

`GET /metrics` returns the registry in Prometheus text format. It is
served under the `read` scope (metrics reveal request paths and data
volumes), so scrape with a bearer token:

```yaml
scrape_configs:
  - job_name: barrel_xet
    authorization:
      credentials: <read-or-write-token>
    static_configs:
      - targets: ["barrel-xet-host:8080"]
```

Set `metrics => false` in the server map to remove the endpoint.

Metric names follow OpenTelemetry semantic conventions and keep their
dots (for example `http.server.request.duration`). Prometheus 3.x
scrapes these UTF-8 names as-is; older scrapers need dots rewritten to
underscores at the scrape layer.

### OTLP push

The `instrument` app auto-registers exporters from the standard `OTEL_*`
environment variables at boot, with no code or config change:

```sh
export OTEL_METRICS_EXPORTER=otlp
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_ENDPOINT=http://collector:4317
```

Traces carry one server span per request (W3C `traceparent` is honored
for propagation).

### Inventory

HTTP (from the livery middleware), labeled by method, status, protocol,
and scheme:

| Metric | Type |
|---|---|
| `http.server.active_requests` | up/down counter |
| `http.server.request.duration` | histogram (seconds) |

Domain (from `xet_metrics`):

| Metric | Type | Labels |
|---|---|---|
| `xet.xorbs.uploaded` | counter | |
| `xet.xorbs.uploaded.bytes` | counter | |
| `xet.xorbs.dedup_hits` | counter | |
| `xet.shards.registered` | counter | |
| `xet.files.registered` | counter | |
| `xet.spool.spilled` | counter | |
| `xet.store.op.duration` | histogram (seconds) | `backend`, `op` |
| `xet.store.write.bytes` | counter | `backend` |
| `xet.store.read.bytes` | counter | `backend` |
| `xet.chunks.queries` | counter | |
| `xet.chunks.hits` | counter | |

`backend` is `fs` or `s3`; `op` is `put`, `get_range`, or `delete`. The
FS data endpoint streams files directly, so its reads do not appear in
`xet.store.read.bytes` (that counter reflects `get_range` calls).

## Logs

The server emits one structured access-log line per request at `notice`
level (method, path, status, duration, request id), plus `error`/
`warning` lines on failure paths. Set `access_log => false` to turn the
access log off.

Every log event carries the client's `X-Xet-Session-Id` as `session_id`
metadata, and, while a request span is active, `trace_id` and `span_id`,
so logs join with traces. The access line also includes its own
`request_id` field.

### File logging with rotation

By default logs go to the node's default handler. To also write them to
a rotating file, uncomment the `logger` block in `config/sys.config.src`
(see below) and set the path. It uses `logger_std_h` with a 10 MiB size
cap and 5 rotated files, and a formatter template that surfaces
`session_id` and `trace_id`.
