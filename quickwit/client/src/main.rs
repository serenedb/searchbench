//! Parquet -> Quickwit ingest API client for SearchBench.
//!
//! Sends the same documents as `quickwit/ingest.py` (same field renames,
//! Timestamp as epoch milliseconds, maps as JSON objects, explicit nulls,
//! 2000-row requests to `/api/v1/<index>/ingest`), but converts with
//! `arrow_json` instead of building a Python dict per row: ingest.py tops out
//! at ~20k docs/s per process, which caps a load before Quickwit does.
//!
//! Work distribution = ingest.py `--order queue`: N threads lease the next row
//! group from a shared counter, so documents reach Quickwit in near time order
//! and splits stay narrow in time.
//!
//! Usage:
//!   qw-parquet-ingest --file part_000.parquet [--file ...] [--url http://localhost:7280]
//!       [--index otel_logs] [--threads 16] [--batch-size 2000] [--backoff-max 30]
//!       [--max-retries 8] [--request-timeout-secs 60]
//!       [--dump-dir DIR [--row-groups 0,1,80]]   # write request bodies instead of sending
use std::fs::File;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use anyhow::{bail, Context, Result};
use arrow_array::cast::AsArray;
use arrow_array::types::Int64Type;
use arrow_array::{ArrayRef, Int64Array, RecordBatch};
use arrow_json::writer::LineDelimited;
use arrow_json::WriterBuilder;
use arrow_schema::{DataType, Field, Schema};
use parquet::arrow::arrow_reader::{
    ArrowReaderMetadata, ArrowReaderOptions, ParquetRecordBatchReaderBuilder,
};

const RENAME: &[(&str, &str)] = &[
    ("timestamp", "Timestamp"),
    ("traceid", "TraceId"),
    ("spanid", "SpanId"),
    ("traceflags", "TraceFlags"),
    ("severitytext", "SeverityText"),
    ("severitynumber", "SeverityNumber"),
    ("servicename", "ServiceName"),
    ("body", "Body"),
    ("resourceschemaurl", "ResourceSchemaUrl"),
    ("resourceattributes", "ResourceAttributes"),
    ("scopeschemaurl", "ScopeSchemaUrl"),
    ("scopename", "ScopeName"),
    ("scopeversion", "ScopeVersion"),
    ("scopeattributes", "ScopeAttributes"),
    ("logattributes", "LogAttributes"),
];

fn canonical(name: &str) -> Option<&'static str> {
    RENAME
        .iter()
        .find(|(from, to)| *from == name || *to == name)
        .map(|(_, to)| *to)
}

struct Args {
    files: Vec<PathBuf>,
    url: String,
    index: String,
    threads: usize,
    batch_size: usize,
    backoff_max: f64,
    max_retries: usize,
    request_timeout_secs: u64,
    dump_dir: Option<PathBuf>,
    row_groups: Option<Vec<usize>>,
}

fn parse_args() -> Result<Args> {
    let mut a = Args {
        files: vec![],
        url: std::env::var("QW_URL").unwrap_or_else(|_| "http://localhost:7280".into()),
        index: std::env::var("QW_INDEX").unwrap_or_else(|_| "otel_logs".into()),
        threads: 16,
        batch_size: 2000,
        backoff_max: 30.0,
        max_retries: 8,
        request_timeout_secs: 60,
        dump_dir: None,
        row_groups: None,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut val = || it.next().with_context(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--file" => a.files.push(val()?.into()),
            "--url" => a.url = val()?,
            "--index" => a.index = val()?,
            "--threads" => a.threads = val()?.parse()?,
            "--batch-size" => a.batch_size = val()?.parse()?,
            "--backoff-max" => a.backoff_max = val()?.parse()?,
            "--max-retries" => a.max_retries = val()?.parse()?,
            "--request-timeout-secs" => a.request_timeout_secs = val()?.parse()?,
            "--dump-dir" => a.dump_dir = Some(val()?.into()),
            "--row-groups" => {
                a.row_groups = Some(
                    val()?
                        .split(',')
                        .map(|s| s.parse())
                        .collect::<Result<_, _>>()?,
                )
            }
            other => bail!("unknown argument {other}"),
        }
    }
    if a.files.is_empty() {
        bail!("at least one --file is required");
    }
    if a.threads == 0 || a.batch_size == 0 || a.request_timeout_secs == 0 {
        bail!("threads, batch-size and request-timeout-secs must be positive");
    }
    if !a.backoff_max.is_finite() || a.backoff_max <= 0.0 {
        bail!("backoff-max must be finite and positive");
    }
    Ok(a)
}

