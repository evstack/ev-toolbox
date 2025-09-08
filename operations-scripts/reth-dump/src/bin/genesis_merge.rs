use std::{fs, path::PathBuf};

use clap::Parser;
use eyre::{bail, Context};
use serde_json::{Map, Value};

#[derive(Parser, Debug, Clone)]
#[command(
    name = "genesis-merge",
    version,
    about = "Merge base genesis with an alloc dump"
)]
struct Args {
    #[arg(long, value_name = "FILE", help = "Base genesis.json path")]
    base: PathBuf,

    #[arg(
        long,
        value_name = "FILE",
        help = "Alloc JSON path (map or {alloc:{}})"
    )]
    alloc: PathBuf,

    #[arg(
        long,
        value_name = "FILE",
        default_value = "genesis.merged.json",
        help = "Output genesis path"
    )]
    out: PathBuf,
}

fn extract_alloc(v: Value) -> eyre::Result<Map<String, Value>> {
    match v {
        Value::Object(mut o) => {
            if let Some(a) = o.remove("alloc") {
                match a {
                    Value::Object(m) => Ok(m),
                    _ => bail!("alloc field is not an object"),
                }
            } else {
                Ok(o)
            }
        }
        _ => bail!("alloc JSON must be an object or an object with an 'alloc' field"),
    }
}

fn main() -> eyre::Result<()> {
    color_eyre::install().ok();
    let args = Args::parse();

    let base_s = fs::read_to_string(&args.base).wrap_err("reading base genesis")?;
    let alloc_s = fs::read_to_string(&args.alloc).wrap_err("reading alloc json")?;

    let mut base_v: Value = serde_json::from_str(&base_s).wrap_err("parsing base genesis")?;
    if !base_v.is_object() {
        bail!("base genesis must be a JSON object");
    }
    let alloc_v: Value = serde_json::from_str(&alloc_s).wrap_err("parsing alloc json")?;
    let alloc_map = extract_alloc(alloc_v)?;

    let o = base_v.as_object_mut().unwrap();
    o.insert("alloc".to_string(), Value::Object(alloc_map));

    let pretty = serde_json::to_string_pretty(&base_v)?;
    fs::write(&args.out, pretty).wrap_err("writing merged genesis")?;
    eprintln!("wrote {}", args.out.display());
    Ok(())
}
