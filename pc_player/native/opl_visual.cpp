#include "adlmidi.h"
#include "adlmidi_midiplay.hpp"
#include "adlmidi_opl3.hpp"
#include "chips/nuked_opl3.h"
#include "chips/nuked/nukedopl3.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>

constexpr int rate = 49716;
constexpr int capacity = 4096;
constexpr int lanes = 20;

struct VoiceState {
    int source, pair, kind, key_on;
    double frequency;
};

struct Visual {
    ADL_MIDIPlayer *midi = nullptr;
    std::unique_ptr<opl3_chip> raw;
    std::array<std::array<float, capacity>, lanes> samples{};
    int cursor = 0;
    double tick_seconds = 0;

    ~Visual() { if (midi) adl_close(midi); }
    opl3_chip *chip() const {
        if (raw) return raw.get();
        auto *player = static_cast<MIDIplay *>(midi->adl_midiPlayer);
        return static_cast<opl3_chip *>(static_cast<NukedOPL3 *>(
            player->m_synth->m_chips[0].get())->visualChip());
    }
};

#define API extern "C" __declspec(dllexport)

API Visual *visual_create(int midi_mode) {
    auto v = std::make_unique<Visual>();
    if (midi_mode) {
        v->midi = adl_init(rate);
        if (!v->midi) return nullptr;
        if (adl_setNumChips(v->midi, 1) < 0 || adl_setBank(v->midi, 58) < 0 ||
            adl_switchEmulator(v->midi, ADLMIDI_EMU_NUKED) < 0) return nullptr;
        adl_setVolumeRangeModel(v->midi, 0);
        adl_setSoftPanEnabled(v->midi, 0);
        adl_rt_resetState(v->midi);
    } else {
        v->raw = std::make_unique<opl3_chip>();
        OPL3_Reset(v->raw.get(), rate);
        // The board uses an OPL3 for both OPL2 and OPL3 register streams.
        OPL3_WriteReg(v->raw.get(), 0x105, 1);
    }
    return v.release();
}

API void visual_destroy(Visual *v) { delete v; }

API void visual_midi(Visual *v, const unsigned char *data, int size) {
    if (!v->midi || size < 1) return;
    const int channel = data[0] & 15;
    if (data[0] == 0xf0) {
        adl_rt_systemExclusive(v->midi, data, size);
        return;
    }
    const int a = size > 1 ? data[1] : 0;
    const int b = size > 2 ? data[2] : 0;
    switch (data[0] & 0xf0) {
    case 0x80: adl_rt_noteOff(v->midi, channel, a); break;
    case 0x90: if (b) adl_rt_noteOn(v->midi, channel, a, b);
               else adl_rt_noteOff(v->midi, channel, a); break;
    case 0xa0: adl_rt_noteAfterTouch(v->midi, channel, a, b); break;
    case 0xb0: adl_rt_controllerChange(v->midi, channel, a, b); break;
    case 0xc0: adl_rt_patchChange(v->midi, channel, a); break;
    case 0xd0: adl_rt_channelAfterTouch(v->midi, channel, a); break;
    case 0xe0: adl_rt_pitchBend(v->midi, channel, a | (b << 7)); break;
    }
}

API void visual_opl(Visual *v, int bank, int reg, int value) {
    OPL3_WriteReg(v->chip(), (bank << 8) | reg, value);
}

API void visual_advance(Visual *v, double seconds, int frames) {
    auto *chip = v->chip();
    for (int i = 0; i < frames; ++i) {
        // Nuked emits the previous right mix and the current left mix.
        std::array<int16_t, 18> previous_right;
        std::copy_n(chip->visual_right, 18, previous_right.begin());
        int16_t stereo[2];
        OPL3_Generate(chip, stereo);
        v->samples[0][v->cursor] = stereo[0] / 32768.0f;
        v->samples[1][v->cursor] = stereo[1] / 32768.0f;
        for (int ch = 0; ch < 18; ++ch)
            v->samples[ch + 2][v->cursor] =
                (chip->visual_left[ch] + previous_right[ch]) / 65536.0f;
        v->cursor = (v->cursor + 1) % capacity;
    }
    // PCM is generated directly: adl_generate() would also tick iterators.
    if (v->midi) {
        auto *player = static_cast<MIDIplay *>(v->midi->adl_midiPlayer);
        v->tick_seconds += seconds;
        while (v->tick_seconds >= 0.001) {
            player->TickIterators(0.001);
            v->tick_seconds -= 0.001;
        }
    }
}

API void visual_snapshot(Visual *v, float *out, VoiceState *states) {
    for (int lane = 0; lane < lanes; ++lane)
        for (int i = 0; i < capacity; ++i)
            out[lane * capacity + i] = v->samples[lane][(v->cursor + i) % capacity];
    auto *chip = v->chip();
    for (int ch = 0; ch < 18; ++ch) {
        const auto &c = chip->channel[ch];
        auto &s = states[ch];
        s.source = c.chtype == 1 ? c.pair->ch_num : ch;
        s.pair = c.chtype == 1 || c.chtype == 2 ? c.pair->ch_num + 1 : 0;
        s.kind = c.chtype == 1 || c.chtype == 2 ? 4 : c.chtype == 3 ? 1 : 2;
        s.key_on = (c.slotz[0]->key | c.slotz[1]->key) != 0;
        s.frequency = std::ldexp(c.f_num * double(rate), c.block - 20);
    }
}
