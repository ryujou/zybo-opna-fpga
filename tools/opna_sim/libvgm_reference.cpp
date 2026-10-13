// Full VGM loader reference; retain wide mixed samples before output clipping.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>
#include "player/vgmplayer.hpp"
#include "utils/MemoryLoader.h"
#include "emu/SoundDevs.h"
#include "emu/EmuCores.h"

int main(int argc, char** argv) {
    if (argc != 5) {std::fprintf(stderr, "libvgm_reference INPUT OUTPUT SECONDS(0=full) PART(0=all,1=PCM,2=SSG)\n"); return 1;}
    std::ifstream input(argv[1], std::ios::binary);
    std::vector<UINT8> bytes((std::istreambuf_iterator<char>(input)), {});
    if (bytes.empty()) return 2;
    DATA_LOADER* loader = MemoryLoader_Init(bytes.data(), bytes.size());
    if (!loader || DataLoader_Load(loader)) return 3;
    VGMPlayer player;
    player.SetSampleRate(48000);
    if (player.LoadFile(loader)) return 4;
    UINT32 id = PLR_DEV_ID(DEVID_YM2608, 0);
    PLR_DEV_OPTS options;
    if (player.GetDeviceOptions(id, options)) return 5;
    options.emuCore[0] = FCC_MAME;
    options.emuCore[1] = FCC_MAME;
    if (player.SetDeviceOptions(id, options)) return 6;
    PLR_MUTE_OPTS mute = {};
    int part = std::atoi(argv[4]);
    if (part == 1) mute.chnMute[1] = 7;
    if (part == 2) mute.chnMute[0] = 0x1fff;
    if (player.SetDeviceMuting(id, mute)) return 7;
    PLR_SONG_INFO song;
    if (player.GetSongInfo(song)) return 8;
    std::vector<PLR_DEV_INFO> before, after;
    player.GetSongDeviceInfo(before);
    if (player.Start()) return 9;
    player.GetSongDeviceInfo(after);
    for (size_t i=0; i<after.size(); ++i)
        std::printf("DEVICE type=%u core=%08x volume_before=%u volume_after=%u rate=%u\n",
                    after[i].type, after[i].core, before[i].volume, after[i].volume, after[i].smplRate);
    UINT32 frames = player.Tick2Sample(player.GetTotalTicks());
    double seconds = std::atof(argv[3]);
    if (seconds > 0) frames = std::min(frames, UINT32(seconds*48000));
    std::ofstream output(argv[2], std::ios::binary);
    std::vector<WAVE_32BS> buffer(2048);
    double peak = 0;
    for (UINT32 pos=0; pos<frames;) {
        UINT32 count = std::min(UINT32(buffer.size()), frames-pos);
        std::fill(buffer.begin(), buffer.end(), WAVE_32BS{});
        if (player.Render(count, buffer.data()) != count) return 10;
        for (UINT32 i=0; i<count; ++i) {
            float stereo[2] = {float(buffer[i].L/256.0 * song.volGain/65536.0),
                               float(buffer[i].R/256.0 * song.volGain/65536.0)};
            peak = std::max(peak, std::max(std::abs(double(stereo[0])), std::abs(double(stereo[1]))));
            output.write(reinterpret_cast<char*>(stereo), sizeof(stereo));
        }
        pos += count;
    }
    std::printf("RENDER frames=%u global_gain_q16=%d peak=%.6f\n", frames, song.volGain, peak);
    player.Stop(); player.UnloadFile(); DataLoader_Deinit(loader);
    return output.good() ? 0 : 11;
}
