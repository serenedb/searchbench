# Shared settings for the SearchBench Pinot adapter.
# Everything here is overridable from the environment so the same adapter runs
# on a laptop and on a benchmark box without edits.

# --- where Pinot lives -------------------------------------------------------
# PINOT_DIST must point at an unpacked distribution (the dir containing bin/).
if [[ -z "${PINOT_DIST:-}" ]]; then
    for _c in /data/pinot-dist \
              "$HOME/pinot-dist" \
              /opt/pinot \
              "$HOME/Documents/GitHub/pinot/pinot-distribution/target/apache-pinot-"*-bin/apache-pinot-*-bin; do
        [[ -x "$_c/bin/pinot-admin.sh" ]] && { PINOT_DIST="$_c"; break; }
    done
fi
: "${PINOT_DIST:?set PINOT_DIST to an unpacked Pinot distribution (the dir containing bin/)}"

# JDK: explicit override wins, else a JDK already on PATH, else macOS java_home.
if [[ -z "${PINOT_JAVA_HOME:-}" ]]; then
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        PINOT_JAVA_HOME="$JAVA_HOME"
    elif command -v java >/dev/null 2>&1; then
        PINOT_JAVA_HOME="$(dirname "$(dirname "$(command -v java)")")"
    elif [[ -x /usr/libexec/java_home ]]; then
        PINOT_JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null)"
    fi
fi
JAVA_HOME="${PINOT_JAVA_HOME:?no JDK found; set PINOT_JAVA_HOME}"
export JAVA_HOME

# pinot-admin.sh selects the JVM from JAVA_HOME but detects the version with a bare `java`, and
# only adds the --add-opens flags when that detection yields >11. With a JDK that is not on PATH
# (e.g. unpacked from a tarball) detection returns empty, the flags are dropped, and the service
# dies in Jersey with InaccessibleObjectException. Keep the chosen JDK first on PATH.
export PATH="$JAVA_HOME/bin:$PATH"

# Fail fast on a JDK older than the one the distribution was built with. Otherwise every component dies
# with an UnsupportedClassVersionError buried in its own log and the driver just reports a 60s timeout.
_java_major=$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+).*/\1/')
if [[ "${_java_major:-0}" -lt "${PINOT_MIN_JAVA:-21}" ]]; then
    echo "JDK ${_java_major} at $JAVA_HOME is older than the required ${PINOT_MIN_JAVA:-21}." >&2
    echo "Set PINOT_JAVA_HOME to a matching JDK (the distribution's class files decide this)." >&2
    exit 1
fi

# --- where data lives --------------------------------------------------------
# On a benchmark box point PINOT_WORK at the big disk; it holds segments,
# the deep store and the sharded corpus, and ./install wipes it.
: "${PINOT_WORK:=$HOME/sb-pinot-work}"
# Segment build scratch. Amazon Linux 2023 mounts /tmp as a tmpfs sized at 50%
# of RAM, so Pinot's default scratch is RAM: 16 concurrent builds then compete
# with the JVM heaps for the same 128GB and the job dies in
# BaseSegmentCreator.close(). Keep scratch on the data disk.
: "${PINOT_TMPDIR:=$PINOT_WORK/tmp}"
: "${PINOT_TABLE:=otel_logs}"

# --- ports / cluster ---------------------------------------------------------
: "${ZK_PORT:=2191}"
: "${CONTROLLER_PORT:=9000}"
: "${BROKER_PORT:=8099}"
: "${SERVER_PORT:=8098}"
: "${SERVER_ADMIN_PORT:=8097}"
: "${PINOT_CLUSTER:=searchbench}"

# --- segment sizing ----------------------------------------------------------
# A segment is Pinot's unit of query parallelism AND of Lucene index build, so
# it must scale with the corpus: one 1B-row segment would serialise the whole
# scan onto a single thread and build one enormous Lucene index. Target rows per
# segment, floored at the core count so a small corpus still parallelises.
: "${PINOT_ROWS_PER_SEGMENT:=4000000}"
: "${PINOT_SEGMENTS:=}"          # explicit override; else derived in ./load
: "${PINOT_MIN_SEGMENTS:=}"      # default: nproc, computed below

if [[ -z "${PINOT_MIN_SEGMENTS}" ]]; then
    PINOT_MIN_SEGMENTS=$( (command -v nproc >/dev/null && nproc) \
        || sysctl -n hw.ncpu 2>/dev/null || echo 8 )
fi

# --- heap --------------------------------------------------------------------
# Default to a fraction of machine RAM rather than a fixed figure: the server
# holds Lucene readers and aggregation state, and 16G is wrong on both a 36G
# laptop and a 128G benchmark box. Pinot leans on the page cache for mmap'd
# segments, so the server deliberately does NOT take most of RAM.
if [[ -z "${SERVER_XMX:-}" ]]; then
    _ram_kb=$( (grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}') \
        || echo $(( $(sysctl -n hw.memsize 2>/dev/null || echo 17179869184) / 1024 )) )
    SERVER_XMX="$(( _ram_kb / 1024 / 1024 * 25 / 100 ))G"   # 25% of RAM
fi
: "${CONTROLLER_XMX:=2G}"
: "${BROKER_XMX:=4G}"

# --- query parallelism -------------------------------------------------------
# Derived from the box, not fixed, for the same reason as the heap above.
#
# The single-stage engine fans segment scans across threads, but its per-query ceiling is
# max(1, min(10, availableProcessors() / 2)) -- i.e. 10 on anything with 20+ cores, NOT the core
# count. The per-query `maxExecutionThreads` option overrides it as long as the server-level
# max.execution.threads is left at its -1 default. Measured on a 32-core box at 1B: 1.51x geomean
# over the non-join queries, and 64 bought nothing over 32, so track the core count.
if [[ -z "${SEARCHBENCH_MAX_EXEC_THREADS:-}" ]]; then
    SEARCHBENCH_MAX_EXEC_THREADS=$( (nproc 2>/dev/null) || sysctl -n hw.ncpu 2>/dev/null || echo 8 )
fi

# Workers per intermediate (join) stage. WorkerManager defaults this to 1, so on a single server
# the whole join stage runs on ONE worker. 8 measured fastest at 1B on 32 cores; 4 and 16 were
# close, 32 slower and 64 clearly worse, so this plateaus rather than tracking the core count.
: "${SEARCHBENCH_STAGE_PARALLELISM:=8}"
export SEARCHBENCH_MAX_EXEC_THREADS SEARCHBENCH_STAGE_PARALLELISM

ADMIN="$PINOT_DIST/bin/pinot-admin.sh"
CONTROLLER="http://localhost:${CONTROLLER_PORT}"
BROKER="http://localhost:${BROKER_PORT}"
