# The seq util, but outputs in hex and adds some hex controls (endianess, case
# and width).
#
# This util is mostly for usage on the tester side. So the crosscompilation
# dependencies aren't added by default. If you require this on the DUT do:
#
#  #|include <util/crosscompilation/crosscompile>
#  add_step_to_crosscompile hexseq_compile_dut
#  add_step_before_test_run hexseq_dut_transfer
#

function hexseq_create_c_file() {
    cat << 'BE_LE_HEXSEQ' > ./hexseq.c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <errno.h>
#include <ctype.h>
#include <getopt.h>
#include <endian.h>
/*---------------------------------------------------------------------------*/
static int parse_u64 (uint64_t* v, char const* str)
{
  char* last;
  errno = 0;
  for (; isspace (*str); ++str);
  *v = strtoull (str, &last, 10);
  if (((*v == UINT64_MAX) && errno) || str[0] == '-' || *last != 0) {
    fprintf (stderr, "Invalid 64-bit unsigned int value: %s\n", str);
    return 1;
  }
  return 0;
}
/*---------------------------------------------------------------------------*/
#define DEF_FMT "%016"PRIx64"\n"
#define DIV_CEIL(x, y) (((x) + (y) - 1) / (y))
/*---------------------------------------------------------------------------*/
void print_usage(void) {
  puts(
    "Usage: hexseq <first> <last> [-b big endian] [-u uppercase] [-w <char width>]"
    );
}
/*---------------------------------------------------------------------------*/
int main (int argc, char* argv[])
{
  uint64_t limits[2];
  uint64_t width = 255;
  int le = 1;
  int upper = 0;
  int c;
  char fmt[sizeof DEF_FMT];

  while ((c = getopt (argc, argv, "buhw:")) != -1) {
    switch (c) {
    case 'b':
      le = 0;
      break;
    case 'h':
      print_usage();
      return 0;
    case 'u':
      upper = 1;
      break;
    case 'w':
      if (parse_u64 (&width, optarg) != 0) {
        return 1;
      }
      if (width > 16) {
        fprintf(
          stderr, "Char width > 16 (64 bit). Add 0's with e.g. sed.\n"
          );
        return 1;
      }
      break;
    default:
      fprintf (stderr, "Invalid option flag: %c.\n", c);
      return 1;
    }
  }
  for (int i = optind, poscount = 0; i != argc; ++i, ++poscount) {
    if (poscount > 1) {
      fprintf (stderr, "Too many positional arguments.\n");
      return 1;
    }
    if (parse_u64 (&limits[poscount], argv[i]) != 0) {
      return 1;
    }
  }
  if (limits[0] > limits[1]) {
    fprintf(
      stderr,
      "The first number in the sequence is bigger than the last one.\n"
      );
    return 1;
  }
  if (width > 16) { /*fit to the biggest width*/
    width = DIV_CEIL (64 -__builtin_clzll (limits[1] ? limits[1] : 1), 4);
  }
  sprintf (fmt, "%%0%"PRIu64"%s\n", width, upper ?  PRIX64 : PRIx64);
  --limits[0];
  do {
    ++limits[0];
    if (le) {
      printf (fmt, htole64 (limits[0]));
    }
    else {
      printf (fmt, htobe64 (limits[0]));
    }
  }
  while (limits[0] != limits[1]);
  return 0;
}
/*---------------------------------------------------------------------------*/

BE_LE_HEXSEQ
}
add_step_before_dut_power_on hexseq_create_c_file

function hexseq_compile() {
    local execname=${1:-hexseq}
    local cc=${CC:-cc}
    $cc hexseq.c -o $execname
}
add_required_host_executables cc
add_step_before_dut_power_on hexseq_compile

function hexseq_compile_dut() {
    hexseq_compile hexseq_dut
}

function hexseq_dut_transfer() {
    dut_put hexseq_dut hexseq
}
