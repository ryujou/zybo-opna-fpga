#include "midi_parser.h"
#include "midi_synth.h"
#include "usb_device.h"
#include "opl_hw.h"
#include "ssm2603.h"
#include "timer_ps.h"
#include "xparameters.h"
#include "xtime_l.h"
#include "xil_printf.h"

extern "C" {
volatile uint32_t midi_max_dispatch_us = 0;
volatile uint32_t midi_processed_events = 0;
volatile uint32_t midi_max_handler_us = 0;
}

namespace {
uint64_t now_us() {
    XTime now;
    XTime_GetTime(&now);
    constexpr uint64_t frequency = COUNTS_PER_SECOND;
    return (now / frequency) * 1000000ULL +
           (now % frequency) * 1000000ULL / frequency;
}
}

void midi_opl_write(uint16_t address, uint8_t value) {
    opl_write_reg(address & 0xFF, value, (address >> 8) & 1);
}
void midi_message_received(const uint8_t *data, size_t size) { midi_synth_message(data, size); }
void midi_sysex_received(const uint8_t *data, size_t size) { midi_synth_sysex(data, size); }

int main() {
    xil_printf("\r\nZybo OPNA MIDI: starting\r\n");
    int status = TimerInitialize(XPAR_XSCUTIMER_0_BASEADDR);
    if (status != XST_SUCCESS) { xil_printf("Timer init failed: %d\r\n", status); return 1; }
    status = ssm2603_init();
    if (status != XST_SUCCESS) { xil_printf("Codec init failed: %d\r\n", status); return 1; }
    opl_reset_core();
    if (!midi_synth_init()) { xil_printf("libOPNMIDI init failed: %s\r\n", midi_synth_error()); return 1; }
    status = midi_usb_init();
    if (status != XST_SUCCESS) { xil_printf("USB init failed: %d\r\n", status); return 1; }
    xil_printf("USB-MIDI ready: CAFE:4014, XG bank, six FM voices\r\n");
    MidiParser parser;
    uint64_t last_tick = now_us(), last_report = last_tick;
    uint32_t last_errors = 0;
    for (;;) {
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
        if (now - last_report >= 1000000) {
            const MidiUsbStats stats = midi_usb_stats();
            const uint32_t errors = stats.overflow + stats.malformed + parser.invalid_packets + parser.oversized_sysex + stats.control_errors;
            if (errors != last_errors) {
                xil_printf("MIDI errors: overflow=%u malformed=%u invalid=%u sysex=%u control=%u\r\n",
                    static_cast<unsigned>(stats.overflow), static_cast<unsigned>(stats.malformed),
                    static_cast<unsigned>(parser.invalid_packets), static_cast<unsigned>(parser.oversized_sysex),
                    static_cast<unsigned>(stats.control_errors));
                last_errors = errors;
            }
            last_report = now;
        }
    }
}