/// One record batch -> one request body (NDJSON), exactly ingest.py's batch_to_ndjson.
fn to_ndjson(batch: &RecordBatch) -> Result<Vec<u8>> {
    let schema = batch.schema();
    let mut fields = Vec::new();
    let mut cols: Vec<ArrayRef> = Vec::new();
    for (i, f) in schema.fields().iter().enumerate() {
        let Some(out) = canonical(f.name()) else {
            continue;
        };
        let col = batch.column(i);
        if let DataType::Timestamp(_, _) = f.data_type() {
            // ingest.py: col.cast(int64) / 1_000_000 -> epoch ms for this ns corpus.
            let ints = arrow_cast::cast(col, &DataType::Int64)?;
            let ms: Int64Array = ints.as_primitive::<Int64Type>().unary(|v| v / 1_000_000);
            fields.push(Field::new(out, DataType::Int64, true));
            cols.push(Arc::new(ms));
        } else {
            fields.push(Field::new(out, f.data_type().clone(), true));
            cols.push(col.clone());
        }
    }
    let out = RecordBatch::try_new(Arc::new(Schema::new(fields)), cols)?;
    let mut buf = Vec::with_capacity(out.num_rows() * 1300);
    {
        let mut w = WriterBuilder::new()
            .with_explicit_nulls(true)
            .build::<_, LineDelimited>(&mut buf);
        w.write(&out)?;
        w.finish()?;
    }
    Ok(buf)
}

fn jitter(seed: &mut u64) -> f64 {
    // xorshift64: 0.5..1.0, keeps the senders from retrying in lockstep.
    *seed ^= *seed << 13;
    *seed ^= *seed >> 7;
    *seed ^= *seed << 17;
    0.5 + (*seed % 1000) as f64 / 2000.0
}

fn post(
    agent: &ureq::Agent,
    url: &str,
    body: &[u8],
    a: &Args,
    seed: &mut u64,
    retries: &AtomicU64,
    logged: &AtomicU64,
    cancelled: &AtomicBool,
) -> Result<()> {
    let mut backoff = 1.0f64.min(a.backoff_max);
    for attempt in 0..=a.max_retries {
        if cancelled.load(Ordering::Relaxed) {
            bail!("ingestion cancelled after another worker failed");
        }
        let failure = match agent
            .post(url)
            .set("Content-Type", "application/x-ndjson")
            .send_bytes(body)
        {
            Ok(_) => return Ok(()),
            Err(ureq::Error::Status(code, resp)) if code == 429 || code == 503 => {
                let text = resp.into_string().unwrap_or_default();
                let failure = format!(
                    "HTTP {code}: {}",
                    text.chars().take(300).collect::<String>()
                );
                if logged.fetch_add(1, Ordering::Relaxed) < 3 {
                    eprintln!("  {failure}");
                }
                failure
            }
            Err(ureq::Error::Status(code, resp)) => {
                bail!("HTTP {code}: {}", resp.into_string().unwrap_or_default());
            }
            Err(e) => format!("request error: {e}"),
        };
        if attempt == a.max_retries {
            bail!(
                "ingest request failed after {} attempts: {failure}",
                attempt + 1
            );
        }
        retries.fetch_add(1, Ordering::Relaxed);
        eprintln!("  retry {}/{}: {failure}", attempt + 1, a.max_retries);
        std::thread::sleep(Duration::from_secs_f64(backoff * jitter(seed)));
        backoff = (backoff * 2.0).min(a.backoff_max);
    }
    unreachable!()
}

