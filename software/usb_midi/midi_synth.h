#pragma once
#include <cstddef>
#include <cstdint>

bool midi_synth_init();
const char *midi_synth_error();
void midi_synth_close();
void midi_synth_reset();
void midi_synth_tick(uint32_t elapsed_us);
void midi_synth_message(const uint8_t *data, size_t size);
void midi_synth_sysex(const uint8_t *data, size_t size);
