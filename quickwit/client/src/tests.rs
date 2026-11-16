use super::*;
use arrow_array::builder::{MapBuilder, StringBuilder};
use arrow_array::{StringArray, TimestampNanosecondArray};
use std::io::{BufRead, BufReader, Read};
use std::net::{TcpListener, TcpStream};

fn args() -> Args {
    Args {
        files: vec![],
        url: String::new(),
        index: "otel_logs".into(),
        threads: 4,
        batch_size: 2000,
        backoff_max: 0.001,
        max_retries: 2,
        request_timeout_secs: 1,
        dump_dir: None,
        row_groups: None,
    }
}

fn respond(mut stream: TcpStream, status: u16) {
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut reader = BufReader::new(&stream);
    let mut length = 0;
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0);
        if line == "\r\n" {
            break;
        }
        if let Some(value) = line.to_lowercase().strip_prefix("content-length:") {
            length = value.trim().parse().unwrap();
        }
    }
    let mut body = vec![0; length];
    reader.read_exact(&mut body).unwrap();
    assert_eq!(body, b"{}\n");
    drop(reader);
    write!(
        stream,
        "HTTP/1.1 {status} Test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    )
    .unwrap();
}

fn server(statuses: Vec<u16>) -> (String, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!(
        "http://{}/api/v1/otel_logs/ingest",
        listener.local_addr().unwrap()
    );
    listener.set_nonblocking(true).unwrap();
    let handle = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        for status in statuses {
            loop {
                match listener.accept() {
                    Ok((stream, _)) => {
                        respond(stream, status);
                        break;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(
                            Instant::now() < deadline,
                            "client did not send expected request"
                        );
                        std::thread::sleep(Duration::from_millis(2));
                    }
                    Err(e) => panic!("{e}"),
                }
            }
        }
    });
    (url, handle)
}

fn send(url: &str, a: &Args, cancelled: &AtomicBool) -> (Result<()>, u64) {
    let retries = AtomicU64::new(0);
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(1))
        .build();
    let result = post(
        &agent,
        url,
        b"{}\n",
        a,
        &mut 1,
        &retries,
        &AtomicU64::new(0),
        cancelled,
    );
    (result, retries.load(Ordering::Relaxed))
}

#[test]
fn timestamp_rename_nulls_and_unknown_columns() {
    let batch = RecordBatch::try_from_iter(vec![
        (
            "timestamp",
            Arc::new(TimestampNanosecondArray::from(vec![
                Some(1_700_000_000_123_456_789),
                None,
            ])) as ArrayRef,
        ),
        (
            "body",
            Arc::new(StringArray::from(vec![Some("hello\nworld"), None])) as ArrayRef,
        ),
        (
            "TimestampTime",
            Arc::new(Int64Array::from(vec![1, 2])) as ArrayRef,
        ),
    ])
    .unwrap();
    let actual = String::from_utf8(to_ndjson(&batch).unwrap()).unwrap();
    assert_eq!(actual, "{\"Timestamp\":1700000000123,\"Body\":\"hello\\nworld\"}\n{\"Timestamp\":null,\"Body\":null}\n");
}

#[test]
fn map_metadata_is_a_json_object() {
    let mut builder = MapBuilder::new(None, StringBuilder::new(), StringBuilder::new());
    builder.keys().append_value("service.name");
    builder.values().append_value("checkout");
    builder.append(true).unwrap();
    let batch = RecordBatch::try_from_iter(vec![(
        "resourceattributes",
        Arc::new(builder.finish()) as ArrayRef,
    )])
    .unwrap();
    assert_eq!(
        String::from_utf8(to_ndjson(&batch).unwrap()).unwrap(),
        "{\"ResourceAttributes\":{\"service.name\":\"checkout\"}}\n"
    );
}

#[test]
fn four_workers_process_each_row_group_once() {
    use parquet::arrow::ArrowWriter;
    use parquet::file::properties::WriterProperties;
    let root = std::env::temp_dir().join(format!(
        "qw-client-test-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("part_000.parquet");
    let batch = RecordBatch::try_from_iter(vec![(
        "Body",
        Arc::new(StringArray::from_iter_values(
            (0..8).map(|i| format!("doc-{i}")),
        )) as ArrayRef,
    )])
    .unwrap();
    let properties = WriterProperties::builder()
        .set_max_row_group_size(2)
        .build();
    let mut writer = ArrowWriter::try_new(
        File::create(&path).unwrap(),
        batch.schema(),
        Some(properties),
    )
    .unwrap();
    writer.write(&batch).unwrap();
    writer.close().unwrap();
    let mut a = args();
    a.dump_dir = Some(root.join("dump"));
    a.batch_size = 1;
    assert_eq!(process_file(&a, &path).unwrap(), 8);
    let mut documents = Vec::new();
    let groups: Vec<_> = std::fs::read_dir(root.join("dump/part_000"))
        .unwrap()
        .collect();
    assert_eq!(groups.len(), 4);
    for group in groups {
        let data = std::fs::read_to_string(group.unwrap().path()).unwrap();
        documents.extend(data.lines().map(str::to_owned));
    }
    documents.sort();
    let expected: Vec<_> = (0..8)
        .map(|i| format!("{{\"Body\":\"doc-{i}\"}}"))
        .collect();
    assert_eq!(documents, expected);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn temporary_overload_retries_then_succeeds() {
    let (url, handle) = server(vec![503, 200]);
    let (result, retries) = send(&url, &args(), &AtomicBool::new(false));
    handle.join().unwrap();
    assert!(result.is_ok());
    assert_eq!(retries, 1);
}

#[test]
fn persistent_overload_has_finite_retry_budget() {
    let (url, handle) = server(vec![429, 503, 503]);
    let (result, retries) = send(&url, &args(), &AtomicBool::new(false));
    handle.join().unwrap();
    assert!(result.unwrap_err().to_string().contains("after 3 attempts"));
    assert_eq!(retries, 2);
}

#[test]
fn permanent_http_error_is_not_retried() {
    let (url, handle) = server(vec![400]);
    let (result, retries) = send(&url, &args(), &AtomicBool::new(false));
    handle.join().unwrap();
    assert!(result.unwrap_err().to_string().contains("HTTP 400"));
    assert_eq!(retries, 0);
}

#[test]
fn connection_refusal_has_finite_retry_budget() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    let (result, retries) = send(&url, &args(), &AtomicBool::new(false));
    assert!(result.unwrap_err().to_string().contains("after 3 attempts"));
    assert_eq!(retries, 2);
}

#[test]
fn cancellation_prevents_sending() {
    let (result, retries) = send("http://127.0.0.1:1", &args(), &AtomicBool::new(true));
    assert!(result.unwrap_err().to_string().contains("cancelled"));
    assert_eq!(retries, 0);
}
