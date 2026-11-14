#!/usr/bin/env python3
"""Local-only CUDA burn-in supervisor. Python stdlib; no installers or network."""
import argparse
import csv
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

GIB = 1024**3

def command(args, timeout=10):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, check=True).stdout

def available_memory():
    values = dict(line.split(':', 1) for line in Path('/proc/meminfo').read_text().splitlines())
    return int(values['MemAvailable'].split()[0]) * 1024

def sensor_readings(root=Path('/sys/class/hwmon')):
    readings = {}
    for folder in root.glob('hwmon*'):
        name = (folder / 'name').read_text().strip()
        for item in folder.glob('temp*_input'):
            value = float(item.read_text()) / 1000
            if not math.isfinite(value):
                raise RuntimeError('non-finite temperature')
            readings[f'{name}:{folder.name}:{item.name}'] = value
    for zone in Path('/sys/class/thermal').glob('thermal_zone*') if root == Path('/sys/class/hwmon') else []:
        value = float((zone / 'temp').read_text()) / 1000
        if not math.isfinite(value):
            raise RuntimeError('non-finite thermal zone')
        readings[f'thermal:{zone.name}:{(zone / "type").read_text().strip()}'] = value
    if not any(key.startswith('acpitz') for key in readings):
        raise RuntimeError('ACPI temperature sensors unavailable')
    if not any(key.startswith('nvme:') for key in readings):
        raise RuntimeError('NVMe temperature sensors unavailable')
    return readings

def policy(gpu_temp, available, sensors):
    if not math.isfinite(gpu_temp) or gpu_temp < 0:
        return 'GPU temperature invalid'
    if gpu_temp >= 80:
        return 'GPU temperature >= 80C'
    if available < 8 * GIB:
        return 'host MemAvailable < 8 GiB'
    for name, value in sensors.items():
        limit = 70 if name.startswith('nvme:') else 85
        if value >= limit:
            return f'{name} temperature >= {limit}C'
    return None

