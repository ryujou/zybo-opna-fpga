// SPDX-License-Identifier: LGPL-3.0-or-later
#include "opl_hw.h"
#include "opl_stream.h"
#include "ssm2603.h"
#include "timer_ps.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "xparameters.h"

int main()
{
    if (Xil_In32(OPNA_BASE + 0x01C) != 0x26080008U) {
        xil_printf("OPNA board ID mismatch\r\n");
        return 1;
    }
    int status = TimerInitialize(XPAR_XSCUTIMER_0_BASEADDR);
    if (status != 0) return status;
    if (!opl_reset_core()) return 2;
    // Keep the DAC muted if initialization or transport setup fails.
    if (!opl_set_running(false)) return 3;
    status = ssm2603_init();
    if (status != 0) {
        xil_printf("codec init failed: %d\r\n", status);
        return status;
    }
    return stream_session();
}
