#!/bin/bash
# Asus Ascent GX10 Server-Based Stress Test Script
# Tests sustained inference throughput by loading model ONCE via llama-server,
# then sending all topics as HTTP requests — mirrors real-world deployment.
#
# Usage:
#   Interactive : ./5-stress-test-server.sh          (prompts for all options)
#   Arguments   : ./5-stress-test-server.sh <length> <vram> <model>
#     length : duration like 6h | 12h | 24h (also Nm for minutes, e.g. 30m)
#              or a topic count: 100 | 200 | 300
#     vram   : low | moderate | high
#     model  : small | large | xlarge
#                small  = Llama 3.1 70B Q4_K_M  (~40GB weights, ~80GB VRAM headroom)
#                large  = Llama 3.1 70B Q8_0    (~74GB weights, ~46GB VRAM headroom)
#                xlarge = Mixtral 8x22B Q5_K_M  (~95GB weights, ~25GB VRAM headroom)
#
# Examples: ./5-stress-test-server.sh 12h high large     (run 12 hours)
#           ./5-stress-test-server.sh 200 moderate large (run 200 topics)
#
# Differences vs 3-stress-test-topics.sh:
#   - Model loads ONCE into VRAM, stays resident for all topics
#   - Requests sent via HTTP to llama-server (/completion endpoint)
#   - Stress-tests sustained token generation throughput, not load/unload cycles
#   - Requires: curl, jq

set -e

# --- Argument parsing (interactive when run without arguments) ---
TOPICS_ARG="${1:-}"
VRAM_ARG="${2:-}"
MODEL_SIZE_ARG="${3:-}"

if [[ -z "$TOPICS_ARG" ]]; then
    echo "========================================="
    echo "GX10 Server Stress Test - Interactive Mode"
    echo "========================================="
    echo ""
    echo "Model to test:"
    echo "  1) small  - Llama 3.1 70B Q4_K_M  (~40GB weights, ~80GB VRAM headroom)"
    echo "  2) large  - Llama 3.1 70B Q8_0    (~74GB weights, ~46GB VRAM headroom)"
    echo "  3) xlarge - Mixtral 8x22B Q5_K_M  (~95GB weights, ~25GB VRAM headroom)"
    read -p "Choice [1-3] (default: 2): " ans
    case "${ans:-2}" in
        1) MODEL_SIZE_ARG="small" ;;
        2) MODEL_SIZE_ARG="large" ;;
        3) MODEL_SIZE_ARG="xlarge" ;;
        *) echo "Invalid choice, using large"; MODEL_SIZE_ARG="large" ;;
    esac
    echo ""
    echo "Test length (at ~2.7 tok/s a topic takes ~5-13 min depending on profile):"
    echo "  1) 6 hours  - minimum burn-in"
    echo "  2) 12 hours - extended burn-in"
    echo "  3) 24 hours - full-day burn-in"
    echo "  4) By topic count instead (100 / 200 / 300)"
    read -p "Choice [1-4] (default: 1): " ans
    case "${ans:-1}" in
        1) TOPICS_ARG="6h" ;;
        2) TOPICS_ARG="12h" ;;
        3) TOPICS_ARG="24h" ;;
        4)
            echo ""
            echo "Number of topics:"
            echo "  1) 100"
            echo "  2) 200"
            echo "  3) 300"
            read -p "Choice [1-3] (default: 2): " ans2
            case "${ans2:-2}" in
                1) TOPICS_ARG=100 ;;
                2) TOPICS_ARG=200 ;;
                3) TOPICS_ARG=300 ;;
                *) echo "Invalid choice, using 200"; TOPICS_ARG=200 ;;
            esac
            ;;
        *) echo "Invalid choice, using 6h"; TOPICS_ARG="6h" ;;
    esac
    echo ""
    echo "VRAM profile (context/batch sizes scale with this):"
    echo "  1) low      - smallest context and batch"
    echo "  2) moderate - balanced"
    echo "  3) high     - largest context and batch"
    read -p "Choice [1-3] (default: 2): " ans
    case "${ans:-2}" in
        1) VRAM_ARG="low" ;;
        2) VRAM_ARG="moderate" ;;
        3) VRAM_ARG="high" ;;
        *) echo "Invalid choice, using moderate"; VRAM_ARG="moderate" ;;
    esac
    echo ""
    echo "-----------------------------------------"
    echo "Selected: length=$TOPICS_ARG  vram=$VRAM_ARG  model=$MODEL_SIZE_ARG"
    echo "(same as: $0 $TOPICS_ARG $VRAM_ARG $MODEL_SIZE_ARG)"
    echo "-----------------------------------------"
    read -p "Start stress test? [Y/n]: " ans
    if [[ "${ans:-y}" =~ ^[Nn] ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""
fi

MODEL_SIZE_ARG="${MODEL_SIZE_ARG:-small}"

# Length: either a duration (6h / 30m) or a topic count (100/200/300)
DURATION_SECS=0
NUM_TOPICS=0
if [[ "$TOPICS_ARG" =~ ^[0-9]+h$ ]]; then
    DURATION_SECS=$(( ${TOPICS_ARG%h} * 3600 ))
elif [[ "$TOPICS_ARG" =~ ^[0-9]+m$ ]]; then
    DURATION_SECS=$(( ${TOPICS_ARG%m} * 60 ))
else
    case "$TOPICS_ARG" in
        100|200|300) NUM_TOPICS="$TOPICS_ARG" ;;
        *) echo "ERROR: length must be a duration (e.g. 6h, 12h, 24h, 30m) or 100/200/300 topics (got: $TOPICS_ARG)"; exit 1 ;;
    esac
