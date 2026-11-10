// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Benoit Chesneau
//
// Answers lookups on a shard written by barrel_xet through xet-core's
// shard reader, which seeks through the footer's lookup tables. One JSON
// line per query on stdout:
//
//   xetcore-check <shard> file:<hex> xorb:<hex> chunk:<hex> ...
//
// file  -> {"file":H,"terms":[[xorb,start,end,bytes],...]} or null terms
// xorb  -> {"xorb":H,"found":xorb hash read at the indexed entry, chunks}
// chunk -> {"chunk":H,"xorb":X,"start":S,"end":E} (dedup query) or nulls
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};

use xet_core_structures::merklehash::MerkleHash;
use xet_core_structures::metadata_shard::MDBShardInfo;
use xet_core_structures::metadata_shard::xorb_structs::XorbChunkSequenceHeader;

const ENTRY_SIZE: u64 = 48;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: xetcore-check <shard> (file|xorb|chunk):<hex>...");
        std::process::exit(2);
    }
    let mut reader = BufReader::new(File::open(&args[1]).expect("open shard"));
    let info = MDBShardInfo::load_from_reader(&mut reader).expect("load shard");
    for query in &args[2..] {
        let (kind, hex) = query.split_once(':').expect("kind:hex");
        let hash = MerkleHash::from_hex(hex).expect("hex hash");
        let line = match kind {
            "file" => file_query(&info, &mut reader, &hash),
            "xorb" => xorb_query(&info, &mut reader, &hash),
            "chunk" => chunk_query(&info, &mut reader, &hash),
            other => panic!("unknown query kind {other}"),
        };
        println!("{line}");
    }
}

fn file_query<R: Read + Seek>(info: &MDBShardInfo, reader: &mut R, hash: &MerkleHash) -> String {
    match info.get_file_reconstruction_info(reader, hash).expect("file lookup") {
        Some(file) => {
            let terms: Vec<String> = file
                .segments
                .iter()
                .map(|s| {
                    format!(
                        "[\"{}\",{},{},{}]",
                        s.xorb_hash.hex(),
                        s.chunk_index_start,
                        s.chunk_index_end,
                        s.unpacked_segment_bytes
                    )
                })
                .collect();
            format!("{{\"file\":\"{}\",\"terms\":[{}]}}", hash.hex(), terms.join(","))
        },
        None => format!("{{\"file\":\"{}\",\"terms\":null}}", hash.hex()),
    }
}

// The xorb table gives an entry index; reading the header there must
// yield the queried hash, as xet-core's own readers assume.
fn xorb_query<R: Read + Seek>(info: &MDBShardInfo, reader: &mut R, hash: &MerkleHash) -> String {
    let mut indices = [0u32; 8];
    let n = info.get_xorb_info_index_by_hash(reader, hash, &mut indices).expect("xorb lookup");
    for &index in indices.iter().take(n) {
        reader
            .seek(SeekFrom::Start(info.metadata.xorb_info_offset + ENTRY_SIZE * index as u64))
            .expect("seek");
        let header = XorbChunkSequenceHeader::deserialize(reader).expect("xorb header");
        if header.xorb_hash == *hash {
            return format!(
                "{{\"xorb\":\"{}\",\"found\":\"{}\",\"chunks\":{}}}",
                hash.hex(),
                header.xorb_hash.hex(),
                header.num_entries
            );
        }
    }
    format!("{{\"xorb\":\"{}\",\"found\":null,\"chunks\":null}}", hash.hex())
}

fn chunk_query<R: Read + Seek>(info: &MDBShardInfo, reader: &mut R, hash: &MerkleHash) -> String {
    match info.chunk_hash_dedup_query(reader, &[*hash]).expect("chunk lookup") {
        Some((_, entry)) => format!(
            "{{\"chunk\":\"{}\",\"xorb\":\"{}\",\"start\":{},\"end\":{}}}",
            hash.hex(),
            entry.xorb_hash.hex(),
            entry.chunk_index_start,
            entry.chunk_index_end
        ),
        None => format!("{{\"chunk\":\"{}\",\"xorb\":null,\"start\":null,\"end\":null}}", hash.hex()),
    }
}
