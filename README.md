# Audited GB10 CUDA burn-in

Replacement for the original LLM/SDXL suite. See [AUDIT.md](AUDIT.md) for the rejected behavior, review scope, guards and limitations. Existing CUDA 13, cuBLAS, Python 3 and journal access required. No automatic dependency installation. CPU workload uses all hardware threads and checked private 32 MiB buffers.

Build on the MSI (unprivileged):

```
/usr/local/cuda/bin/nvcc -O3 -arch=sm_121 burnin.cu -lcublas -o burnin
g++ -O3 -std=c++17 -pthread cpu.cpp -o cpu
python3 -m unittest -v test_policy
```

Run `supervise.py --help` for arguments. Default workload is all CPU threads, 128 GEMMs per cycle, and 80 GiB of checked GPU global memory plus ~768 MiB of GEMM matrices, for 10 hours. Start with a short preflight. Do not run the CUDA binary unattended without its supervisor and service deadline.

This repository's service template is configured for the owner's MSI user `e` and installation directory `/home/e/acceptance/burnin-suite`. It is not enabled at boot. With the template installed, launch a unique run:

```
sudo systemctl start msi-burnin@$(date -u +%Y%m%dT%H%M%SZ)
```

Reports are under `/home/e/acceptance/burnin-runs/10h-<instance>/`. The laptop and SSH connection can be shut down. Stopping the MSI or losing power interrupts the test; it does not resume or claim PASS.

```
systemctl list-units 'msi-burnin@*'
sudo systemctl stop msi-burnin@<instance>
cat /home/e/acceptance/burnin-runs/10h-<instance>/summary.json
```

`summary.json` stays RUNNING during execution, then records PASS, FAIL or STOPPED. `worker.log` records every fully verified cycle. `samples.csv` contains the temperature/utilization/power/clock/memory samples every 10 seconds. A RUNNING file without an active service means an incomplete run. Preserve all reports.

All available hwmon and thermal-zone temperatures plus NVIDIA GPU temperature are logged every 10 seconds. Each hourly summary is written locally to hourly.jsonl and the service journal; no laptop polling is required. An unavailable or changed sensor set stops the test.

`run-10h.sh` starts the installed service with a unique name and rejects a concurrent test.

No model download, root workload, disk write benchmark, firmware update, shell-history manipulation, blanket cache deletion or output cleanup. No automatic PASS for pre-existing platform warnings: they remain documented baseline exclusions accepted by the owner.
