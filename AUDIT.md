# Audit and replacement

Upstream reviewed: jeffrymahbuubi/dgx-spark-stress-test, commit 651af7850c393b030f5717a5402344c2c8e4c83f. All tracked shell files, README and .gitignore read. Shell syntax checked without executing them. No upstream setup, downloader, binary or workload was executed on the target.

Upstream rejected under the owner's constraint that the test must do only stress testing:

- 0-setup.sh:43-44 installs system packages; :80 runs a network-delivered uv installer through a shell; :111 builds an unpinned llama.cpp; :132 extracts an external dgxtop binary without a pinned checksum.
- 6-stress-test-combined.sh:44 builds unpinned recursive stable-diffusion.cpp; :60-68 downloads weights from mutable main branches, without explicit SHA256 validation.
- 9-cleanup.sh:32-51 deletes shared user tools/caches, edits .bashrc, optionally clears shell history, and deletes the complete suite and its logs. This is a separate, explicitly prompted script; it is NOT automatically called by the workload. It is nevertheless outside the permitted scope.
- 5-stress-test-server.sh:220-224 records critical temperatures without aborting. Monitor failure is not supervised.
- 5-stress-test-server.sh:480-482 and :553-569 break on server death/repeated failures, then print a normal completion summary; no corresponding failure exit is enforced.
- 6-stress-test-combined.sh:113-114 tolerates repeated SDXL failures; the attempted batch count is not proof of successful GPU work.
- No full memory data verification, known-answer compute verification or kernel/AER error gate. Duration is checked between requests, not as a hard deadline.

These findings do not establish malicious intent. Transitive upstream source trees, installers and binary dependencies were not audited: the execution gate already failed before fetching them.

## Replacement

Legacy entry points removed on branch audited-cuda-burnin; upstream history retained. New burnin.cu and supervise.py are original code. No model downloads, network installers, cleanup/history editing, firmware operations, driver changes, filesystem benchmarks or privileged workload code.

CUDA workload alternates changing 64-bit indexed patterns across the allocated GPU global memory with complete readback comparison in a separate kernel, and 128 TF32-enabled 8192x8192 cuBLAS SGEMMs with complete known-answer output comparison. GPU global allocation uses GB10's physical unified memory. This is not a test of every byte of RAM or every unified-memory migration path, nor a complete instruction-set, NIC or SSD qualification. It does not promise a particular utilization percentage.

Supervisor uses only Python standard library and existing nvidia-smi/journalctl. It preserves pre-existing kernel messages as baseline and stops on NEW kernel messages of priority warning or higher. It stops at GPU >=90C, other hwmon sensors >=90C, NVMe >=70C, MemAvailable <8 GiB, missing/invalid required telemetry, lost heartbeat, nonzero worker exit or missed deadline. These are conservative test policies, not manufacturer-specified thermal limits. Firmware thermoprotection remains intact.

The original cpu.cpp adds all hardware CPU threads, each writing and checking a private 32 MiB integer-pattern buffer. Deliberate CPU corruption was detected with exit 4. The final owner-requested duration is 10 hours; systemd enforces 36,200 seconds including startup/cleanup.

Systemd runs as user e, NoNewPrivileges, filesystem read-only except the run directory, separate /tmp, AF_UNIX-only socket creation, 110 GiB process memory limit, control-group termination and a wall-clock deadline. GPU allocation accounting may differ from normal process RSS: free-memory polling remains necessary. Systemd is local to MSI and independent of SSH. No automatic restart after failure or reboot; an interrupted run is incomplete.

Each run has a fresh directory: summary.json (RUNNING/PASS/FAIL/STOPPED), worker.log, 10-second samples.csv (every available hwmon/thermal-zone sensor + GPU), hourly.jsonl, kernel-baseline.jsonl, kernel-new.jsonl and initial device/memory snapshots. Existing directories cannot be reused. A power loss may leave RUNNING: this is not PASS. Only the measured duration with workload COMPLETE and zero failures earns PASS.

## Verification record

- Python threshold tests passed locally and on target.
- Native CUDA compilation against installed CUDA/cuBLAS succeeded.
- Deliberate single-bit corruption detected exactly one memory mismatch, exit 4.
- First preflight stopped BEFORE workload launch because ACPI hwmon names include numeric suffixes. Sensor discovery fixed; failure evidence retained.
- GPU-only preflights: 8 GiB / 60 seconds PASS (112 cycles); 80 GiB / 120 seconds PASS (89 cycles). No new kernel warnings.
- Operator stop: service stopped, worker gone, summary STOPPED with exit 130 (not PASS).
- Final combined preflight: 80 GiB, 128 GEMMs/cycle, 20 CPU threads, 60-second request: PASS after 73.255 seconds including startup/cleanup; 7 GPU cycles, 102499 CPU buffer cycles, zero mismatches and no new kernel warnings. Peak recorded GPU 66C, hottest ACPI/SoC sensor 82.6C.
- Final template operator-stop validation preserved STOPPED and left no workload processes.
- The 10-hour result remains RUNNING until the on-device summary records completion. Short preflights do not establish 10-hour stability.

## Owner-authorized thermal policy revision

On 15 November 2026 the owner requested official limits or a 90C test guard. Read-only inspection of this MSI found every ACPI thermal zone critical trip at 104800 millidegrees C. This is an emergency trip, not an approved sustained operating limit. Published MSI/NVIDIA hardware pages examined did not establish a sustained die/ACPI-zone limit; ambient operating temperature must not be substituted for die temperature.

The test guard is now 90C GPU and non-NVMe sensors, with the independent 70C NVMe guard retained. Early CPU pause/resume logic was discarded: full CPU and GPU workloads remain continuous. Factory thermal protection, fans, clocks, power caps and firmware are unchanged.

The earlier 10-hour attempt stopped after 84.25 seconds at 85.2C under the old guard, without data mismatches or new kernel warnings. A brief experimental adaptive preflight failed on an 8-second nvidia-smi timeout during startup, not a thermal or computation fault; that experimental revision was discarded. Reporting retains both failed attempts. The previously tested 10-second sampling supervisor is used, with only the owner-authorized guard and corresponding tests changed.

Sources inspected: https://ipc.msi.com/product_detail/EdgeXpert-MS-C931 and https://docs.nvidia.com/dgx/dgx-spark/hardware.html . The device's own sysfs trip-point snapshot is saved on the MSI.

### 90C guard validation outcome

The 180-second full-load preflight ended FAIL after 193.329 seconds including startup/final sampling/cleanup: hottest acpitz_4 reading 91.1C, peak GPU average 75C. Polling is discrete, so a 90C stop policy can observe an overshoot. GPU workload completed 27 fully verified cycles (128 GEMMs/cycle and 80 GiB checked memory); CPU completed 261025 checked buffer cycles. Both worker exits were zero and there were no new kernel warnings. The supervisor correctly withheld PASS because its temperature guard was crossed. No repeat 10-hour attempt was started. This establishes a test-policy stop, not a confirmed manufacturer thermal fault.

## Current owner-requested run: four hours, 99C

The owner explicitly requested a 99C guard and four-hour full-load run. Changed only GPU/non-NVMe stop thresholds to 99C, default duration to 14400 seconds, service hard deadline to 14600 seconds and run-directory/launcher names. SSD remains 70C; all computation, kernel-error, telemetry and memory guards remain. CPU duty cycling remains disabled. Factory thermal management and trip points remain unchanged. The prior 90C result is retained as history; the four-hour result must be read from its new run directory.