def atomic_json(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    tmp.replace(path)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--seconds', type=int, default=36000)
    parser.add_argument('--gib', type=float, default=80)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--cpu-worker', type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 86400 or not math.isfinite(args.gib) or not .125 <= args.gib <= 90:
        parser.error('seconds 1..86400; GiB 0.125..90')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)  # Never overwrite previous evidence.
    result = {'status': 'RUNNING', 'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
              'seconds_requested': args.seconds, 'gib_requested': args.gib,
              'scope': 'GPU TF32 GEMM + checked GPU global memory + all CPU threads; no disk/NIC qualification'}
    worker = None
    cpu_worker = None
    cpu_log = None
    started = time.monotonic()
    stop_requested = False
    def stop(signum, frame):
        nonlocal stop_requested
        stop_requested = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    code = 1
    try:
        if available_memory() < (args.gib + 10) * GIB:
            raise RuntimeError('not enough host memory; need workload + 10 GiB reserve')
        baseline = command(['journalctl', '-k', '-b', '-o', 'json', '--no-pager'])
        (output / 'kernel-baseline.jsonl').write_text(baseline)
        entries = [json.loads(line) for line in baseline.splitlines() if line]
        if not entries:
            raise RuntimeError('kernel journal unavailable')
        cursor = entries[-1]['__CURSOR']
        (output / 'nvidia-before.txt').write_text(command(['nvidia-smi', '-q']))
        (output / 'meminfo-before.txt').write_text(Path('/proc/meminfo').read_text())
        initial_gpu = float(command(['nvidia-smi', '--query-gpu=temperature.gpu', '--format=csv,noheader,nounits']).strip())
        initial_problem = policy(initial_gpu, available_memory(), sensor_readings())
        if initial_problem:
            raise RuntimeError(initial_problem)
        expected_sensors = set(sensor_readings())
        atomic_json(output / 'summary.json', result)
        with (output / 'samples.csv').open('w', buffering=1) as samples, (output / 'kernel-new.jsonl').open('w', buffering=1) as kernel, (output / 'worker.log').open('w', buffering=1) as log:
            writer = csv.writer(samples)
            writer.writerow(['utc', 'elapsed_s', 'gpu_temp_c', 'gpu_util_pct', 'power_w', 'sm_clock_mhz', 'mem_available_bytes', 'sensors_json'])
            cpu_log = (output / 'cpu.log').open('w', buffering=1)
            cpu_worker = subprocess.Popen([str(args.cpu_worker.resolve()), str(args.seconds + 120)], stdout=cpu_log, stderr=subprocess.STDOUT)
            worker = subprocess.Popen([str(args.worker.resolve()), str(args.gib), str(args.seconds)], stdout=log, stderr=subprocess.STDOUT)
            last_sample = -10.0
            next_hour = 3600
            peaks = {}
            while True:
                elapsed = time.monotonic() - started
                if stop_requested:
                    raise InterruptedError('operator/service stop')
                if cpu_worker.poll() is not None:
                    raise RuntimeError(f'CPU worker exited early: {cpu_worker.returncode}')
                if time.time() - (output / 'cpu.log').stat().st_mtime > 30:
                    raise RuntimeError('CPU heartbeat missing for 30 seconds')
                if elapsed > args.seconds + 150:
                    raise RuntimeError('wall-clock deadline exceeded')
                if elapsed - last_sample >= 10 or worker.poll() is not None:
                    raw = command(['nvidia-smi', '--query-gpu=temperature.gpu,utilization.gpu,power.draw,clocks.sm', '--format=csv,noheader,nounits'], 8).strip()
                    fields = [field.strip() for field in raw.split(',')]
                    if len(fields) != 4:
                        raise RuntimeError('unexpected GPU telemetry')
                    temp = float(fields[0])
                    sensors = sensor_readings()
                    if set(sensors) != expected_sensors:
                        raise RuntimeError('temperature sensor set changed')
                    available = available_memory()
                    writer.writerow([time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), round(elapsed, 2), *fields, available, json.dumps(sensors, sort_keys=True)])
                    all_temps = dict(sensors, gpu=temp)
                    for name, value in all_temps.items():
                        peaks[name] = max(value, peaks.get(name, value))
                    result.update(elapsed_s=round(elapsed, 2), temperature_peaks_c=peaks, mem_available_bytes=available)
                    atomic_json(output / 'summary.json', result)
                    if elapsed >= next_hour:
                        message = {'hour': int(elapsed // 3600), 'elapsed_s': round(elapsed), 'gpu_temp_c': temp, 'temperature_peaks_c': peaks, 'mem_available_bytes': available, 'status': 'RUNNING'}
                        with (output / 'hourly.jsonl').open('a') as hourly:
                            hourly.write(json.dumps(message) + '\n')
                        print(json.dumps(message), flush=True)
                        next_hour += 3600
                    problem = policy(temp, available, sensors)
                    if problem:
                        raise RuntimeError(problem)
                    updates = command(['journalctl', '-k', '-b', '--after-cursor=' + cursor, '-o', 'json', '--no-pager'])
                    if updates:
                        kernel.write(updates)
                        new_entries = [json.loads(line) for line in updates.splitlines() if line]
                        for entry in new_entries:
                            cursor = entry['__CURSOR']
                            if int(entry.get('PRIORITY', 6)) <= 4:
                                raise RuntimeError('new kernel warning/error: ' + entry.get('MESSAGE', 'unknown'))
                    if time.time() - (output / 'worker.log').stat().st_mtime > 120:
                        raise RuntimeError('worker heartbeat missing for 120 seconds')
                    last_sample = elapsed
                rc = worker.poll()
                if rc is not None:
                    if rc != 0:
                        raise RuntimeError(f'worker exited {rc}')
                    text = (output / 'worker.log').read_text()
                    if 'COMPLETE cycles=' not in text or 'PASS cycle=' not in text:
                        raise RuntimeError('missing workload completion evidence')
                    if elapsed < args.seconds:
                        raise RuntimeError('worker finished before requested duration')
                    result['status'] = 'PASS'
                    code = 0
                    break
                time.sleep(.5)
    except InterruptedError as exc:
        result.update(status='STOPPED', reason=str(exc)); code = 130
    except Exception as exc:
        result.update(status='FAIL', reason=f'{type(exc).__name__}: {exc}')
    finally:
        if worker is not None and worker.poll() is None:
            worker.terminate()
            try:
                worker.wait(timeout=10)
            except subprocess.TimeoutExpired:
                worker.kill()
                try:
                    worker.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    result.update(status='FAIL', reason='GPU worker did not terminate; possible driver hang')
                    code = 1
        if cpu_worker is not None and cpu_worker.poll() is None:
            cpu_worker.terminate()
            try:
                cpu_worker.wait(timeout=5)
            except subprocess.TimeoutExpired:
                cpu_worker.kill()
                cpu_worker.wait(timeout=2)
        if cpu_worker is not None:
            result['cpu_exit'] = cpu_worker.poll()
            if code == 0 and cpu_worker.returncode != 0:
                result.update(status='FAIL', reason='CPU worker failed at shutdown')
                code = 1
        if cpu_log is not None:
            cpu_log.close()
        result['elapsed_s'] = round(time.monotonic() - started, 3)
        result['ended_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
        result['worker_exit'] = worker.poll() if worker else None
        atomic_json(output / 'summary.json', result)
        print(json.dumps(result), flush=True)
    return code

if __name__ == '__main__':
    sys.exit(main())
