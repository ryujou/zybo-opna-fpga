/* Functional SCH investigation only: sample scheduling is not a timing oracle. */
#include <stdint.h>
#include <stdio.h>

#if defined(PROBE_LIBVGM)
#include "fmopn.h"
static void *chip;
static void reset_chip(void) { ym2608_reset_chip(chip); }
static int init_chip(void) {
    chip = ym2608_init(NULL, 8000000, 8000000 / 144, NULL, NULL);
    return chip != NULL;
}
static void write_port(int port, int data) { ym2608_write(chip, port, data); }
static void sample(FILE *out, int tick) {
    DEV_SMPL left, right, *buffer[2] = {&left, &right};
    ym2608_update_one(chip, 1, buffer);
    fprintf(out, "%d,pcm,0,%d\n%d,pcm,1,%d\n", tick, left, tick, right);
}
#else
static unsigned address[2];
#if defined(PROBE_LIBOPNA)
#include "opnafm.h"
static struct opna_fm chip;
static void reset_chip(void) { opna_fm_reset(&chip); }
static int init_chip(void) { return 1; }
static void write_reg(unsigned reg, unsigned data) { opna_fm_writereg(&chip, reg, data); }
static void sample(FILE *out, int tick) {
    int16_t buffer[2] = {0, 0};
    opna_fm_mix(&chip, buffer, 1, NULL, 0);
    fprintf(out, "%d,pcm,0,%d\n%d,pcm,1,%d\n", tick, buffer[0], tick, buffer[1]);
}
#elif defined(PROBE_PMDWIN)
#include "opna.h"
static OPNA chip;
static void reset_chip(void) { OPNAReset(&chip); }
static int init_chip(void) { return OPNAInit(&chip, 8000000, 8000000 / 144, 0); }
static void write_reg(unsigned reg, unsigned data) { OPNASetReg(&chip, reg, data); }
static void sample(FILE *out, int tick) {
    int16_t buffer = 0;
    OPNAMix(&chip, &buffer, 1);
    fprintf(out, "%d,pcm,0,%d\n", tick, buffer);
}
#else
#error Select a probe core
#endif
static void write_port(int port, int data) {
    if (port & 1) write_reg(address[port >> 1] + ((port >> 1) << 8), data);
    else address[port >> 1] = data;
}
#endif

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    FILE *input = fopen(argv[1], "r"), *output = fopen(argv[2], "w");
    if (!input || !output || !init_chip()) return 2;
    int total, next, ic, cs, wr, rd, port, data, previous_ic = 1;
    if (fscanf(input, "%d", &total) != 1) return 2;
    int fields = fscanf(input, "%d%d%d%d%d%d%d", &next, &ic, &cs, &wr, &rd, &port, &data);
    reset_chip();
    fprintf(output, "tick,kind,index,value\n");
    for (int tick = 0; tick < total; ++tick) {
        if (fields == 7 && tick == next) {
            if (!ic && previous_ic) reset_chip();
            if (ic && !cs && !wr) write_port(port, data);
            previous_ic = ic;
            fields = fscanf(input, "%d%d%d%d%d%d%d", &next, &ic, &cs, &wr, &rd, &port, &data);
        }
        /* One FM frame = 144 master cycles. Register APIs have no pin timing. */
        if (tick % 288 == 0) sample(output, tick);
    }
    fclose(input);
    fclose(output);
#if defined(PROBE_LIBVGM)
    ym2608_shutdown(chip);
#endif
    return fields == EOF ? 0 : 2;
}
