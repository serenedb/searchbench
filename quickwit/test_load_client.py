"""Exercise Rust client selection without Docker or an index server."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class RustClientSelectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.adapter = self.root / "quickwit"
        self.adapter.mkdir()
        shutil.copy(Path(__file__).with_name("load"), self.adapter / "load")
        shutil.copytree(Path(__file__).with_name("config"), self.adapter / "config")
        (self.root / "lib").mkdir()
        # The clients exit before settling; no background merge sampler is needed.
        (self.root / "lib/load-phases.sh").write_text('phases_start() { :; }\n')
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.data = self.root / "data"
        self.data.mkdir()
        (self.data / "part_000.parquet").touch()
        self.calls = self.root / "calls"
        self.env = dict(os.environ, PATH=str(self.bin) + ":" + os.environ["PATH"],
                        SEARCHBENCH_LOAD_CLIENT="rust", SEARCHBENCH_DATA_DIR=str(self.data),
                        MOCK_CALLS=str(self.calls), QW_INGEST="http")
        for key in ["QW_CLIENT_BIN", "SEARCHBENCH_SKIP_LOAD", "SEARCHBENCH_LOAD_PROCESSES",
                    "SEARCHBENCH_LOAD_MAX_RETRIES", "SEARCHBENCH_LOAD_REQUEST_TIMEOUT",
                    "SEARCHBENCH_DATASET", "QW_SPLIT_NUM_DOCS", "QW_COMMIT_TIMEOUT_SECS",
                    "QW_MIN_SHARDS", "QW_VALIDATE_DOCS", "QW_MERGE_POLICY", "QW_HEAP_SIZE",
                    "QW_ENABLE_IN_MEMORY_INDEXING", "SEARCHBENCH_LOAD_BATCH_SIZE",
                    "QW_PARQUET_CLI", "QW_PARQUET_PIPELINES", "QW_PARQUET_BATCH_ROWS"]:
            self.env.pop(key, None)
        self.executable(self.bin / "curl", '#!/bin/sh\necho "curl $*" >> "$MOCK_CALLS"\n')
        self.executable(self.bin / "sleep", "#!/bin/sh\nexit 0\n")

    @staticmethod
    def executable(path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o755)

    def run_load(self):
        return subprocess.run(["bash", str(self.adapter / "load")], env=self.env,
                              text=True, capture_output=True)

    def test_missing_rust_client_fails_before_index_deletion(self):
        result = self.run_load()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Rust client missing", result.stderr)
        self.assertFalse(self.calls.exists())

    def test_invalid_client_fails_before_index_deletion(self):
        self.env["SEARCHBENCH_LOAD_CLIENT"] = "typo"
        result = self.run_load()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be rust or python", result.stderr)
        self.assertFalse(self.calls.exists())

    def test_rust_arguments_and_failure_are_propagated(self):
        client = self.adapter / "client/target/release/qw-parquet-ingest"
        self.executable(client, '#!/bin/sh\nprintf "rust %s\\n" "$*" >> "$MOCK_CALLS"\nexit 42\n')
        result = self.run_load()
        self.assertEqual(result.returncode, 42)
        calls = self.calls.read_text()
        self.assertIn("--threads 16", calls)
        self.assertIn("--max-retries 8", calls)
        self.assertIn("--request-timeout-secs 60", calls)
        self.assertIn(str(self.data / "part_000.parquet"), calls)
        self.assertNotIn("waiting for commit", result.stdout)

    def test_explicit_binary_and_concurrency_are_used(self):
        client = self.root / "custom-client"
        self.executable(client, '#!/bin/sh\nprintf "rust %s\\n" "$*" >> "$MOCK_CALLS"\nexit 42\n')
        self.env.update(QW_CLIENT_BIN=str(client), SEARCHBENCH_LOAD_PROCESSES="3",
                        SEARCHBENCH_LOAD_MAX_RETRIES="2", SEARCHBENCH_LOAD_REQUEST_TIMEOUT="10")
        result = self.run_load()
        self.assertEqual(result.returncode, 42)
        calls = self.calls.read_text()
        for value in ["--threads 3", "--max-retries 2", "--request-timeout-secs 10"]:
            self.assertIn(value, calls)
        self.assertNotIn("--batch-size", calls)

    def test_optional_batch_size_is_forwarded(self):
        client = self.root / "custom-client"
        self.executable(client, '#!/bin/sh\nprintf "rust %s\\n" "$*" >> "$MOCK_CALLS"\nexit 42\n')
        self.env.update(QW_CLIENT_BIN=str(client), SEARCHBENCH_LOAD_BATCH_SIZE="8000")
        self.assertEqual(self.run_load().returncode, 42)
        self.assertIn("--batch-size 8000", self.calls.read_text())

    def test_main_index_configuration_overrides_still_apply(self):
        import json
        client = self.root / "custom-client"
        self.executable(client, '#!/bin/sh\nexit 42\n')
        config = self.root / "posted-config.json"
        self.env.update(QW_CLIENT_BIN=str(client), QW_SPLIT_NUM_DOCS="1000000",
                        QW_MERGE_POLICY="no_merge", QW_COMMIT_TIMEOUT_SECS="30",
                        QW_HEAP_SIZE="128MB", QW_VALIDATE_DOCS="off", QW_MIN_SHARDS="4",
                        MOCK_CONFIG=str(config), SEARCHBENCH_LOAD_PROCESSES="4")
        self.executable(self.bin / "curl", '''#!/bin/sh
for arg do
    case "$arg" in @/tmp/qw_index_config.*.json) cp "${arg#@}" "$MOCK_CONFIG";; esac
done
''')
        result = self.run_load()
        self.assertEqual(result.returncode, 42, result.stderr)
        data = json.loads(config.read_text())
        self.assertEqual(data["indexing_settings"]["split_num_docs_target"], 1000000)
        self.assertEqual(data["indexing_settings"]["commit_timeout_secs"], 30)
        self.assertEqual(data["indexing_settings"]["merge_policy"], {"type": "no_merge"})
        self.assertEqual(data["indexing_settings"]["resources"]["heap_size"], "128MB")
        self.assertFalse(data["ingest_settings"]["validate_docs"])
        self.assertEqual(data["ingest_settings"]["min_shards"], 4)

    def captured_config(self, dataset=None, **overrides):
        client = self.root / "custom-client"
        self.executable(client, '#!/bin/sh\nexit 42\n')
        config = self.root / "posted-config.json"
        if dataset is None:
            self.env.pop("SEARCHBENCH_DATASET", None)
        else:
            self.env["SEARCHBENCH_DATASET"] = dataset
        self.env.update(QW_CLIENT_BIN=str(client), MOCK_CONFIG=str(config), **overrides)
        self.executable(self.bin / "curl", '''#!/bin/sh
for arg do
    case "$arg" in @/tmp/qw_index_config.*.json) cp "${arg#@}" "$MOCK_CONFIG";; esac
done
''')
        result = self.run_load()
        self.assertEqual(result.returncode, 42, result.stderr)
        return json.loads(config.read_text())

    def test_100m_dataset_defaults(self):
        config = self.captured_config("otel_logs_100m")
        self.assertEqual(config["ingest_settings"], {"min_shards": 64, "validate_docs": False})
        self.assertEqual(config["indexing_settings"]["commit_timeout_secs"], 30)
        self.assertEqual(config["indexing_settings"]["split_num_docs_target"], 1000000)
        self.assertEqual(config["indexing_settings"]["merge_policy"], {
            "type": "stable_log", "min_level_num_docs": 100000,
            "merge_factor": 10, "max_merge_factor": 12, "maturation_period": "2days"})
        base = json.loads((self.adapter / "config/index_config.json").read_text())
        self.assertEqual(config["doc_mapping"], base["doc_mapping"])

    def test_100m_explicit_overrides_win(self):
        config = self.captured_config("otel_logs_100m", QW_MIN_SHARDS="8", QW_VALIDATE_DOCS="on",
                                      QW_SPLIT_NUM_DOCS="2000000", QW_COMMIT_TIMEOUT_SECS="90",
                                      QW_MERGE_POLICY="no_merge")
        self.assertEqual(config["ingest_settings"]["min_shards"], 8)
        self.assertTrue(config["ingest_settings"].get("validate_docs", True))
        self.assertEqual(config["indexing_settings"]["split_num_docs_target"], 2000000)
        self.assertEqual(config["indexing_settings"]["commit_timeout_secs"], 90)
        self.assertEqual(config["indexing_settings"]["merge_policy"], {"type": "no_merge"})

    def test_other_datasets_keep_main_defaults(self):
        base = json.loads((self.adapter / "config/index_config.json").read_text())
        for dataset in [None, "otel_logs_100k", "otel_logs_10m", "otel_logs_1b"]:
            with self.subTest(dataset=dataset):
                self.assertEqual(self.captured_config(dataset), base)

    def run_start(self, dataset, validation=None, existing=False, existing_label="previous-validation-mode", **extra):
        shutil.copy(Path(__file__).with_name("start"), self.adapter / "start")
        self.executable(self.adapter / "check", '#!/bin/sh\nexit 0\n')
        env = dict(self.env, SEARCHBENCH_DATASET=dataset, QW_STORAGE="local", QW_CLUSTERING="on",
                   QW_DATA_DIR=str(self.root / "qw-data"), MOCK_REMOVED=str(self.root / "removed"),
                   MOCK_EXISTING="yes" if existing else "no", MOCK_LABEL=existing_label, QW_S3_ROOT="")
        for key in ["QW_SERVICES", "QW_SHARD_THROUGHPUT_LIMIT", "QW_INGEST_QUEUE_MEMORY",
                    "QW_INGEST_QUEUE_DISK", "QW_FAST_FIELD_CACHE", "QW_VALIDATE_DOCS"]:
            env.pop(key, None)
        if validation is not None:
            env["QW_VALIDATE_DOCS"] = validation
        env.update(extra)
        self.executable(self.bin / "docker", '''#!/bin/sh
echo "$*" >> "$MOCK_CALLS"
case "$1" in
    inspect)
        if [ "$MOCK_EXISTING" = yes ] && [ ! -e "$MOCK_REMOVED" ]; then
            [ "$2" != -f ] || echo "$MOCK_LABEL"
            exit 0
        fi
        exit 1 ;;
    rm) touch "$MOCK_REMOVED" ;;
esac
exit 0
''')
        self.calls.write_text('')
        result = subprocess.run(["bash", str(self.adapter / "start")], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return self.calls.read_text()

    def test_start_uses_dataset_validation_mode_and_honors_override(self):
        for dataset, override, disabled in [("otel_logs_100m", None, True),
                                             ("otel_logs_100m", "on", False),
                                             ("otel_logs_1b", None, False)]:
            with self.subTest(dataset=dataset, override=override):
                calls = self.run_start(dataset, override)
                self.assertIn("run -d", calls)
                self.assertEqual("QW_DISABLE_DOCUMENT_VALIDATION=true" in calls, disabled)

    def test_wrapper_exports_in_memory_indexing_for_the_driver_and_children(self):
        shutil.copy(Path(__file__).with_name("benchmark.sh"), self.adapter / "benchmark.sh")
        # Stub driver: print the value its environment (and every child) inherits.
        self.executable(self.root / "lib/benchmark.sh",
                        '#!/bin/sh\nprintf "%s\\n" "${QW_ENABLE_IN_MEMORY_INDEXING-unset}"\n')
        for given, expected in [(None, "true"), ("false", "false"), ("true", "true")]:
            with self.subTest(given=given):
                env = dict(self.env)
                env.pop("QW_ENABLE_IN_MEMORY_INDEXING", None)
                if given is not None:
                    env["QW_ENABLE_IN_MEMORY_INDEXING"] = given
                result = subprocess.run(["bash", str(self.adapter / "benchmark.sh")], env=env,
                                        text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)

    def test_dataset_defaults_export_in_memory_indexing(self):
        env = dict(self.env)
        env.pop("QW_ENABLE_IN_MEMORY_INDEXING", None)
        result = subprocess.run(["bash", "-c", 'source "$1"; sh -c \'echo "${QW_ENABLE_IN_MEMORY_INDEXING-unset}"\'',
                                 "_", str(self.adapter / "config/dataset-defaults.sh")],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "true")

    def test_load_logs_in_memory_indexing(self):
        client = self.root / "custom-client"
        self.executable(client, '#!/bin/sh\nexit 42\n')
        self.env.update(QW_CLIENT_BIN=str(client), QW_ENABLE_IN_MEMORY_INDEXING="false")
        result = self.run_load()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("[load] in-memory indexing: QW_ENABLE_IN_MEMORY_INDEXING=false", result.stdout)

    def test_fast_field_cache_off_in_both_node_configs(self):
        for name in ["quickwit.yaml", "quickwit_s3.yaml"]:
            with self.subTest(config=name):
                text = (Path(__file__).with_name("config") / name).read_text()
                self.assertIn("\n  fast_field_cache_capacity: 0\n", text)
                self.assertIn("\n  partial_request_cache_capacity: 0\n", text)
                self.assertIn("\n  predicate_cache_capacity: 0\n", text)

    def test_fast_field_cache_override_rewrites_the_mounted_config(self):
        # ./start edits the copied node config with GNU `sed -i` (the bench hosts are Linux).
        gnu = shutil.which("sed") if subprocess.run(["sed", "--version"], capture_output=True).returncode == 0 \
            else shutil.which("gsed")
        if not gnu:
            self.skipTest("needs GNU sed")
        self.executable(self.bin / "sed", f'#!/bin/sh\nexec "{gnu}" "$@"\n')
        shutil.copytree(Path(__file__).with_name("config"), self.adapter / "config", dirs_exist_ok=True)
        calls = self.run_start("otel_logs_100m", QW_FAST_FIELD_CACHE="16GiB")
        cfg = self.root / "qw-data" / ".quickwit-node.yaml"
        self.assertIn("\n  fast_field_cache_capacity: 16GiB\n", cfg.read_text())
        self.assertIn(f"{cfg}:/quickwit/config/quickwit.yaml:ro", calls)

    def test_start_recreates_healthy_container_with_old_validation_mode(self):
        calls = self.run_start("otel_logs_100m", existing=True)
        self.assertIn("rm -f", calls)
        self.assertIn("QW_DISABLE_DOCUMENT_VALIDATION=true", calls)
        self.assertLess(calls.index("rm -f"), calls.index("run -d"))

    def test_memory_indexing_flag_defaults_on_for_all_datasets_and_can_opt_out(self):
        for dataset in ["otel_logs_100m", "otel_logs_1b", "otel_logs_100k"]:
            with self.subTest(dataset=dataset):
                calls = self.run_start(dataset)
                self.assertIn("-e QW_ENABLE_IN_MEMORY_INDEXING=true", calls)
                self.assertIn("|in-memory-indexing=true", calls)
        self.env["QW_ENABLE_IN_MEMORY_INDEXING"] = "false"
        calls = self.run_start("otel_logs_100m")
        self.assertIn("-e QW_ENABLE_IN_MEMORY_INDEXING=false", calls)
        self.assertIn("|in-memory-indexing=false", calls)

    def test_memory_indexing_change_recreates_a_healthy_container(self):
        image = self.env.get("QW_IMAGE", "quickwit/quickwit:edge@sha256:34b9552eb09fa85785f529d888ed2a64df68d3e2241213710b74accf4023e8ff")
        extra = self.env.get("QW_EXTRA_ENV", "")
        # A container from before the default flipped (flag off) must not be reused.
        label = f"{image}|{extra}|local|on|off|default|default|default|all|{self.root / 'qw-data'}||in-memory-indexing=false"
        self.env["QW_ENABLE_IN_MEMORY_INDEXING"] = "false"
        calls = self.run_start("otel_logs_100m", existing=True, existing_label=label)
        self.assertNotIn("rm -f", calls)
        self.assertNotIn("run -d", calls)
        self.env.pop("QW_ENABLE_IN_MEMORY_INDEXING")
        calls = self.run_start("otel_logs_100m", existing=True, existing_label=label)
        self.assertIn("rm -f", calls)
        self.assertIn("-e QW_ENABLE_IN_MEMORY_INDEXING=true", calls)

    def test_invalid_memory_indexing_flag_fails_before_index_deletion(self):
        self.env["QW_ENABLE_IN_MEMORY_INDEXING"] = "typo"
        result = self.run_load()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be true or false", result.stderr)
        self.assertFalse(self.calls.exists())

    def run_parquet(self, legacy, **env):
        """Run ./load with QW_INGEST=parquet against a mocked local-ingest CLI generation."""
        self.env.update(QW_INGEST="parquet", QW_ENABLE_IN_MEMORY_INDEXING="true", **env)
        marks = self.root / "marks"
        # phases_now advances 100 s per call; marks are recorded for the phase split.
        (self.root / "lib/load-phases.sh").write_text(
            'phases_start() { :; }\n'
            f'phases_now() {{ n=$(cat "{self.root}/clock" 2>/dev/null || echo 1000); echo $((n+100)) > "{self.root}/clock"; echo $n; }}\n'
            f'phases_mark() {{ printf -v "_PH_$1" "%s" "${{2:-1}}"; echo "$1=${{2:-}}" >> "{marks}"; }}\n')
        self.executable(self.adapter / "stop", '#!/bin/sh\nexit 0\n')
        # Stop before count/settle checks, after recording the bulk-ingest command.
        self.executable(self.adapter / "start", '#!/bin/sh\nexit 42\n')
        help_text = "--batch-num-rows <N>" if legacy else "--num-pipelines <N>"
        output = ("   Docs: 100\n   Indexing: 1MB/s, 10 docs/s\n   Indexing + merges: 1MB/s, 5 docs/s\n" if legacy
                  else "Num docs 50 Time 00:00:01\nNum docs 100 Time 00:00:02\n✔ Documents successfully indexed.\n")
        self.executable(self.bin / "docker", f'''#!/bin/sh
echo "docker $*" >> "$MOCK_CALLS"
case "$*" in *--help*) echo "{help_text}"; exit 0 ;; esac
printf '{output}'
''')
        result = self.run_load()
        return result, self.calls.read_text(), (marks.read_text() if marks.exists() else "")

    def test_memory_indexing_flag_reaches_parquet_cli(self):
        result, calls, _ = self.run_parquet(legacy=True)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("-e QW_ENABLE_IN_MEMORY_INDEXING=true", calls)
        self.assertIn("--input-format parquet", calls)
        self.assertIn("parquet local-ingest CLI: legacy", result.stdout)

    def test_bulk_parquet_cli_omits_removed_flags_and_splits_phases(self):
        result, calls, marks = self.run_parquet(legacy=False, QW_PARQUET_PIPELINES="8")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("parquet local-ingest CLI: bulk", result.stdout)
        ingest_call = next(line for line in calls.splitlines() if "tool local-ingest --index" in line)
        self.assertNotIn("--input-format", ingest_call)
        self.assertNotIn("--batch-num-rows", ingest_call)
        self.assertIn("--num-pipelines 8", ingest_call)
        self.assertIn("--input-path file:///data/part_000.parquet", ingest_call)
        # ingest_end precedes merges_end; both come from real timestamps, never invented.
        values = dict(line.split("=", 1) for line in marks.splitlines())
        self.assertLessEqual(float(values["ingest_end"]), float(values["merges_end"]))

    def test_bulk_parquet_cli_rejects_batch_rows(self):
        result, calls, _ = self.run_parquet(legacy=False, QW_PARQUET_BATCH_ROWS="4096")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("QW_PARQUET_BATCH_ROWS is not supported", result.stderr)
        self.assertNotIn("tool local-ingest --index", calls)

    def test_parquet_cli_override_is_validated(self):
        result, _, _ = self.run_parquet(legacy=False, QW_PARQUET_CLI="typo")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("QW_PARQUET_CLI must be auto, legacy or bulk", result.stderr)


if __name__ == "__main__":
    unittest.main()
