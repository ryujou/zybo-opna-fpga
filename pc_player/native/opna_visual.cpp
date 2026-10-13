// The same pinned libvgm/MAME cores and file volume rules as the PC98 reference.
#include <algorithm>
#include <array>
#include <memory>
#include <vector>
#include "player/vgmplayer.hpp"
#include "utils/MemoryLoader.h"
#include "emu/SoundDevs.h"
#include "emu/EmuCores.h"

namespace {
constexpr unsigned capacity = 4096;
struct Voice {
    VGMPlayer player;
    DATA_LOADER* loader = nullptr;
    double gain = 0;
    ~Voice() {
        player.Stop(); player.UnloadFile();
        if (loader) DataLoader_Deinit(loader);
    }
    bool init(const std::vector<UINT8>& bytes, unsigned index) {
        loader = MemoryLoader_Init(bytes.data(), bytes.size());
        if (!loader || DataLoader_Load(loader)) return false;
        player.SetSampleRate(48000);
        if (player.LoadFile(loader)) return false;
        const UINT32 id = PLR_DEV_ID(DEVID_YM2608, 0);
        PLR_DEV_OPTS options;
        if (player.GetDeviceOptions(id, options)) return false;
        options.emuCore[0] = options.emuCore[1] = FCC_MAME;
        if (player.SetDeviceOptions(id, options)) return false;
        PLR_MUTE_OPTS mute = {};
        if (index) {
            mute.chnMute[0] = 0x1fff;
            mute.chnMute[1] = 7;
            if (index <= 6) mute.chnMute[0] &= ~(1u << (index - 1));
            else if (index <= 9) mute.chnMute[1] &= ~(1u << (index - 7));
            else if (index == 10) mute.chnMute[0] &= ~0xfc0u; // six rhythm voices
            else mute.chnMute[0] &= ~0x1000u; // Delta-T ADPCM
        }
        if (player.SetDeviceMuting(id, mute)) return false;
        PLR_SONG_INFO song;
        if (player.GetSongInfo(song)) return false;
        gain = song.volGain / 65536.0 / 256.0 / 32768.0 / 8.0;
        return player.Start() == 0;
    }
};
struct Visual {
    std::vector<UINT8> bytes;
    std::array<Voice, 12> voices;
    std::array<std::array<float, capacity>, 13> ring = {};
    unsigned position = 0;
    UINT64 frames = 0;
    bool init(const UINT8* data, unsigned size) {
        bytes.assign(data, data + size);
        for (unsigned i = 0; i < voices.size(); ++i)
            if (!voices[i].init(bytes, i)) return false;
        return true;
    }
    bool advance(UINT64 target) {
        std::array<WAVE_32BS, 512> buffer;
        while (frames < target) {
            unsigned count = unsigned(std::min<UINT64>(512, target - frames));
            for (unsigned voice = 0; voice < voices.size(); ++voice) {
                std::fill(buffer.begin(), buffer.end(), WAVE_32BS{});
                if (voices[voice].player.Render(count, buffer.data()) != count) return false;
                for (unsigned n = 0; n < count; ++n) {
                    unsigned at = (position + n) % capacity;
                    double gain = voices[voice].gain;
                    if (!voice) {
                        ring[0][at] = float(buffer[n].L * gain);
                        ring[1][at] = float(buffer[n].R * gain);
                    } else {
                        ring[voice + 1][at] = float((double(buffer[n].L) + buffer[n].R) * .5 * gain);
                    }
                }
            }
            frames += count;
            position = (position + count) % capacity;
        }
        return true;
    }
};
}

extern "C" {
__declspec(dllexport) void* opna_visual_create(const UINT8* bytes, unsigned size) {
    auto visual = std::make_unique<Visual>();
    if (!visual->init(bytes, size)) return nullptr;
    return visual.release();
}
__declspec(dllexport) void opna_visual_destroy(void* handle) { delete static_cast<Visual*>(handle); }
__declspec(dllexport) int opna_visual_advance(void* handle, UINT64 frame) {
    return static_cast<Visual*>(handle)->advance(frame);
}
__declspec(dllexport) void opna_visual_snapshot(void* handle, float* output) {
    auto& v = *static_cast<Visual*>(handle);
    for (unsigned lane = 0; lane < v.ring.size(); ++lane)
        for (unsigned n = 0; n < capacity; ++n)
            output[lane * capacity + n] = v.ring[lane][(v.position + n) % capacity];
}
}