fi
if [[ "$DURATION_SECS" -gt 0 ]]; then
    LENGTH_DESC="duration $TOPICS_ARG"
else
    LENGTH_DESC="$NUM_TOPICS topics"
fi

# VRAM profiles — same as script 3, same rationale
case "$MODEL_SIZE_ARG" in
    small)
        # Llama 3.1 70B Q4_K_M — ~40GB weights, large VRAM headroom
        case "$VRAM_ARG" in
            low)      CONTEXT_SIZE=8192;  BATCH_SIZE=512;  N_PREDICT=1024 ;;
            moderate) CONTEXT_SIZE=32768; BATCH_SIZE=2048; N_PREDICT=1536 ;;
            high)     CONTEXT_SIZE=65536; BATCH_SIZE=4096; N_PREDICT=2048 ;;
            *) echo "ERROR: vram must be low, moderate, or high (got: $VRAM_ARG)"; exit 1 ;;
        esac
        ;;
    large)
        # Llama 3.1 70B Q8_0 — ~74GB weights, moderate VRAM headroom (~46GB)
        case "$VRAM_ARG" in
            low)      CONTEXT_SIZE=4096;  BATCH_SIZE=512;  N_PREDICT=1024 ;;
            moderate) CONTEXT_SIZE=8192;  BATCH_SIZE=1024; N_PREDICT=1536 ;;
            high)     CONTEXT_SIZE=16384; BATCH_SIZE=2048; N_PREDICT=2048 ;;
            *) echo "ERROR: vram must be low, moderate, or high (got: $VRAM_ARG)"; exit 1 ;;
        esac
        ;;
    xlarge)
        # Mixtral 8x22B Q5_K_M — ~95GB weights, tight VRAM headroom (~25GB)
        case "$VRAM_ARG" in
            low)      CONTEXT_SIZE=2048; BATCH_SIZE=256; N_PREDICT=512  ;;
            moderate) CONTEXT_SIZE=4096; BATCH_SIZE=512; N_PREDICT=1024 ;;
            high)     CONTEXT_SIZE=8192; BATCH_SIZE=512; N_PREDICT=1536 ;;
            *) echo "ERROR: vram must be low, moderate, or high (got: $VRAM_ARG)"; exit 1 ;;
        esac
        ;;
    *) echo "ERROR: model must be small, large, or xlarge (got: $MODEL_SIZE_ARG)"; exit 1 ;;
esac

# --- Configuration ---
MODEL_PATH="./models/Meta-Llama-3.1-70B-Instruct-Q4_K_M.gguf"
case "$MODEL_SIZE_ARG" in
    large)  MODEL_PATH="./models/Meta-Llama-3.1-70B-Instruct-Q8_0/Meta-Llama-3.1-70B-Instruct-Q8_0-00001-of-00002.gguf" ;;
    xlarge) MODEL_PATH="./models/Mixtral-8x22B-Instruct-v0.1.Q5_K_M-00001-of-00004.gguf" ;;
esac

LLAMA_CPP_PATH="./llama.cpp"
LOG_DIR="./logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
STRESS_LOG="$LOG_DIR/stress_test_server_${TIMESTAMP}.log"
SERVER_LOG="$LOG_DIR/llama_server_${TIMESTAMP}.log"
MONITOR_LOG="$LOG_DIR/gpu_monitor_${TIMESTAMP}.csv"
ALERT_LOG="$LOG_DIR/gpu_alerts_${TIMESTAMP}.log"

# Thermal monitor: samples GPU + SoC sensors into a CSV for the whole run
MONITOR_INTERVAL=10   # seconds between samples
TEMP_WARN=80          # deg C - logged as WARNING
TEMP_CRIT=85          # deg C - logged as CRITICAL

# llama-server parameters
GPU_LAYERS=999
TEMPERATURE=0.8
REPEAT_PENALTY=1.1
SERVER_PORT=8080
SERVER_HOST="127.0.0.1"
# Seconds to wait for model load; overridable because concurrent GPU load
# (combined test) slows the load significantly
SERVER_STARTUP_TIMEOUT="${STRESS_STARTUP_TIMEOUT:-300}"
SERVER_PID=""

