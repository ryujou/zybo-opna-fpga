#include "midi_parser.h"
#include "midi_synth.h"
#include "usb_device.h"
#include "opl_hw.h"
#include "opl_stream.h"
#include "ssm2603.h"
#include "timer_ps.h"
#include "xparameters.h"
#include "xtime_l.h"
#include "xil_io.h"
#include "xil_printf.h"
#include "sleep.h"

extern "C" {
volatile uint32_t midi_max_dispatch_us = 0;
volatile uint32_t midi_processed_events = 0;
volatile uint32_t midi_max_handler_us = 0;
volatile uint32_t usb_active_mode = 0;
volatile uint32_t usb_mode_changes = 0;
// JTAG unattended tests: -1 reads the physical switch; 0/1 overrides SW0.
volatile int32_t usb_sw0_override = -1;
}

namespace {
bool midi_mode, candidate_mode;
uint64_t candidate_since;

uint64_t now_us() {
    XTime now;
    XTime_GetTime(&now);
    return (now / COUNTS_PER_SECOND) * 1000000ULL +
           (now % COUNTS_PER_SECOND) * 1000000ULL / COUNTS_PER_SECOND;
}

bool switch_is_up() {
    const int32_t override = usb_sw0_override;
    return override < 0 ? (Xil_In32(OPNA_BASE + 0x020) & 1U) : (override & 1);
}

bool mode_changed() {
    const bool level = !switch_is_up();
    const uint64_t now = now_us();
    if (level != candidate_mode) {
        candidate_mode = level;
        candidate_since = now;
    }
    // Contact bounce must not cause multiple USB disconnect/reconnect cycles.
    return candidate_mode != midi_mode && now - candidate_since >= 50000;
}

int play_midi() {
    if (!opl_reset_core()) return 2;
    if (!midi_synth_init()) {
        xil_printf("libOPNMIDI init failed: %s\r\n", midi_synth_error());
        return 3;
    }
    const int status = midi_usb_init();
    if (status != XST_SUCCESS) { midi_synth_close(); return status; }
    xil_printf("SW0 OFF: Zybo OPNA MIDI, CAFE:4014\r\n");
    MidiParser parser;
    uint64_t last_tick = now_us();
    while (!mode_changed()) {
        if (midi_usb_take_reset()) {
            parser.reset();
            midi_synth_reset();
            last_tick = now_us();
        }
        const uint64_t now = now_us();
        if (now - last_tick >= 1000) {
            midi_synth_tick(static_cast<uint32_t>(now - last_tick));
            last_tick = now;
        }
        MidiUsbEvent event;
        if (midi_usb_pop(event)) {
            const uint32_t started = static_cast<uint32_t>(now_us());
            const uint32_t delay = started - event.received_us;
            if (delay > midi_max_dispatch_us) midi_max_dispatch_us = delay;
            parser.accept(event.data);
            const uint32_t elapsed = static_cast<uint32_t>(now_us()) - started;
            if (elapsed > midi_max_handler_us) midi_max_handler_us = elapsed;
            ++midi_processed_events;
        }
    }
    midi_usb_close();
    midi_synth_reset();
    midi_synth_close();
    return 0;
}
}

void midi_opl_write(uint16_t address, uint8_t value) {
    opl_write_reg(address & 0xff, value, (address >> 8) & 1);
}
void midi_message_received(const uint8_t *data, size_t size) { midi_synth_message(data, size); }
void midi_sysex_received(const uint8_t *data, size_t size) { midi_synth_sysex(data, size); }

int main() {
    if (Xil_In32(OPNA_BASE + 0x01c) != 0x26080008U ||
        (Xil_In32(OPNA_BASE + 0x020) & ~1U) != 0x53570000U) {
        xil_printf("Dual-mode hardware with SW0 is required\r\n");
        return 1;
    }
    int status = TimerInitialize(XPAR_XSCUTIMER_0_BASEADDR);
    if (status != XST_SUCCESS) return status;
    if (!opl_reset_core() || !opl_set_running(false)) return 2;
    status = ssm2603_init();
    if (status != XST_SUCCESS) return status;
    usleep(50000);
    for (;;) {
        midi_mode = candidate_mode = !switch_is_up();
        candidate_since = now_us();
        usb_active_mode = midi_mode ? 1 : 2;
        if (midi_mode) status = play_midi();
        else {
            xil_printf("SW0 ON: Zybo PC98 OPNA, CAFE:4012\r\n");
            status = stream_session(mode_changed);
        }
        if (!opl_set_running(false)) return 2;
        if (status != 0) { xil_printf("USB mode failed: %d\r\n", status); return status; }
        ++usb_mode_changes;
        // Both USB identities use the same controller; retire the old Windows device first.
        usleep(500000);
    }
}
