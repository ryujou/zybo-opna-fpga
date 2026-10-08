#pragma once
#include <cstddef>
#include <cstdint>

extern const uint8_t midi_device_descriptor[18];
extern const uint8_t midi_config_descriptor[101];
size_t midi_string_descriptor(uint8_t index, uint8_t *output);