# Per-request timeout scaled to N_PREDICT: worst-case 1.5 tok/s plus 10 min
# buffer for prompt processing. (A fixed 600s cap caused spurious errors:
# at ~2.7 tok/s a full 2048-token generation takes ~12.5 minutes.)
# STRESS_SLOW_FACTOR: 2 -> assumes >=1.5 tok/s; the combined test (script 6)
# exports 4 (>=0.75 tok/s) because concurrent image gen slows LLM decode.
SLOW_FACTOR="${STRESS_SLOW_FACTOR:-2}"
CURL_MAX_TIME=$(( N_PREDICT * SLOW_FACTOR / 3 + 600 ))

# --- Dependency checks ---
if ! command -v curl &>/dev/null; then
    echo "ERROR: curl is required but not found"; exit 1
fi
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not found (install: apt install jq / brew install jq)"; exit 1
fi

# --- GPU/thermal monitor (background CSV logger) ---
monitor_loop() {
    echo "timestamp,gpu_temp_c,gpu_util_pct,power_w,sm_clock_mhz,soc_temp_max_c,sys_mem_used_pct" > "$MONITOR_LOG"
    while :; do
        local TS GTEMP GUTIL GPOW GCLK SOC MEMPCT v
        TS=$(date '+%Y-%m-%d %H:%M:%S')
        read -r GTEMP GUTIL GPOW GCLK <<< "$(nvidia-smi \
            --query-gpu=temperature.gpu,utilization.gpu,power.draw,clocks.sm \
            --format=csv,noheader,nounits 2>/dev/null | tr -d ',')"
        # Hottest ACPI/SoC thermal zone (hwmon; some nodes are unreadable - skip)
        SOC=0
        for t in /sys/class/hwmon/hwmon*/temp*_input; do
            v=$(cat "$t" 2>/dev/null) || continue
            v=$((v / 1000))
            [ "$v" -gt "$SOC" ] && SOC=$v
        done
        MEMPCT=$(free | awk '/Mem:/ {printf "%.0f", $3/$2*100}')
        echo "$TS,${GTEMP:-NA},${GUTIL:-NA},${GPOW:-NA},${GCLK:-NA},$SOC,$MEMPCT" >> "$MONITOR_LOG"
        if [[ "${GTEMP:-0}" =~ ^[0-9]+$ ]]; then
            if [ "$GTEMP" -ge "$TEMP_CRIT" ]; then
                echo "[$TS] CRITICAL: GPU ${GTEMP}C >= ${TEMP_CRIT}C" >> "$ALERT_LOG"
            elif [ "$GTEMP" -ge "$TEMP_WARN" ]; then
                echo "[$TS] WARNING: GPU ${GTEMP}C >= ${TEMP_WARN}C" >> "$ALERT_LOG"
            fi
        fi
        sleep "$MONITOR_INTERVAL"
    done
}
MONITOR_PID=""

