// SPDX-License-Identifier: LGPL-3.0-or-later
#ifndef OPL_HW_H_
#define OPL_HW_H_

#include "xil_types.h"

constexpr UINTPTR OPNA_BASE = 0x43C00000U;
constexpr UINTPTR OPNA_SAMPLE_BASE = 0x01000000U;
constexpr u32 OPNA_SAMPLE_BYTES = 1U << 18;
constexpr u32 OPNA_RUN = 1U;
constexpr u32 OPNA_RESET = 2U;
constexpr u32 OPNA_MUTE = 4U;
constexpr u32 OPNA_BUSY = 1U;
constexpr u32 OPNA_RESETTING = 2U;
constexpr u32 OPNA_DDR_PENDING = 4U;
constexpr u32 OPNA_DDR_ERROR = 8U;
constexpr u32 OPNA_HOST_PENDING = 32U;

u32 opl_status(void);
bool opl_write_reg(u8 reg, u8 data, u8 bank);
bool opl_reset_core(void);
bool opl_set_running(bool running, u64 *pause_ticks = nullptr);
bool opl_sample_begin(u32 offset, u32 length, u8 memory_type);
bool opl_sample_write(const u8 *data, u32 length);
bool opl_sample_end(void);
bool opl_sample_read(u32 offset, u8 *data, u32 length);
u32 opl_sample_loaded(void);

#endif
