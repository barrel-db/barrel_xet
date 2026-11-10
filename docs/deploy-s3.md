# Deploy the server with S3 storage

This guide runs the CAS server with xorb blobs in an S3-compatible bucket
(AWS S3, Garage, RustFS, MinIO, Ceph) instead of the local filesystem. Use
it when you want object storage and CDN-frontable, presigned download URLs.
rocksdb still holds the metadata locally.

S3 is optional. Without a `blob` setting the server stores blobs on the
filesystem under `data_dir`, and nothing here applies.

## When to use

Filesystem storage (the default) keeps blobs on the server's disk and
serves ranges through a signed self URL. The S3 backend stores blobs in a
bucket and hands clients **presigned GET URLs**, so downloads can bypass
the server entirely and ride a CDN.

## Configure

Set `blob => {s3, ...}` in the `server` map (`config/sys.config.src`):

```erlang
{server, #{
    name => barrel_xet,
    data_dir => "/var/lib/barrel_xet",   %% rocksdb metadata still lives here
    http => #{port => 8080},
    blob => {s3, #{
        bucket => <<"my-xet-bucket">>,
        s3 => #{
            endpoint => <<"https://s3.eu-west-1.amazonaws.com">>,
            region => <<"eu-west-1">>,
            access_key_id => <<"...">>,
            secret_access_key => <<"...">>
        }
    }},
    url_ttl => 900,   %% presigned URL lifetime in seconds
    auth => {xet_auth_static, #{tokens => #{<<"write-token">> => write}}}
}}
```

For Garage or MinIO, point `endpoint` at the local server (e.g.
`<<"http://127.0.0.1:3900">>`) and keep `region` matching its config.

The `BARREL_XET_*` environment variables, the Docker image, and the
systemd and FreeBSD service files from
[Deploy the CAS server](deploy-server.md) apply unchanged: only the
`blob` map differs. The S3 credentials are not environment variables, so
keep them in the config file (or your own secret store) with `0600`
permissions. S3 deployments do not use `BARREL_XET_URL_SECRET`.

### Retries

Object puts retry transient S3 failures (HTTP 429 and 5xx, connect and
timeout errors) automatically, since a xorb upload sends the whole
object as one replayable body. Tune the defaults through the `s3` map:

```erlang
s3 => #{
    %% ...credentials...
    retry => #{max => 3, backoff => {200, 2.0}}
}
```

`max` is the retry count and `backoff` is `{BaseMs, Factor}` for
exponential backoff. Streamed puts are not retried, but the server
always uploads xorbs as full binaries.

## Verify against Garage or RustFS

Two single-node stores in Docker are the integration targets. Each script
prints the `XET_S3_*` variables to export:

```sh
bash test/docker/garage-up.sh     # Garage on :3910
bash test/docker/rustfs-up.sh     # RustFS on :3920
```

With the variables exported, the `live` group of the S3 suite runs the
blob-store operations and a full server roundtrip (upload through the
API, download through presigned URLs):

```sh
rebar3 ct --suite=xet_store_s3_SUITE
```

Stop the stores when done:

```sh
bash test/docker/garage-down.sh
bash test/docker/rustfs-down.sh
```

Without `XET_S3_ENDPOINT` the `live` group is skipped; the rest of the
suite runs against an in-memory fake.

## Notes

- Uploads are validated in full on the server before the blob is written,
  so an invalid xorb never reaches the bucket.
- The signed-data endpoint (`/api/v1/xorbs/{ns}/{hash}/data`) is not used
  with S3; reconstruction returns bucket presigned URLs directly.
- Presigned URLs set the response `Cache-Control` to
  `public, immutable, max-age=<URL lifetime>`, so a CDN or proxy never
  serves the bytes past it (spec 13.6.1). Objects carry no stored
  `Cache-Control`: Garage ignores the override on ranged GETs, and a
  stored long `max-age` would then outlive the URL. Ranged responses
  from Garage therefore have no `Cache-Control`; RustFS applies the
  override to them too.
- S3 computes object ETags itself (an MD5 digest), so the `ETag` is not
  the xorb hash as it is on the filesystem backend. Clients verify chunks
  by hash anyway.
