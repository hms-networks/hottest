# Adds a small util to test char devices (developed for serial ports) on both
# the host machine and the DUT.

#|include <util/crosscompilation/crosscompile>

function char_dev_rw_create_c_file() {
  cat << 'CHAR_DEV_RW_C_EOF' > ./char-dev-rw.c
#include <stdio.h>
#include <stdlib.h>
#include <getopt.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <sched.h>
#include <unistd.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <inttypes.h>
#include <termios.h>

#define START_VALUE ((uint8_t) 0xcc)
/*---------------------------------------------------------------------------*/
struct send_burst {
  unsigned long bytes;
  unsigned long pause_us;
};
/*---------------------------------------------------------------------------*/
struct port_settings {
  unsigned long baudrate;
  unsigned long bitschar;
  unsigned long overhead;
};
/*---------------------------------------------------------------------------*/
static void print_usage (FILE* f)
{
  fputs(
"Usage for receiving:\n"
"  char-dev-rw-tester -F <dev> -r <expected byte count> <total listen microsec>"
"\n"
"\n"
"Usage for sending:\n"
"  char-dev-rw-tester -F <dev> [<byte count> <microsec pause>].."
"\n"
"  ...where the sequence [<char count> <microsec pause>] can be repeated\n"
"  as many times as necessary. It allows simulating burst transfers\n"
"\n"
"Usage for calculating the theoretical transfer time:\n"
"  char-dev-rw-tester -c 115200:10 [<byte count> <microsec pause>]"
"\n"
"  ...where 115200 is the baudrate and and 10 the bits/byte. The other\n"
"  parameters work like on sending mode.\n",
  f
  );
}
/*---------------------------------------------------------------------------*/
static void print_help (FILE* f)
{
  fputs(
"char-dev-rw-test\n"
"\n"
"Program that either sends or receives and tries to match a known send\n"
"Intended for testing communications based on char devices.\n"
"\n"
"This program just does the sending/receiving. The configuration has to\n"
"be done externally, e.g. for serial devices with the \"stty\" utility.\n"
"When it's used as a receiver the external configuration must make the\n"
"\"read\" syscall to return periodically (timeout).\n"
"\n",
  f
  );
  print_usage (f);
}
/*---------------------------------------------------------------------------*/
static uint64_t get_microsec (void)
{
  struct timespec t;
  clock_gettime (CLOCK_MONOTONIC_RAW /*non POSIX*/, &t);
  return (uint64_t) ((((uint64_t) t.tv_sec) * 1000000) + (t.tv_nsec / 1000));
}
/*---------------------------------------------------------------------------*/
static int send (int fd, struct send_burst const* sb, int sb_count)
{
  uint8_t buff[128];
  uint8_t curr_byte = START_VALUE;

  uint64_t send_start  = get_microsec();
  uint64_t total_bytes = 0;

  for (struct send_burst const* it = sb; it < (sb + sb_count); ++it) {
    unsigned long bytes = it->bytes;
    total_bytes        += bytes;
    while (bytes) {
      unsigned long count = (bytes < sizeof buff) ? bytes : sizeof buff;
      bytes -= count;
      for (unsigned long i = 0; i < count; ++i) {
        buff[i] = curr_byte++;
      }
      int n = write (fd, buff, count);
      if (n != count) {
        fprintf (stderr, "Error when writing fd: %s\n", strerror (errno));
        return 1;
      }
    }
    if (it->pause_us == 0) {
      continue;
    }
    uint64_t start = get_microsec();
    uint64_t now   = start;
    while ((now - start) <= it->pause_us) {
      sched_yield();
      now = get_microsec();
    }
  }
  printf (
    "%"PRIu64" bytes transfered in %f seconds\n",
    total_bytes, ((double) (get_microsec() - send_start)) / 1000000.
    );
  return 0;
}
/*---------------------------------------------------------------------------*/
static int calculate(
  struct port_settings const* ps, struct send_burst const* sb, int sb_count
  )
{
  uint64_t bytes    = 0;
  uint64_t pause_us = 0;
  uint64_t pause_us_last = 0;

  for (struct send_burst const* it = sb; it < (sb + sb_count); ++it) {
    bytes += it->bytes;
    pause_us_last = it->pause_us;
    pause_us += pause_us_last;
  }
  pause_us -= pause_us_last; /*all bytes are received before the last pause*/
  /* overkill but correct I guess */
  uint64_t chars    = ((bytes * 8) + ps->bitschar - 1) / ps->bitschar;
  uint64_t overhead = chars * ps->overhead;
  uint64_t bits     = (chars * ps->bitschar) + overhead;

  double ts = ((double) bits) / ((double) ps->baudrate);
  ts       += ((double) pause_us) / 1000000.;
  printf ("%llu bytes\n", (unsigned long long) bytes);
  printf ("%f seconds\n", ts);
  return 0;
}
/*---------------------------------------------------------------------------*/
static int receive (int fd, unsigned long count, unsigned long listen_us)
{
  uint8_t buff[128];
  uint8_t       nextbyte = START_VALUE;
  uint64_t      start    = get_microsec();
  uint64_t      now      = start;
  unsigned long received = 0;

  while (((now - start) <= listen_us) && received < count){
    int n = read (fd, buff, sizeof buff);
    if (n < 0) {
      fprintf (stderr, "Error when reading fd: %s\n", strerror (errno));
      return 1;
    }
    for (int i = 0; i < n; ++i) {
      if (buff[i] != nextbyte) {
        fprintf(
          stderr,
          "Wrong byte. number: %lu, value: %d, expected: %d\n",
          received + i, (int) buff[i], (int) nextbyte
          );
        return 1;
      }
      ++nextbyte;
    }
    received += n;
    now = get_microsec();
  }
  if (received != count) {
    fprintf(
      stderr,
      "Bytes count mismatch. expected: %lu, got: %lu\n",
      count, received
      );
    int lastread = read (fd, buff, sizeof buff);
    if (lastread > 0) {
      fprintf(
        stderr,
        "The device buffer had unread data. Maybe the timeout was too short.\n"
      );
    }
    return 1;
  }
  printf(
    "%lu bytes correctly matched in %f seconds\n",
    count,
    ((double) (get_microsec() - start)) / 1000000.
    );
  return 0;
}
/*---------------------------------------------------------------------------*/
static int parse_ul (unsigned long* v, char const* str)
{
  char* end;
  errno = 0;
  *v = strtoul (str, &end, 10);
  if (((*v == ULONG_MAX) && errno) || str[0] == '-' || *end != 0) {
    fprintf (stderr, "Invalid unsigned int value: %s\n", str);
    return 1;
  }
  return 0;
}
/*---------------------------------------------------------------------------*/
static struct port_settings parse_port_settings (char const* str)
{
  struct port_settings ps;
  char* rwstr = strdup (str);

  memset (&ps, sizeof ps, 0);
  if (!rwstr) {
    fputs ("Unable to allocate memory\n", stderr);
    return ps;
  }
  char* mode = strchr (rwstr, ':');
  if (!mode) {
    fputs(
      "Port settings are specified as: \"<port>:<mode>\". Couldn't find ':' character separator.",
      stderr
      );
    goto do_free;
  }
  *mode = 0;
  ++mode;
  if (strlen (mode) != 3) {
    fprintf (stderr, "Invalid string length on serial port mode value: \"%s\"\n", mode);
    goto do_free;
  }
  switch (*mode) {
    case '5': ps.bitschar = 5; break;
    case '6': ps.bitschar = 6; break;
    case '7': ps.bitschar = 7; break;
    case '8': ps.bitschar = 8; break;
    default:
      fprintf (stderr, "Invalid serial port mode bits: %c\n", *mode);
      goto do_free;
  }
  ++mode;
  switch (*mode) {
    case 'n': /* deliberate fall-through*/
    case 'N': break;
    case 'e': /* deliberate fall-through*/
    case 'E': /* deliberate fall-through*/
    case 'o': /* deliberate fall-through*/
    case 'O': ps.overhead += 1; break;
    default:
      fprintf (stderr, "Invalid serial port mode parity: %c\n", *mode);
      goto do_free;
  }
  ++mode;
  switch (*mode) {
    case '1': ps.overhead += 1; break;
    case '2': ps.overhead += 2; break;
    default:
      fprintf (stderr, "Invalid serial port mode stop bits: %c\n", *mode);
      goto do_free;
  }
  if (parse_ul (&ps.baudrate, rwstr) != 0) {
    ps.baudrate = 0;
    goto do_free;
  }
do_free:
  free (rwstr);
  return ps;
}
/*---------------------------------------------------------------------------*/
enum mode {
  m_sender,
  m_receiver,
  m_calculator,
};
/*---------------------------------------------------------------------------*/
int main (int argc, char* argv[])
{
  struct port_settings portsettings;
  const char* filename = NULL;
  int mode = m_sender;
  int c;

  while ((c = getopt (argc, argv, "hrF:c:")) != -1) {
    switch (c) {
    case 'r':
      mode = m_receiver;
      break;
    case 'c':
      mode = m_calculator;
      portsettings = parse_port_settings (optarg);
      if (portsettings.baudrate == 0) {
        return 1;
      }
      break;
    case 'F':
      filename = optarg;
      break;
    case 'h':
      print_help (stdout);
      return 0;
    default:
      fprintf (stderr, "Invalid argument.\n");
      print_usage (stderr);
      return 1;
    }
  }
  if (mode == m_calculator) {
    filename = NULL;
  }
  else if (filename == NULL) {
    fputs ("(-F) not specified. No device to open.\n", stderr);
    print_usage (stderr);
    return 1;
  }
  /*validate the positional arguments*/
  int poscount = 0;
  for (int i = optind; i != argc; ++i, ++poscount) {
    if (mode == m_receiver && poscount > 2) {
      fputs ("Too many arguments for a receiver.\n", stderr);
      print_usage (stderr);
      return 1;
    }
    unsigned long v;
    if (parse_ul (&v, argv[i]) != 0) {
      return 1;
    }
  }
  if (mode != m_receiver) {
    if (poscount == 0) {
      fprintf (stderr, "Sender/calculator mode requires at least one positional argument\n");
      print_usage (stderr);
      return 1;
    }
  }
  else if (poscount != 2) {
    fprintf (stderr, "A receiver requires exactly two positional arguments\n");
    print_usage (stderr);
    return 1;
  }
  char** pos = &argv[optind];
  int fd;
  if (filename) {
    fd = open (filename, O_RDWR | O_NOCTTY | O_SYNC);
    if (fd < 0) {
      fprintf (stderr, "Unable to open file: %s\n", filename);
      return 1;
    }
    tcflush (fd, TCIOFLUSH);
  }
  int ret = 0;
  if (mode == m_receiver) {
    ret = receive(
      fd, strtoul (pos[0], NULL, 10), strtoul (pos[1], NULL, 10)
      );
  }
  else {
    int sb_count = (poscount + 1) / 2;
    struct send_burst* sb;
    sb = malloc (sb_count * sizeof *sb);
    if (!sb) {
      ret = 1;
      fputs ("Unable to allocate memory\n", stderr);
      goto do_close;
    }
    for (int i = 0; i < poscount; ++i) {
      struct send_burst* s = sb + (i / 2);
      if ((i % 2) == 0) {
        s->bytes    = strtoul (pos[i], NULL, 10);
        s->pause_us = 0;
      }
      else {
        s->pause_us = strtoul (pos[i], NULL, 10);
      }
    }
    if (mode == m_sender) {
      ret = send (fd, sb, sb_count);
    }
    else {
      ret = calculate (&portsettings, sb, sb_count);
    }
    free (sb);
  }
do_close:
  if (filename) {
    close (fd);
  }
  return ret;
}
/*---------------------------------------------------------------------------*/
CHAR_DEV_RW_C_EOF
}
add_step_before_dut_power_on char_dev_rw_create_c_file

function char_dev_rw_compile() {
    local execname=${1:-char-dev-rw}
    local cc=${CC:-cc}
    $cc char-dev-rw.c -o $execname
}
add_required_host_executables cc
add_step_before_dut_power_on char_dev_rw_compile

function char_dev_rw_compile_dut() {
    char_dev_rw_compile char-dev-rw_dut
}
add_step_to_crosscompile char_dev_rw_compile_dut

function char_dev_rw_dut_transfer() {
    dut_put char-dev-rw_dut char-dev-rw
}
add_step_before_test_run char_dev_rw_dut_transfer