fn process_file(a: &Args, path: &PathBuf) -> Result<u64> {
    let meta = ArrowReaderMetadata::load(&File::open(path)?, ArrowReaderOptions::new())?;
    let md = meta.metadata().clone();
    let total_rows: i64 = md.row_groups().iter().map(|rg| rg.num_rows()).sum();
    let rgs: Vec<usize> = a
        .row_groups
        .clone()
        .unwrap_or_else(|| (0..md.num_row_groups()).collect());
    let dump_sub = a
        .dump_dir
        .as_ref()
        .map(|d| d.join(path.file_stem().unwrap()));
    if let Some(d) = &dump_sub {
        std::fs::create_dir_all(d)?;
    }
    println!(
        "{}: {} rows / {} row groups -> {} threads (Rust client, row-group queue){}",
        path.display(),
        total_rows,
        md.num_row_groups(),
        a.threads,
        if dump_sub.is_some() {
            ", dump mode"
        } else {
            ""
        }
    );
    let url = format!("{}/api/v1/{}/ingest", a.url, a.index);
    let next = AtomicUsize::new(0);
    let cancelled = AtomicBool::new(false);
    let (docs, retries, logged) = (AtomicU64::new(0), AtomicU64::new(0), AtomicU64::new(0));
    let t0 = Instant::now();
    std::thread::scope(|s| -> Result<()> {
        let mut handles = Vec::new();
        for t in 0..a.threads {
            let (meta, rgs, url, next, docs, retries, logged, dump_sub, cancelled) = (
                meta.clone(),
                &rgs,
                &url,
                &next,
                &docs,
                &retries,
                &logged,
                &dump_sub,
                &cancelled,
            );
            handles.push(s.spawn(move || -> Result<()> {
                let result = (|| -> Result<()> {
                    let agent = ureq::AgentBuilder::new()
                        .timeout(Duration::from_secs(a.request_timeout_secs))
                        .build();
                    let mut seed = 0x9E3779B97F4A7C15u64
                        ^ (t as u64 + 1)
                        ^ SystemTime::now()
                            .duration_since(SystemTime::UNIX_EPOCH)?
                            .as_nanos() as u64;
                    loop {
                        if cancelled.load(Ordering::Relaxed) {
                            bail!("ingestion cancelled after another worker failed");
                        }
                        let i = next.fetch_add(1, Ordering::Relaxed);
                        let Some(&rg) = rgs.get(i) else { return Ok(()) };
                        let reader = ParquetRecordBatchReaderBuilder::new_with_metadata(
                            File::open(path)?,
                            meta.clone(),
                        )
                        .with_row_groups(vec![rg])
                        .with_batch_size(a.batch_size)
                        .build()?;
                        let mut dump = match dump_sub {
                            Some(d) => Some(File::create(d.join(format!("rg_{rg:05}.ndjson")))?),
                            None => None,
                        };
                        for batch in reader {
                            let batch = batch?;
                            let body = to_ndjson(&batch)?;
                            match dump.as_mut() {
                                Some(f) => f.write_all(&body)?,
                                None => post(
                                    &agent, url, &body, a, &mut seed, retries, logged, cancelled,
                                )?,
                            }
                            docs.fetch_add(batch.num_rows() as u64, Ordering::Relaxed);
                        }
                    }
                })();
                if result.is_err() {
                    cancelled.store(true, Ordering::Relaxed);
                }
                result
            }));
        }
        for h in handles {
            h.join().expect("thread panicked")?;
        }
        Ok(())
    })?;
    let el = t0.elapsed().as_secs_f64();
    let n = docs.load(Ordering::Relaxed);
    println!(
        "File done: {n} docs in {el:.1}s  ({:.0} docs/s), {} retried requests",
        n as f64 / el,
        retries.load(Ordering::Relaxed)
    );
    Ok(n)
}

#[cfg(test)]
mod tests;

fn main() -> Result<()> {
    let a = parse_args()?;
    let t0 = Instant::now();
    let mut grand = 0u64;
    for f in &a.files {
        grand += process_file(&a, f)?;
    }
    let el = t0.elapsed().as_secs_f64();
    println!(
        "\nGrand total: {grand} docs in {el:.1}s  ({:.0} docs/s)",
        grand as f64 / el
    );
    Ok(())
}
