// SPDX-License-Identifier: LGPL-3.0-or-later
#include "opl_hw.h"

#include <cstring>
#include "timer_ps.h"
#include "xil_cache.h"
#include "xil_io.h"

namespace {
constexpr u32 kControl = 0x004;
constexpr u32 kStatus = 0x008;
constexpr u32 kDdrBase = 0x00C;
constexpr u32 kMemoryType = 0x010;
u32 sample_offset = 0;
u32 sample_expected = 0;
u32 sample_loaded = 0;
bool sample_upload = false;

bool wait_idle(u32 mask)
{
    u32 status;
    do {
        status = opl_status();
        if (status & OPNA_DDR_ERROR) return false;
    } while (status & mask);
    return true;
}

u8 *sample_data()
{
#ifdef OPNA_HOST_TEST
    extern u8 *opna_host_sample_data();
    return opna_host_sample_data();
#else
    return reinterpret_cast<u8 *>(OPNA_SAMPLE_BASE);
#endif
}
}

u32 opl_status(void)
{
    return Xil_In32(OPNA_BASE + kStatus);
}

bool opl_write_reg(u8 reg, u8 data, u8 bank)
{
    if (bank > 1 || !(Xil_In32(OPNA_BASE + kControl) & OPNA_RUN)) return false;
    const u32 mask = OPNA_BUSY | OPNA_RESETTING | OPNA_HOST_PENDING;
    if (!wait_idle(mask)) return false;
    Xil_Out8(OPNA_BASE + bank * 2U, reg);
    if (!wait_idle(mask)) return false;
    // The AXI write response follows WR release; the hardware also enforces
    // the native address/data and rhythm-key recovery intervals.
    Xil_Out8(OPNA_BASE + bank * 2U + 1U, data);
    return wait_idle(mask);
}

bool opl_reset_core(bool reset_mix)
{
	sample_upload = false;
    // IC is an actual hardware reset, including its release stabilization.
    Xil_Out32(OPNA_BASE + kControl, OPNA_RUN | OPNA_MUTE | OPNA_RESET);
    if (!wait_idle(OPNA_RESETTING | OPNA_HOST_PENDING)) return false;
    Xil_Out32(OPNA_BASE + kControl, OPNA_RUN);
    return !reset_mix || opl_set_mix(65536, 65536, 65536);
}

bool opl_set_mix(u32 pcm, u32 ssg, u32 master)
{
    if (Xil_In32(OPNA_BASE + 0x01c) != 0x26080008U) return false;
    const bool running = (Xil_In32(OPNA_BASE + kControl) & OPNA_RUN) != 0;
    if (!opl_set_running(false)) return false;
    Xil_Out32(OPNA_BASE + 0x024, pcm);
    Xil_Out32(OPNA_BASE + 0x028, ssg);
    Xil_Out32(OPNA_BASE + 0x02c, master);
    if (Xil_In32(OPNA_BASE + 0x024) != pcm || Xil_In32(OPNA_BASE + 0x028) != ssg ||
        Xil_In32(OPNA_BASE + 0x02c) != master) return false;
    return !running || opl_set_running(true);
}

u32 opl_clip_count(bool right) { return Xil_In32(OPNA_BASE + (right ? 0x034 : 0x030)); }
void opl_clear_clips(void) {
    Xil_Out32(OPNA_BASE + 0x030, 1);
    Xil_Out32(OPNA_BASE + 0x034, 1);
}

bool opl_set_running(bool running, u64 *pause_ticks)
{
    if (running) {
        if (opl_status() & OPNA_DDR_ERROR) return false;
        Xil_Out32(OPNA_BASE + kControl, OPNA_RUN);
        return !(opl_status() & OPNA_DDR_ERROR) &&
            (Xil_In32(OPNA_BASE + kControl) & OPNA_RUN);
    }
    if (!wait_idle(OPNA_BUSY | OPNA_RESETTING | OPNA_HOST_PENDING)) return false;
    Xil_Out32(OPNA_BASE + kControl, OPNA_MUTE);
    if (pause_ticks) *pause_ticks = TimerNowTicks();
    return wait_idle(OPNA_DDR_PENDING);
}

bool opl_sample_begin(u32 offset, u32 length, u8 memory_type)
{
    if (length == 0 || offset >= OPNA_SAMPLE_BYTES ||
        length > OPNA_SAMPLE_BYTES - offset || memory_type > 2) return false;
    if (!opl_set_running(false)) return false;
    Xil_Out32(OPNA_BASE + kDdrBase, OPNA_SAMPLE_BASE);
    Xil_Out32(OPNA_BASE + kMemoryType, memory_type);
    // A short file has the same zero-filled remainder as the native model.
    std::memset(sample_data(), 0, OPNA_SAMPLE_BYTES);
    sample_offset = offset;
    sample_expected = length;
    sample_loaded = 0;
    sample_upload = true;
    return true;
}

bool opl_sample_write(const u8 *data, u32 length)
{
    if (!sample_upload || length > sample_expected - sample_loaded) return false;
    std::memcpy(sample_data() + sample_offset + sample_loaded, data, length);
    sample_loaded += length;
    return true;
}

bool opl_sample_end(void)
{
    if (!sample_upload || sample_loaded != sample_expected) return false;
    Xil_DCacheFlushRange(reinterpret_cast<INTPTR>(sample_data()), OPNA_SAMPLE_BYTES);
    sample_upload = false;
    // RUN rising invalidates the PL byte cache after CPU cache writeback.
    return opl_set_running(true);
}

bool opl_sample_read(u32 offset, u8 *data, u32 length)
{
    if (sample_upload || offset >= OPNA_SAMPLE_BYTES ||
        length > OPNA_SAMPLE_BYTES - offset) return false;
    if (!opl_set_running(false)) return false;
    Xil_DCacheInvalidateRange(reinterpret_cast<INTPTR>(sample_data()), OPNA_SAMPLE_BYTES);
    std::memcpy(data, sample_data() + offset, length);
    return true; // Readback leaves the chip paused until explicit resume/reset.
}

u32 opl_sample_loaded(void)
{
    return sample_loaded;
}
