import collections
import sys

INPUT_FILE = sys.argv[1]

cpu_util = collections.defaultdict(float)
num_samples = collections.defaultdict(float)

with open(INPUT_FILE) as f1:
    for line in f1:
        if "CPU" not in line:
            elements = line.split()
            assert len(elements) == 8
            cpu = int(elements[1])
            idle = float(elements[7])
            cpu_util[cpu] += 100 - idle
            num_samples[cpu] += 1

total_util = 0
num_cpus = 0
for cpu in cpu_util:
    if num_samples[cpu] != 0:
        # Calculate average util for this CPU
        cpu_util[cpu] /= num_samples[cpu]
        # Sum up util for all CPUs
        total_util += cpu_util[cpu]
        num_cpus += 1

print("cpu_utils:", dict(cpu_util))
print("num_samples:", dict(num_samples))
print("avg_cpu_util:", "" if num_cpus == 0 else total_util / num_cpus)