# --- Cleanup on exit ---
cleanup() {
    if [[ -n "$MONITOR_PID" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi
    if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "" | tee -a "$STRESS_LOG"
        echo "Stopping llama-server (PID $SERVER_PID)..." | tee -a "$STRESS_LOG"
        kill "$SERVER_PID"
        wait "$SERVER_PID" 2>/dev/null || true
        echo "Server stopped." | tee -a "$STRESS_LOG"
    fi
}
trap cleanup EXIT INT TERM

# --- Create log directory ---
mkdir -p "$LOG_DIR"

echo "=========================================" | tee "$STRESS_LOG"
echo "Asus Ascent GX10 Server-Based Stress Test" | tee -a "$STRESS_LOG"
echo "=========================================" | tee -a "$STRESS_LOG"
echo "Start time: $(date)" | tee -a "$STRESS_LOG"
echo "Test length: $LENGTH_DESC" | tee -a "$STRESS_LOG"
echo "VRAM profile: $VRAM_ARG / model-size: $MODEL_SIZE_ARG (ctx=$CONTEXT_SIZE, batch=$BATCH_SIZE, predict=$N_PREDICT)" | tee -a "$STRESS_LOG"
echo "Per-request timeout: ${CURL_MAX_TIME}s" | tee -a "$STRESS_LOG"
echo "Model: $MODEL_PATH" | tee -a "$STRESS_LOG"
echo "Mode: SINGLE LOAD — model stays resident for the whole test ($LENGTH_DESC)" | tee -a "$STRESS_LOG"
echo "Stress log: $STRESS_LOG" | tee -a "$STRESS_LOG"
echo "Server log: $SERVER_LOG" | tee -a "$STRESS_LOG"
echo "" | tee -a "$STRESS_LOG"

# --- Validate model ---
if [ ! -f "$MODEL_PATH" ]; then
    echo "ERROR: Model not found at $MODEL_PATH" | tee -a "$STRESS_LOG"
    echo "Please run ./1-download-model.sh first" | tee -a "$STRESS_LOG"
    exit 1
fi

# --- Locate llama-server ---
if [ -f "$LLAMA_CPP_PATH/llama-server" ]; then
    LLAMA_SERVER="$LLAMA_CPP_PATH/llama-server"
elif [ -f "$LLAMA_CPP_PATH/build/bin/llama-server" ]; then
    LLAMA_SERVER="$LLAMA_CPP_PATH/build/bin/llama-server"
elif command -v llama-server &>/dev/null; then
    LLAMA_SERVER="llama-server"
else
    echo "ERROR: llama-server not found" | tee -a "$STRESS_LOG"
    echo "Please build llama.cpp first" | tee -a "$STRESS_LOG"
    exit 1
fi

LLAMA_LIB_DIR="$(dirname "$LLAMA_SERVER")"
export LD_LIBRARY_PATH="$LLAMA_LIB_DIR:$LD_LIBRARY_PATH"

echo "Using llama-server: $LLAMA_SERVER" | tee -a "$STRESS_LOG"
echo "Library path: $LLAMA_LIB_DIR" | tee -a "$STRESS_LOG"
echo "" | tee -a "$STRESS_LOG"

# --- System info ---
echo "System Information:" | tee -a "$STRESS_LOG"
echo "-------------------" | tee -a "$STRESS_LOG"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv | tee -a "$STRESS_LOG"
echo "" | tee -a "$STRESS_LOG"

# --- Start thermal monitor ---
monitor_loop &
MONITOR_PID=$!
echo "GPU/thermal monitor started (PID $MONITOR_PID, every ${MONITOR_INTERVAL}s -> $MONITOR_LOG)" | tee -a "$STRESS_LOG"
echo "" | tee -a "$STRESS_LOG"

# --- Start llama-server ---
echo "Starting llama-server — model will load once and stay resident..." | tee -a "$STRESS_LOG"
echo "Server log: $SERVER_LOG" | tee -a "$STRESS_LOG"

$LLAMA_SERVER \
    -m "$MODEL_PATH" \
    -ngl $GPU_LAYERS \
    -c $CONTEXT_SIZE \
    -b $BATCH_SIZE \
    --host "$SERVER_HOST" \
    --port "$SERVER_PORT" \
    --log-disable \
    > "$SERVER_LOG" 2>&1 &

SERVER_PID=$!
echo "Server PID: $SERVER_PID" | tee -a "$STRESS_LOG"

# --- Wait for server to be ready ---
echo "Waiting for server to load model (up to ${SERVER_STARTUP_TIMEOUT}s)..." | tee -a "$STRESS_LOG"
LOAD_START=$(date +%s)
SERVER_READY=0

for i in $(seq 1 $SERVER_STARTUP_TIMEOUT); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: llama-server process died during startup" | tee -a "$STRESS_LOG"
        echo "Check server log: $SERVER_LOG" | tee -a "$STRESS_LOG"
        exit 1
    fi

    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        "http://${SERVER_HOST}:${SERVER_PORT}/health" 2>/dev/null || echo "000")

    if [[ "$HTTP_STATUS" == "200" ]]; then
        SERVER_READY=1
        break
    fi

    sleep 1
done

if [[ "$SERVER_READY" -eq 0 ]]; then
    echo "ERROR: Server did not become ready within ${SERVER_STARTUP_TIMEOUT}s" | tee -a "$STRESS_LOG"
    exit 1
fi

LOAD_END=$(date +%s)
LOAD_DURATION=$((LOAD_END - LOAD_START))
echo "Model loaded and server ready in ${LOAD_DURATION}s" | tee -a "$STRESS_LOG"
echo "" | tee -a "$STRESS_LOG"

# --- Topics ---
TOPICS=(
    "Explain quantum computing in detail, covering quantum bits, superposition, entanglement, and quantum algorithms."
    "Write a comprehensive guide to machine learning, including supervised learning, unsupervised learning, neural networks, and deep learning architectures."
    "Describe the history of computer science from the early mechanical computers to modern quantum computers."
    "Analyze the principles of distributed systems, including consistency, availability, partition tolerance, and consensus algorithms."
    "Provide an in-depth explanation of cryptography, covering symmetric encryption, asymmetric encryption, hash functions, and digital signatures."
    "Discuss advanced algorithms and data structures including B-trees, red-black trees, graph algorithms, and dynamic programming."
    "Explain the architecture of modern operating systems, including process management, memory management, file systems, and I/O systems."
    "Describe the evolution of computer networks from ARPANET to the modern Internet, including protocols, routing, and network security."
    "Analyze cloud computing architectures, including virtualization, containerization, microservices, and serverless computing."
    "Explain artificial intelligence and its subfields: machine learning, computer vision, natural language processing, and robotics."
    "Discuss database systems, covering relational databases, NoSQL databases, distributed databases, and database optimization."
    "Describe software engineering principles, including design patterns, software architecture, testing methodologies, and DevOps practices."
    "Explain compiler design, including lexical analysis, syntax analysis, semantic analysis, and code generation."
    "Analyze cybersecurity threats and defenses, including malware, intrusion detection, penetration testing, and security frameworks."
    "Discuss blockchain technology, cryptocurrencies, smart contracts, consensus mechanisms, and decentralized applications."
    "Explain computer graphics and rendering techniques, including ray tracing, rasterization, shading, and GPU programming."
    "Describe high-performance computing, parallel processing, GPU computing, and distributed computing frameworks."
    "Analyze big data technologies, including Hadoop, Spark, data lakes, data warehouses, and real-time processing."
    "Explain the Internet of Things (IoT), edge computing, sensor networks, and IoT security considerations."
    "Discuss computer architecture, including CPU design, instruction sets, pipelining, caching, and memory hierarchies."
    "Describe programming language theory, including type systems, lambda calculus, formal semantics, and language design."
    "Explain version control systems, Git workflows, branching strategies, and collaborative software development."
    "Analyze web technologies, including HTML5, CSS3, JavaScript frameworks, RESTful APIs, and Progressive Web Apps."
    "Discuss mobile app development for iOS and Android, including native development, cross-platform frameworks, and mobile UI/UX."
    "Explain game development, including game engines, physics simulation, AI for games, and multiplayer networking."
    "Describe data science and analytics, covering statistical analysis, data visualization, predictive modeling, and business intelligence."
    "Analyze information retrieval and search engines, including indexing, ranking algorithms, query processing, and recommendation systems."
    "Explain augmented reality (AR) and virtual reality (VR), including hardware, tracking systems, and immersive applications."
    "Discuss bioinformatics and computational biology, including genome sequencing, protein folding, and phylogenetic analysis."
    "Describe embedded systems, real-time operating systems, microcontroller programming, and hardware-software co-design."
    "Explain network protocols in depth: TCP/IP, HTTP/HTTPS, DNS, DHCP, and emerging protocols like QUIC."
    "Analyze software testing strategies, including unit testing, integration testing, end-to-end testing, and test automation."
    "Discuss container orchestration with Kubernetes, Docker Swarm, service mesh, and cloud-native architectures."
    "Explain machine learning model deployment, MLOps, model monitoring, and production ML systems."
    "Describe computational complexity theory, P vs NP problem, NP-completeness, and approximation algorithms."
    "Analyze wireless communication technologies: Wi-Fi, Bluetooth, 5G, LoRaWAN, and satellite communications."
    "Explain digital signal processing, Fourier transforms, filtering, and audio/video compression algorithms."
    "Discuss ethical AI, algorithmic bias, fairness in machine learning, and responsible AI development."
    "Describe quantum algorithms like Shor's algorithm, Grover's algorithm, and quantum error correction."
    "Analyze software architecture patterns: monolithic, microservices, event-driven, and serverless architectures."
    "Explain natural language processing techniques: tokenization, parsing, named entity recognition, and transformer models."
    "Discuss computer vision applications: object detection, image segmentation, facial recognition, and autonomous vehicles."
    "Describe functional programming concepts, pure functions, immutability, monads, and functional reactive programming."
    "Analyze time series analysis, forecasting methods, ARIMA models, and deep learning for sequential data."
    "Explain reinforcement learning, Q-learning, policy gradients, actor-critic methods, and multi-agent systems."
    "Discuss code optimization techniques, profiling, algorithmic optimization, and compiler optimizations."
    "Describe API design principles, REST vs GraphQL, API versioning, authentication, and rate limiting."
    "Analyze edge AI and on-device machine learning for mobile and IoT devices."
    "Explain federated learning, privacy-preserving machine learning, and differential privacy."
    "Discuss software development methodologies: Agile, Scrum, Kanban, and Extreme Programming."
    "Describe memory management techniques, garbage collection algorithms, and memory leak detection."
    "Analyze streaming data processing with Apache Kafka, Apache Flink, and real-time analytics."
    "Explain computer security fundamentals: authentication, authorization, encryption, and secure coding practices."
    "Discuss data structures for specific use cases: bloom filters, skip lists, tries, and spatial data structures."
    "Describe neural network architectures: CNNs, RNNs, LSTMs, GANs, and attention mechanisms."
    "Analyze performance optimization for databases: indexing strategies, query optimization, and caching."
    "Explain distributed consensus algorithms: Paxos, Raft, and Byzantine fault tolerance."
    "Discuss software refactoring techniques, code smells, technical debt, and clean code principles."
    "Describe network security: firewalls, VPNs, intrusion detection systems, and zero-trust architecture."
    "Analyze graph theory and graph algorithms: shortest path, minimum spanning tree, and graph coloring."
    "Explain computer vision deep learning: image classification, object detection with YOLO/R-CNN, and semantic segmentation."
    "Discuss event-driven architecture, message queues, publish-subscribe patterns, and event sourcing."
    "Describe load balancing algorithms, CDN architecture, and scalable web application design."
    "Analyze time complexity analysis, Big O notation, amortized analysis, and space-time tradeoffs."
    "Explain transfer learning, pre-trained models, fine-tuning, and domain adaptation."
    "Discuss continuous integration and continuous deployment (CI/CD) pipelines and automation."
    "Describe multi-threading and concurrency: locks, semaphores, race conditions, and deadlock prevention."
    "Analyze recommendation systems: collaborative filtering, content-based filtering, and hybrid approaches."
    "Explain hyperparameter optimization, grid search, random search, and Bayesian optimization."
    "Discuss software licensing, open source licenses, intellectual property, and compliance."
    "Describe network programming: sockets, TCP/UDP programming, and asynchronous I/O."
    "Analyze anomaly detection techniques using statistical methods and machine learning."
    "Explain generative AI models: GPT, BERT, diffusion models, and large language models."
    "Discuss infrastructure as code with Terraform, CloudFormation, and configuration management."
    "Describe image processing techniques: filtering, edge detection, morphological operations, and feature extraction."
    "Analyze caching strategies: client-side caching, server-side caching, and distributed caching with Redis."
    "Explain explainable AI (XAI), model interpretability, SHAP values, and LIME."
    "Discuss software supply chain security, dependency management, and vulnerability scanning."
    "Describe numerical computing and scientific computing with NumPy, SciPy, and MATLAB."
    "Analyze sentiment analysis, text classification, and emotion detection in NLP."
    "Explain system design for large-scale applications: scalability, reliability, and fault tolerance."
    "Discuss digital image formats, compression algorithms like JPEG and PNG, and video codecs."
    "Describe penetration testing methodologies, vulnerability assessment, and security auditing."
    "Analyze feature engineering for machine learning: feature selection, dimensionality reduction, and encoding."
    "Explain web scraping techniques, HTML parsing, and ethical considerations."
    "Discuss chaos engineering, resilience testing, and failure injection in distributed systems."
    "Describe GPU programming with CUDA, OpenCL, and shader programming."
    "Analyze network traffic analysis, packet inspection, and network forensics."
    "Explain data privacy regulations: GDPR, CCPA, and privacy by design principles."
    "Discuss software documentation best practices, API documentation, and technical writing."
    "Describe audio processing and speech recognition systems."
    "Analyze A/B testing, experimental design, and statistical significance in product development."
    "Explain distributed tracing, observability, and monitoring in microservices architectures."
    "Discuss computer-aided design (CAD) systems and computational geometry."
    "Describe ensemble learning methods: bagging, boosting, stacking, and random forests."
    "Analyze serverless architecture patterns, function as a service, and event-driven serverless."
    "Explain knowledge graphs, semantic web technologies, and ontologies."
    "Discuss hardware acceleration for AI: TPUs, NPUs, and custom AI chips."
    "Describe software architectural trade-offs and decision-making frameworks."
    "Analyze cross-platform development frameworks: React Native, Flutter, Electron, and Xamarin."
    "Explain information theory, entropy, data compression, and error correction codes."
)

# --- Metrics ---
TOTAL_TOKENS=0
TOTAL_TOKENS_PER_SEC=0
TOKENS_PER_SEC_SAMPLES=0
ERRORS=0
CONSECUTIVE_ERRORS=0
START_TIME=$(date +%s)

echo "Starting stress test (model already resident in VRAM)..." | tee -a "$STRESS_LOG"
echo "Running $LENGTH_DESC via HTTP..." | tee -a "$STRESS_LOG"
echo "" | tee -a "$STRESS_LOG"

# --- Main loop ---
i=0
while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    if [[ "$DURATION_SECS" -gt 0 ]]; then
        [[ "$ELAPSED" -ge "$DURATION_SECS" ]] && break
    else
        [[ "$i" -ge "$NUM_TOPICS" ]] && break
    fi
    i=$((i + 1))

    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: llama-server died mid-test (check $SERVER_LOG)" | tee -a "$STRESS_LOG"
        break
    fi

    CURRENT_TIME=$(date +%Y-%m-%d\ %H:%M:%S)
    ELAPSED_MIN=$((ELAPSED / 60))

    TOPIC_INDEX=$(((i - 1) % ${#TOPICS[@]}))
    TOPIC="${TOPICS[$TOPIC_INDEX]}"

    echo "=========================================" | tee -a "$STRESS_LOG"
    if [[ "$DURATION_SECS" -gt 0 ]]; then
        echo "Topic: $i (running for $TOPICS_ARG)" | tee -a "$STRESS_LOG"
    else
        echo "Topic: $i / $NUM_TOPICS" | tee -a "$STRESS_LOG"
    fi
    echo "Time: $CURRENT_TIME" | tee -a "$STRESS_LOG"
    echo "Elapsed: ${ELAPSED_MIN} minutes" | tee -a "$STRESS_LOG"
    echo "Prompt: ${TOPIC:0:80}..." | tee -a "$STRESS_LOG"
    echo "=========================================" | tee -a "$STRESS_LOG"

    ITER_START=$(date +%s)

    # Build JSON payload with streaming enabled
    PAYLOAD=$(jq -n \
        --arg prompt "$TOPIC" \
        --argjson n_predict "$N_PREDICT" \
        --argjson temperature "$TEMPERATURE" \
        --argjson repeat_penalty "$REPEAT_PENALTY" \
        '{
            prompt: $prompt,
            n_predict: $n_predict,
            temperature: $temperature,
            repeat_penalty: $repeat_penalty,
            stream: true
        }')

    LAST_CHUNK_FILE=$(mktemp)

    # Stream tokens live — each SSE chunk printed immediately as generated
    # Final chunk (stop=true) contains timing metrics, saved to temp file
    curl -s -X POST \
        "http://${SERVER_HOST}:${SERVER_PORT}/completion" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" \
        --no-buffer \
        --max-time "$CURL_MAX_TIME" 2>/dev/null | \
    while IFS= read -r line; do
        if [[ "$line" == data:* ]]; then
            JSON="${line#data: }"
            CONTENT=$(printf '%s' "$JSON" | jq -r '.content // ""' 2>/dev/null)
            STOP=$(printf '%s' "$JSON" | jq -r '.stop // false' 2>/dev/null)
            printf '%s' "$CONTENT"
            printf '%s' "$CONTENT" >> "$STRESS_LOG"
            if [[ "$STOP" == "true" ]]; then
                printf '%s\n' "$JSON" > "$LAST_CHUNK_FILE"
            fi
        fi
    done
    CURL_EXIT=${PIPESTATUS[0]}
    printf '\n' | tee -a "$STRESS_LOG"

    ITER_END=$(date +%s)
    ITER_DURATION=$((ITER_END - ITER_START))

    if [[ $CURL_EXIT -ne 0 ]]; then
        ERRORS=$((ERRORS + 1))
        CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
        echo "ERROR: curl failed (exit $CURL_EXIT) for topic $i" | tee -a "$STRESS_LOG"
        echo "Errors: $ERRORS total, $CONSECUTIVE_ERRORS consecutive" | tee -a "$STRESS_LOG"
        echo "" | tee -a "$STRESS_LOG"
        rm -f "$LAST_CHUNK_FILE"
        if [ $CONSECUTIVE_ERRORS -ge 5 ]; then
            echo "5 consecutive errors - server looks unhealthy, stopping stress test" | tee -a "$STRESS_LOG"
            break
        fi
        continue
    fi

    if [[ ! -s "$LAST_CHUNK_FILE" ]]; then
        ERRORS=$((ERRORS + 1))
        CONSECUTIVE_ERRORS=$((CONSECUTIVE_ERRORS + 1))
        echo "ERROR: No completion received from server for topic $i" | tee -a "$STRESS_LOG"
        echo "Errors: $ERRORS total, $CONSECUTIVE_ERRORS consecutive" | tee -a "$STRESS_LOG"
        echo "" | tee -a "$STRESS_LOG"
        rm -f "$LAST_CHUNK_FILE"
        if [ $CONSECUTIVE_ERRORS -ge 5 ]; then
            echo "5 consecutive errors - server looks unhealthy, stopping stress test" | tee -a "$STRESS_LOG"
            break
        fi
        continue
    fi

    CONSECUTIVE_ERRORS=0

    # Extract metrics from final SSE chunk (stop=true contains full timings)
    TOKENS_PREDICTED=$(jq -r '.tokens_predicted // 0' < "$LAST_CHUNK_FILE")
    TOKENS_PER_SEC_RAW=$(jq -r '.timings.predicted_per_second // 0' < "$LAST_CHUNK_FILE")
    PROMPT_TOKENS=$(jq -r '.tokens_evaluated // 0' < "$LAST_CHUNK_FILE")
    PROMPT_PER_SEC=$(jq -r '.timings.prompt_per_second // 0' < "$LAST_CHUNK_FILE")
    rm -f "$LAST_CHUNK_FILE"

    echo "" | tee -a "$STRESS_LOG"

    TOTAL_TOKENS=$((TOTAL_TOKENS + TOKENS_PREDICTED))
    TOKENS_PER_SEC_SAMPLES=$((TOKENS_PER_SEC_SAMPLES + 1))
    TOTAL_TOKENS_PER_SEC=$(awk "BEGIN {printf \"%.2f\", $TOTAL_TOKENS_PER_SEC + $TOKENS_PER_SEC_RAW}")

    AVG_TPS=$(awk "BEGIN {printf \"%.2f\", $TOTAL_TOKENS_PER_SEC / $TOKENS_PER_SEC_SAMPLES}")

    echo "Topic $i completed in ${ITER_DURATION}s" | tee -a "$STRESS_LOG"
    echo "  Prompt tokens    : $PROMPT_TOKENS @ $(printf '%.1f' "$PROMPT_PER_SEC") tok/s" | tee -a "$STRESS_LOG"
    echo "  Generated tokens : $TOKENS_PREDICTED @ $(printf '%.1f' "$TOKENS_PER_SEC_RAW") tok/s" | tee -a "$STRESS_LOG"
    echo "  Avg gen speed    : ${AVG_TPS} tok/s (over $TOKENS_PER_SEC_SAMPLES topics)" | tee -a "$STRESS_LOG"
    echo "  Total tokens     : $TOTAL_TOKENS" | tee -a "$STRESS_LOG"
    if [[ "$DURATION_SECS" -gt 0 ]]; then
        NOW_ELAPSED=$(($(date +%s) - START_TIME))
        echo "  Progress         : ${NOW_ELAPSED}s / ${DURATION_SECS}s ($(awk "BEGIN {printf \"%.1f\", ($NOW_ELAPSED/$DURATION_SECS)*100}")%)" | tee -a "$STRESS_LOG"
    else
        echo "  Progress         : $i/$NUM_TOPICS ($(awk "BEGIN {printf \"%.1f\", ($i/$NUM_TOPICS)*100}")%)" | tee -a "$STRESS_LOG"
    fi
    echo "" | tee -a "$STRESS_LOG"

    # No sleep needed — server handles pacing; add if thermal throttling observed
done

# --- Final summary ---
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
TOTAL_HOURS=$((TOTAL_DURATION / 3600))
TOTAL_MINUTES=$(((TOTAL_DURATION % 3600) / 60))
FINAL_AVG_TPS=0
if [[ $TOKENS_PER_SEC_SAMPLES -gt 0 ]]; then
    FINAL_AVG_TPS=$(awk "BEGIN {printf \"%.2f\", $TOTAL_TOKENS_PER_SEC / $TOKENS_PER_SEC_SAMPLES}")
fi

echo "" | tee -a "$STRESS_LOG"
echo "=========================================" | tee -a "$STRESS_LOG"
echo "Stress Test Complete!" | tee -a "$STRESS_LOG"
echo "=========================================" | tee -a "$STRESS_LOG"
echo "End time: $(date)" | tee -a "$STRESS_LOG"
echo "Total duration      : ${TOTAL_HOURS}h ${TOTAL_MINUTES}m" | tee -a "$STRESS_LOG"
echo "Model load time     : ${LOAD_DURATION}s (one-time)" | tee -a "$STRESS_LOG"
if [[ "$DURATION_SECS" -gt 0 ]]; then
    echo "Topics completed    : $i (target length: $TOPICS_ARG)" | tee -a "$STRESS_LOG"
else
    echo "Topics completed    : $i / $NUM_TOPICS" | tee -a "$STRESS_LOG"
fi
echo "Total tokens        : $TOTAL_TOKENS" | tee -a "$STRESS_LOG"
echo "Avg gen throughput  : ${FINAL_AVG_TPS} tok/s" | tee -a "$STRESS_LOG"
echo "Total errors        : $ERRORS" | tee -a "$STRESS_LOG"

# Thermal summary from the monitor CSV
if [ -f "$MONITOR_LOG" ]; then
    read -r PEAK_GPU_T PEAK_POW PEAK_SOC_T <<< "$(awk -F, '
        NR>1 { if ($2+0>t) t=$2+0; if ($4+0>p) p=$4+0; if ($6+0>s) s=$6+0 }
        END  { printf "%d %.1f %d", t, p, s }' "$MONITOR_LOG")"
    echo "Peak GPU temp       : ${PEAK_GPU_T}C (warn ${TEMP_WARN}C / crit ${TEMP_CRIT}C)" | tee -a "$STRESS_LOG"
    echo "Peak SoC temp       : ${PEAK_SOC_T}C" | tee -a "$STRESS_LOG"
    echo "Peak power draw     : ${PEAK_POW}W" | tee -a "$STRESS_LOG"
    if [ -s "$ALERT_LOG" ]; then
        echo "Thermal alerts      : $(wc -l < "$ALERT_LOG") (see $ALERT_LOG)" | tee -a "$STRESS_LOG"
    else
        echo "Thermal alerts      : none" | tee -a "$STRESS_LOG"
    fi
fi
echo "" | tee -a "$STRESS_LOG"
echo "Stress log  : $STRESS_LOG" | tee -a "$STRESS_LOG"
echo "Server log  : $SERVER_LOG" | tee -a "$STRESS_LOG"
echo "Monitor CSV : $MONITOR_LOG" | tee -a "$STRESS_LOG"
echo "" | tee -a "$STRESS_LOG"

# --- Final GPU status ---
echo "Final GPU Status:" | tee -a "$STRESS_LOG"
nvidia-smi | tee -a "$STRESS_LOG"
