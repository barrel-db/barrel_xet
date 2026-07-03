# Golden test fixtures

Files copied from the XET protocol reference dataset
[xet-team/xet-spec-reference-files](https://huggingface.co/datasets/xet-team/xet-spec-reference-files)
(Apache-2.0). They pin the output of the reference implementation for one real
input file, `Electric_Vehicle_Population_Data_20250917.csv` (63 MB, from
data.wa.gov).

Vendored here (small):

- `*.chunk` - raw bytes of the first three chunks of the CSV; each filename is
  the chunk hash in XET string format
- `Electric_Vehicle_Population_Data_20250917.csv.chunks` - `<chunk hash> <length>`
  per line, in file order (796 chunks)
- `Electric_Vehicle_Population_Data_20250917.csv.shard*` - shard for the file:
  stored form, with verification entries, upload form (`verification-no-footer`),
  and a dedupe-response form
- `Electric_Vehicle_Population_Data_20250917.csv.xet-file-hash` /
  `.xet-xorb-hash` - expected file and xorb hashes, XET string format
- `eea25d6...b7632.xorb.chunks` / `.xorb.range-hash` - chunk listing and range
  verification hash of the xorb

Not vendored (fetched by `make fixtures` into `large/`, gitignored):

- `Electric_Vehicle_Population_Data_20250917.csv` (63 MB source file)
- `eea25d6...b7632.xorb` (14.7 MB serialized xorb)

Test groups that need the large files skip themselves when `large/` is absent.
