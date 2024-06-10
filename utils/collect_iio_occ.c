#include <assert.h>  // assert() function
#include <errno.h>   // errno support
#include <fcntl.h>   // for open()
#include <math.h>    // for pow() function used in RAPL computations
#include <signal.h>  // for signal handler
#include <stdint.h>  // standard integer types, e.g., uint32_t
#include <stdio.h>   // printf, etc
#include <stdlib.h>  // exit() and EXIT_FAILURE
#include <string.h>  // strerror() function converts errno to a text string for printing
#include <sys/ipc.h>
#include <sys/mman.h>  // support for mmap() function
#include <sys/shm.h>
#include <sys/time.h>  // for gettimeofday
#include <time.h>
#include <unistd.h>  // sysconf() function, sleep() function

#define LOG_FREQUENCY 1
#define LOG_PRINT_FREQUENCY 20
#define LOG_SIZE 100000
#define WEIGHT_FACTOR 8
#define WEIGHT_FACTOR_LONG_TERM 256
#define IRP_MSR_PMON_CTL_BASE 0x0A5BL
#define IRP_MSR_PMON_CTR_BASE 0x0A59L
#define IIO_PCIE_1_PORT_0_BW_IN \
  0x0B20  // We're concerned with PCIe 1 stack on our machine (Table 1-11 in
          // Intel Skylake Manual)
#define IRP_OCC_VAL 0x0040040F
// #define STACK 1  // We're concerned with stack #1 on our machine
// #define CORE 28
// #define NUM_LCORES 32  // Number of (logical) cores

int *msr_fd;  // msr device driver files will be read from various
              // functions, so make descriptors global

FILE *log_file;

struct log_entry {
  uint64_t l_tsc;               // latest TSC
  uint64_t td_ns;               // latest measured time delta in us
  uint64_t avg_occ;             // latest measured avg IIO occupancy
  uint64_t s_avg_occ;           // latest calculated smoothed occupancy
  uint64_t s_avg_occ_longterm;  // latest calculated smoothed occupancy long
                                // term
  int core;                     // current core
};

struct log_entry iio_log[LOG_SIZE];
uint32_t log_index = 0;
uint32_t counter = 0;
uint64_t prev_rdtsc = 0;
uint64_t cur_rdtsc = 0;
uint64_t prev_cum_occ = 0;
uint64_t cur_cum_occ = 0;
uint64_t prev_cum_frc = 0;
uint64_t cur_cum_frc = 0;
uint64_t tsc_sample = 0;
uint64_t msr_num;
uint64_t rc64;
uint64_t cum_occ_sample = 0;
uint64_t cum_frc_sample = 0;
uint64_t latest_avg_occ = 0;
uint64_t latest_avg_pcie_bw = 0;
uint64_t latest_time_delta = 0;
uint64_t smoothed_avg_occ = 0;
uint64_t smoothed_avg_occ_longterm = 0;
uint64_t smoothed_avg_pcie_bw = 0;
float smoothed_avg_occ_f = 0.0;
float smoothed_avg_occ_longterm_f = 0.0;
float smoothed_avg_pcie_bw_f = 0.0;
uint64_t latest_time_delta_us = 0;
uint64_t latest_time_delta_ns = 0;

static inline __attribute__((always_inline)) unsigned long rdtsc() {
  unsigned long a, d;

  __asm__ volatile("rdtsc" : "=a"(a), "=d"(d));

  return (a | (d << 32));
}

static inline __attribute__((always_inline)) unsigned long rdtscp() {
  unsigned long a, d, c;

  __asm__ volatile("rdtscp" : "=a"(a), "=d"(d), "=c"(c));

  return (a | (d << 32));
}

extern inline __attribute__((always_inline)) int get_core_number() {
  unsigned long a, d, c;

  __asm__ volatile("rdtscp" : "=a"(a), "=d"(d), "=c"(c));

  return (c & 0xFFFUL);
}

void rdmsr_userspace(int core, uint64_t rd_msr, uint64_t *rd_val_addr) {
  rc64 = pread(msr_fd[core], rd_val_addr, sizeof(rd_val_addr), rd_msr);
  if (rc64 != sizeof(rd_val_addr)) {
    fprintf(log_file, "ERROR: failed to read MSR %lx on Logical Processor %d",
            rd_msr, core);
    exit(-1);
  }
}

void wrmsr_userspace(int core, uint64_t wr_msr, uint64_t *wr_val_addr) {
  rc64 = pwrite(msr_fd[core], wr_val_addr, sizeof(wr_val_addr), wr_msr);
  fprintf(log_file, "pwrite(msr_fd[%d]=%d, %p, %lu, %lu) = %ld\n", core,
          msr_fd[core], wr_val_addr, sizeof(wr_val_addr), wr_msr, rc64);
  if (rc64 != 8) {
    fprintf(log_file,
            "ERROR writing to MSR device on core %d, write %ld bytes\n", core,
            rc64);
    exit(-1);
  }
}

static void update_log(int core) {
  iio_log[log_index % LOG_SIZE].l_tsc = cur_rdtsc;
  iio_log[log_index % LOG_SIZE].td_ns = latest_time_delta_ns;
  iio_log[log_index % LOG_SIZE].avg_occ = latest_avg_occ;
  iio_log[log_index % LOG_SIZE].s_avg_occ = smoothed_avg_occ;
  iio_log[log_index % LOG_SIZE].s_avg_occ_longterm = smoothed_avg_occ_longterm;
  iio_log[log_index % LOG_SIZE].core = core;
  ++log_index;
}

