// SPDX-License-Identifier: GPL-3.0-or-later
// 98fmplayer PMD driver and OPNA timers produce one pass of register music.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <io.h>
#include "fmdriver/fmdriver_pmd.h"
#include "libopna/opna.h"
#include "libopna/opnatimer.h"

static struct opna chip;
static struct opna_timer timer;
static struct driver_pmd pmd;
static struct fmdriver_work work;
static unsigned char output[8*1024*1024];
static size_t length = 0x100;
static uint64_t previous;

static void byte(unsigned value) {
    if (length == sizeof(output)) {
        fputs("PMD register stream exceeds 8 MiB\n", stderr);
        exit(1);
    }
    output[length++] = value;
}
static void wait_until(uint64_t tick) {
    while (previous < tick) {
        unsigned delta = tick-previous > 65535 ? 65535 : (unsigned)(tick-previous);
        byte(0x61); byte(delta); byte(delta >> 8);
        previous += delta;
    }
}
static void write_reg(struct fmdriver_work *w, unsigned reg, unsigned value) {
    (void)w;
    wait_until(chip.generated_frames * 144 * 44100 / 7987200);
    byte(reg & 0x100 ? 0x57 : 0x56); byte(reg); byte(value);
    opna_timer_writereg(&timer, reg, value);
}
static unsigned read_reg(struct fmdriver_work *w, unsigned reg) {
    (void)w; return opna_readreg(&chip, reg);
}
static uint8_t status(struct fmdriver_work *w, bool a1) {
    (void)w; (void)a1; return opna_timer_status(&timer);
}
static void interrupt(void *ptr) {
    struct fmdriver_work *w = ptr;
    w->driver_opna_interrupt(w);
}
static void put32(unsigned offset, unsigned value) {
    for (unsigned i=0; i<4; ++i) output[offset+i] = value >> (8*i);
}
int main(void) {
    unsigned char data[65536];
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
    size_t size = fread(data, 1, sizeof(data), stdin);
    if (size >= sizeof(data) || !pmd_load(&pmd, data, (uint16_t)size)) {
        fputs("Invalid or oversized PMD file\n", stderr); return 1;
    }
    opna_reset(&chip);
    opna_timer_reset(&timer, &chip);
    work.opna_readreg = read_reg;
    work.opna_writereg = write_reg;
    work.opna_status = status;
    opna_timer_set_int_callback(&timer, interrupt, &work);
    pmd_init(&work, &pmd);
    if (pmd.ppcfile[0] || pmd.ppsfile[0] || pmd.ppzfile[0] || pmd.ppzfile2[0]) {
        fputs("External PPC/PPS/PPZ samples are not supported by this player\n", stderr);
        return 1;
    }
    while (work.playing && !work.loop_cnt) {
        int16_t samples[512*2] = {0};
        opna_timer_mix(&timer, samples, 512);
        if (chip.generated_frames > (uint64_t)7987200*600/144) {
            fputs("PMD did not finish a loop within 10 minutes\n", stderr); return 1;
        }
    }
    wait_until(chip.generated_frames * 144 * 44100 / 7987200);
    byte(0x66);
    memcpy(output, "Vgm ", 4);
    put32(4, (unsigned)length-4);
    put32(8, 0x151);
    put32(0x18, (unsigned)previous);
    put32(0x34, 0x100-0x34);
    put32(0x48, 7987200);
    return fwrite(output, 1, length, stdout) == length ? 0 : 1;
}
