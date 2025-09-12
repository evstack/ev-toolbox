reth-dump-alloc
================

CLI to dump a Reth node's latest plain state into a genesis alloc and optionally merge it into a new genesis.json.

Status: initial implementation, single-threaded, streaming JSON writer. Parallelism/chunking TODO.

Commands

- `reth-dump-alloc`:
  - `--datadir <PATH>`: Path to Reth datadir (or `.../db`).
  - `--out <FILE>`: Output path (default: `alloc.json`).
  - `--zero-out-empty-EOAs` (flag): Include zeroed EOAs in output (default: skip them).
  - `--parallel`, `--chunk-bytes`: Accepted but not implemented yet.

  Output shape:

  {
    "alloc": {
      "0x...": { "balance": "0x...", "nonce": "0x...", "code": "0x...", "storage": {"0xslot": "0xvalue"} },
      ...
    }
  }

- `genesis-merge`:
  - `--base <FILE>`: Base genesis template (your chain config/consensus fields).
  - `--alloc <FILE>`: Alloc JSON; accepts either a plain object or `{ "alloc": { ... } }`.
  - `--out <FILE>`: Output merged genesis path (default: `genesis.merged.json`).

Notes

- Reads Reth plain state tables at head: `PlainAccountState`, `Bytecodes`, `PlainStorageState`.
- Storage keys/values are 32-byte left‑padded hex.
- Skips code/storage fields when empty; skips zeroed EOAs unless `--zero-out-empty-EOAs`.
- If your Reth datadir is `/path/to/reth`, point `--datadir` there; the tool will use `/path/to/reth/db` automatically if present.

Build

This crate depends on `reth-*` crates. Ensure you can fetch crates from your registry, then:

  cargo build --release

Usage example

  reth-dump-alloc --datadir /data/reth --out alloc.json
  genesis-merge --base genesis.template.json --alloc alloc.json --out genesis.json