static void update_occ_ctl_reg(int core, int stack) {
  // program the desired CTL register to read the corresponding CTR value
  msr_num = IRP_MSR_PMON_CTL_BASE + (0x20 * stack) + 0;
  uint64_t wr_val = IRP_OCC_VAL;
  wrmsr_userspace(core, msr_num, &wr_val);
}

static void sample_iio_occ_counter(int core, int stack) {
  uint64_t rd_val = 0;
  msr_num = IRP_MSR_PMON_CTR_BASE + (0x20 * stack) + 0;
  rdmsr_userspace(core, msr_num, &rd_val);
  cum_occ_sample = rd_val;
  prev_cum_occ = cur_cum_occ;
  cur_cum_occ = cum_occ_sample;
}

static void sample_time_counter() {
  tsc_sample = rdtscp();
  prev_rdtsc = cur_rdtsc;
  cur_rdtsc = tsc_sample;
}

static void sample_counters(int core, int stack) {
  // first sample occupancy
  sample_iio_occ_counter(core, stack);
  // sample time at the last
  sample_time_counter();
  return;
}

static void update_occ(void) {
  // latest_time_delta_us = (cur_rdtsc - prev_rdtsc) / 3300;
  latest_time_delta_ns = ((cur_rdtsc - prev_rdtsc) * 10) / 33;
  if (latest_time_delta_ns > 0) {
    latest_avg_occ = (cur_cum_occ - prev_cum_occ) / (latest_time_delta_ns >> 1);
    if (latest_avg_occ > 10) {
      smoothed_avg_occ_f =
          ((((float)(WEIGHT_FACTOR - 1)) * smoothed_avg_occ_longterm_f) +
           latest_avg_occ) /
          ((float)WEIGHT_FACTOR);
      smoothed_avg_occ = (uint64_t)smoothed_avg_occ_f;

      smoothed_avg_occ_longterm_f = ((((float)(WEIGHT_FACTOR_LONG_TERM - 1)) *
                                      smoothed_avg_occ_longterm_f) +
                                     latest_avg_occ) /
                                    ((float)WEIGHT_FACTOR_LONG_TERM);
      smoothed_avg_occ_longterm = (uint64_t)smoothed_avg_occ_longterm_f;
    }
    // smoothed_avg_occ = ((7*smoothed_avg_occ) + latest_avg_occ) >> 3;
  }
  // (float(occ[i] - occ[i-1]) / ((float(time_us[i+1] - time_us[i])) * 1e-6 *
  // freq));
}

void main_init(int num_lcores, int core, int stack) {
  // initialize the log
  int i = 0;
  while (i < LOG_SIZE) {
    iio_log[i].l_tsc = 0;
    iio_log[i].td_ns = 0;
    iio_log[i].avg_occ = 0;
    iio_log[i].s_avg_occ = 0;
    iio_log[i].s_avg_occ_longterm = 0;
    iio_log[i].core = num_lcores;  // Dummy value to indicate uninitialized
    ++i;
  }
  update_occ_ctl_reg(core, stack);
}

void main_exit() {
  // dump iio_log info
  int i = 0;
  fprintf(
      log_file,
      "index,latest_tsc,time_delta_ns,avg_occ,s_avg_occ,s_avg_occ_long,core\n");
  while (i < LOG_SIZE) {
    fprintf(log_file, "%d,%lu,%lu,%lu,%lu,%lu,%d\n", i, iio_log[i].l_tsc,
            iio_log[i].td_ns, iio_log[i].avg_occ, iio_log[i].s_avg_occ,
            iio_log[i].s_avg_occ_longterm, iio_log[i].core);
    ++i;
  }
}

static void catch_function(int signal) {
  printf("Caught SIGCONT. Shutting down...\n");
  main_exit();
  exit(0);
}

int main(int argc, char const *argv[]) {
  if (signal(SIGINT, catch_function) == SIG_ERR) {
    fprintf(log_file, "An error occurred while setting the signal handler.\n");
    return EXIT_FAILURE;
  }

  char filename[100];
  sprintf(filename, "iio.csv");
  log_file = fopen(filename, "w+");
  if (log_file == 0) {
    fprintf(stderr, "ERROR %s when trying to open log file %s\n",
            strerror(errno), filename);
    exit(-1);
  }

  if (argc != 4) {
    fprintf(
        log_file,
        "Usage: %s <num_lcores> <core to use for measurement> <IIO stack>\n",
        argv[0]);
    exit(-1);
  }
  int num_lcores = atoi(argv[1]);
  // This is the core used to measure the IIO occupancy. Must be on the same
  // NUMA node as the NIC.
  int measure_core = atoi(argv[2]);
  int stack = atoi(argv[3]);

  msr_fd = (int *)malloc(sizeof(int) * num_lcores);

  for (int c = 0; c < num_lcores; ++c) {
    sprintf(filename, "/dev/cpu/%d/msr", c);
    msr_fd[c] = open(filename, O_RDWR);
    // printf("   open command returns %d\n",msr_fd[i]);
    if (msr_fd[c] == -1) {
      fprintf(log_file, "ERROR %s when trying to open %s\n", strerror(errno),
              filename);
      exit(-1);
    }
  }

  main_init(num_lcores, measure_core, stack);
  update_occ_ctl_reg(measure_core, stack);

  while (1) {
    sample_counters(measure_core, stack);
    update_occ();
    update_log(measure_core);
    ++counter;
  }

  main_exit();

  free(msr_fd);
  return 0;
}
