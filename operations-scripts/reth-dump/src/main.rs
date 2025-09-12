use std::{
    fs::File,
    io::{BufWriter, Write},
    path::{Path, PathBuf},
};

use clap::Parser;
use eyre::WrapErr;
use serde::Serialize;

use reth_db::cursor::{DbCursorRO, DbDupCursorRO};
use reth_db::{open_db_read_only, tables, transaction::DbTx, Database};
use std::fmt::LowerHex;

#[derive(Parser, Debug, Clone)]
#[command(
    name = "reth-dump-alloc",
    version,
    about = "Dump Reth plain state into genesis alloc"
)]
struct Args {
    #[arg(
        long,
        value_name = "PATH",
        help = "Path to Reth datadir (or its db subdir)"
    )]
    datadir: PathBuf,

    #[arg(
        long,
        value_name = "FILE",
        default_value = "alloc.json",
        help = "Output JSON path"
    )]
    out: PathBuf,

    #[arg(
        long,
        default_value_t = true,
        help = "Emit zero balance/nonce fields for empty EOAs"
    )]
    zero_out_empty_eoas: bool,

    #[arg(
        long,
        value_name = "N",
        default_value_t = 0usize,
        help = "Parallel workers (reserved)"
    )]
    parallel: usize,

    #[arg(
        long,
        value_name = "BYTES",
        default_value = "0",
        help = "Chunk output size (reserved)"
    )]
    chunk_bytes: String,
}

#[derive(Serialize)]
struct AllocEntry {
    balance: String,
    nonce: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    storage: Option<serde_json::Map<String, serde_json::Value>>,
}

fn hex_u64(n: u64) -> String {
    format!("0x{:x}", n)
}

fn hex_lower<T: LowerHex>(t: T) -> String {
    format!("0x{t:x}")
}

fn hex_pad_64_lower<T: LowerHex>(t: T) -> String {
    let s = format!("{t:x}");
    if s.len() >= 64 {
        return format!("0x{}", s);
    }
    let mut out = String::with_capacity(2 + 64);
    out.push_str("0x");
    for _ in 0..(64 - s.len()) {
        out.push('0');
    }
    out.push_str(&s);
    out
}

fn db_path(datadir: &Path) -> PathBuf {
    let dbdir = datadir.join("db");
    if dbdir.exists() {
        dbdir
    } else {
        datadir.to_path_buf()
    }
}

fn main() -> eyre::Result<()> {
    color_eyre::install().ok();

    let args = Args::parse();
    if args.parallel > 0 {
        eprintln!("parallel not yet implemented; proceeding single-threaded");
    }
    if args.chunk_bytes != "0" {
        eprintln!("chunked output not yet implemented; writing single file");
    }

    let dbdir = db_path(&args.datadir);

    let env = open_db_read_only(&dbdir, Default::default())
        .wrap_err_with(|| format!("opening MDBX env at {}", dbdir.display()))?;
    let tx = env.tx().wrap_err("starting read-only tx")?;

    let mut out = BufWriter::new(File::create(&args.out).wrap_err("creating output file")?);
    writeln!(out, "{{\n  \"alloc\": {{").wrap_err("writing header")?;

    let mut first_account = true;

    let mut account_cursor = tx
        .cursor_read::<tables::PlainAccountState>()
        .wrap_err("opening PlainAccountState cursor")?;

    while let Some((addr, acc)) = account_cursor.next().wrap_err("iterating accounts")? {
        let balance_hex = hex_lower(acc.balance);
        let nonce_hex = hex_u64(acc.nonce);

        let code_hex = if let Some(hash) = acc.bytecode_hash {
            match tx.get::<tables::Bytecodes>(hash) {
                Ok(Some(bytecode)) => Some(format!("0x{}", hex::encode(bytecode.bytes()))),
                Ok(None) => Some("0x".to_string()),
                Err(e) => return Err(e).wrap_err("reading Bytecodes table"),
            }
        } else {
            None
        };

        let mut storage_map: serde_json::Map<String, serde_json::Value> = Default::default();

        let mut storage_cursor = tx
            .cursor_read::<tables::PlainStorageState>()
            .wrap_err("opening PlainStorageState cursor")?;

        if let Some((current_addr, mut entry)) = storage_cursor
            .seek(addr)
            .wrap_err("seeking storage for address")?
        {
            if current_addr == addr {
                loop {
                    let slot_hex = hex_pad_64_lower(entry.key);
                    let value_hex = hex_pad_64_lower(entry.value);
                    storage_map.insert(slot_hex, serde_json::Value::String(value_hex));
                    if let Some((_, e)) = storage_cursor
                        .next_dup()
                        .wrap_err("iterating storage dup")?
                    {
                        entry = e;
                    } else {
                        break;
                    }
                }
            }
        }

        let storage_opt = if storage_map.is_empty() {
            None
        } else {
            Some(storage_map)
        };

        if !(args.zero_out_empty_eoas) {
            let is_empty_eoa = code_hex.is_none()
                && storage_opt.is_none()
                && balance_hex == "0x0"
                && nonce_hex == "0x0";
            if is_empty_eoa {
                continue;
            }
        }

        if !first_account {
            writeln!(out, ",").wrap_err("writing entry separator")?;
        }
        first_account = false;

        let entry = AllocEntry {
            balance: balance_hex,
            nonce: nonce_hex,
            code: code_hex,
            storage: storage_opt,
        };

        let addr_hex = format!("0x{}", hex::encode(addr.as_slice()));
        write!(out, "    \"{}\": ", addr_hex).wrap_err("writing entry key")?;
        write!(out, "{}", serde_json::to_string(&entry)?).wrap_err("writing entry value")?;
    }

    writeln!(out, "\n  }}\n}}").wrap_err("finalizing output")?;
    out.flush().ok();

    Ok(())
}
