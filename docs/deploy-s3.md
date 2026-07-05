# Deploy the server with S3 storage

This guide runs the CAS server with xorb blobs in an S3-compatible bucket
(AWS S3, Garage, MinIO, Ceph) instead of the local filesystem. Use it when
you want object storage and CDN-frontable, presigned download URLs. rocksdb
still holds the metadata locally.

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

## Verify against Garage

A single-node Garage in Docker is the integration target:

```sh
sh test/docker/garage-up.sh     # prints endpoint/keys/bucket to export
# ... set the server's blob config to those values, start the server ...
sh test/docker/garage-down.sh
```

The `xet_store_s3` CT suite runs the same operations against Garage when
`XET_S3_ENDPOINT` is set.

## Notes

- Uploads are validated in full on the server before the blob is written,
  so an invalid xorb never reaches the bucket.
- The signed-data endpoint (`/api/v1/xorbs/{ns}/{hash}/data`) is not used
  with S3; reconstruction returns bucket presigned URLs directly.
