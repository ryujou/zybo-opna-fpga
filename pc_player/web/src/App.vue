<script setup lang="ts">
import { computed, ref } from 'vue'
import IconButton from './components/IconButton.vue'
import Tracker from './components/Tracker.vue'
import Waveform from './components/Waveform.vue'
import { formatTime, noteName, usePlayer } from './usePlayer'

const { state, song, selected, error, busy, connected, deviceId, control, load, voices } = usePlayer()
const input = ref<HTMLInputElement>()
const listOpen = ref(false)
const dragActive = ref(false)
const playing = computed(() => state.value?.status === 'playing')
const paused = computed(() => state.value?.status === 'paused')
const midiMode = computed(() => selected.value?.format === 'MIDI')
const opnaLabels = ['FM 1', 'FM 2', 'FM 3', 'FM 4', 'FM 5', 'FM 6', 'SSG A', 'SSG B', 'SSG C', 'Rhythm', 'ADPCM']
const opnaMode = computed(() => selected.value?.mode === 'opna')
const mode = computed(() => selected.value?.mode ?? 'vgm')
const matching = computed(() => state.value?.devices.items.filter(d => d.mode === mode.value) ?? [])
const deviceText = computed(() => {
  if (state.value?.device) return state.value.device.name
  if (!selected.value) return state.value?.devices.items[0]?.name ?? '未连接'
  return matching.value[0]?.name ?? `SW0 → ${midiMode.value ? 'MIDI' : opnaMode.value ? 'OPNA 原曲' : 'OPL3 VGM'}`
})
const canPlay = computed(() => connected.value && !!selected.value && (matching.value.length > 0 || (state.value?.test_mode && !opnaMode.value)))
const channelRows = computed(() => {
  if (midiMode.value) return state.value?.channels.map(c => ({ id: c.id, detail: `${c.program.toString().padStart(3, '0')}  ${c.name}`, active: c.active, note: c.note })) ?? []
  if (opnaMode.value) return opnaLabels.map((detail, index) => ({ id: index + 1, detail, active: state.value?.opl[index]?.active ?? false, note: null }))
  return Array.from({ length: 18 }, (_, index) => {
    const c = state.value?.opl[index]
    return { id: index + 1, detail: c ? (c.kind === 4 ? `4-op  ↔ ${c.pair.toString().padStart(2, '0')}` : c.kind === 1 ? ['BD', 'HH/SD', 'TOM/TC'][index - 6] : '2-op') : '···', active: c?.active ?? false, note: c?.note ?? null }
  })
})

async function fileChanged(event: Event) {
  const element = event.target as HTMLInputElement
  if (element.files?.length) await load(element.files)
  element.value = ''
}
async function drop(event: DragEvent) {
  dragActive.value = false
  if (event.dataTransfer?.files.length) await load(event.dataTransfer.files)
}
async function select(id: string, play = false) {
  await control('select', id)
  listOpen.value = false
  if (play) await control('play')
}
function playPause() { void control(playing.value ? 'pause' : paused.value ? 'resume' : 'play') }
function selectVoice(slot: number, event: Event) { void voices(slot, Number((event.target as HTMLSelectElement).value)) }
</script>

<template>
  <main class="player" :class="{ 'drag-active': dragActive }" @dragover.prevent="dragActive = true" @dragleave.self="dragActive = false" @drop.prevent="drop">
    <input ref="input" type="file" hidden multiple accept=".mid,.midi,.vgm,.vgz,.m,.m2,.mz,.mp,.pmd" @change="fileChanged" />
    <header class="status-bar">
      <span class="song-title" :title="selected?.title">{{ selected?.title ?? '—' }}</span>
      <span class="format">{{ opnaMode ? "YM2608 · " : "" }}{{ selected?.format }}</span>
      <span class="device-dot" :class="{ online: matching.length || state?.device }" />
      <select v-if="matching.length > 1" v-model="deviceId" class="device-select" aria-label="输出设备">
        <option value="">{{ matching[0].name }}</option>
        <option v-for="device in matching" :key="device.id" :value="device.id">{{ device.name }}</option>
      </select>
      <span v-else class="device-name" :title="state?.devices.error || deviceText">{{ deviceText }}</span>
    </header>

    <section class="upper-band">
      <div class="overview-panel panel"><Tracker :song="song" :position="state?.position ?? 0" overview /></div>
      <div class="transport-panel panel">
        <Waveform :lines="state?.total ?? [[], []]" stereo :gain="opnaMode ? 8 : 1" :title="opnaMode ? 'YM2608 软件参考波形 · 显示 ×8' : undefined" />
        <div class="transport-controls">
          <IconButton icon="open" label="打开文件" :disabled="busy" @click="input?.click()" />
          <IconButton :icon="playing ? 'pause' : 'play'" :label="playing ? '暂停' : paused ? '继续' : '播放'"
            :active="playing || paused" :disabled="busy || !canPlay" @click="playPause" />
          <IconButton icon="stop" label="停止" :disabled="busy || !selected" @click="control('stop')" />
          <IconButton icon="restart" label="重新播放" :disabled="busy || !canPlay" @click="control('restart')" />
          <span class="transport-time">{{ formatTime(state?.position ?? 0) }} / {{ formatTime(selected?.duration ?? 0) }}</span>
        </div>
        <div class="progress-track" role="progressbar" :aria-valuenow="state?.status === 'uploading' ? state.upload : Math.floor((state?.position ?? 0) * 100 / (selected?.duration || 1))" aria-valuemin="0" aria-valuemax="100" aria-label="播放进度">
          <i :style="{ width: `${state?.status === 'uploading' ? state.upload : Math.min(100, (state?.position ?? 0) * 100 / (selected?.duration || 1))}%` }" />
        </div>
        <p v-if="error || state?.error" class="operation-error" role="alert">{{ error || state?.error }}</p>
        <span v-if="state?.status === 'uploading'" class="upload-state">{{ state.upload }}%</span>
      </div>
      <div class="instruments-panel panel">
        <button v-for="channel in channelRows" :key="channel.id" class="instrument-row" :class="{ sounding: channel.active }" :title="channel.detail"
          :aria-label="`观察声部 ${channel.id}`" @click="voices(0, channel.id)">
          <span class="channel-number">{{ channel.id.toString().padStart(2, '0') }}</span>
          <span class="instrument-detail">{{ selected ? channel.detail : '···' }}</span>
          <span class="channel-note">{{ noteName(channel.note) }}</span>
          <i class="activity-dot" :class="{ active: channel.active }" />
        </button>
      </div>
      <div class="info-panel panel">
        <div class="song-info">
          <strong :title="selected?.title">{{ selected?.title ?? '—' }}</strong>
          <span v-for="key in ['game', 'author', 'system']" :key="key" :title="selected?.metadata[key]">{{ selected?.metadata[key] }}</span>
          <div class="file-facts"><span>{{ selected?.format }}</span><span>{{ formatTime(selected?.duration ?? 0) }}</span></div>
        </div>
        <IconButton icon="list" label="文件列表" :active="listOpen" @click="listOpen = !listOpen" />
        <Transition name="list">
          <div v-if="listOpen" class="file-list">
            <div class="list-actions"><IconButton icon="open" label="打开文件" @click="input?.click()" /><IconButton icon="close" label="关闭列表" @click="listOpen = false" /></div>
            <button v-for="item in state?.playlist ?? []" :key="item.id" class="file-row" :class="{ selected: item.id === state?.selected }"
              :title="item.name" @click="select(item.id)" @dblclick="select(item.id, true)">
              <span>{{ item.name }}</span><small>{{ item.format }}</small><time>{{ formatTime(item.duration) }}</time>
            </button>
          </div>
        </Transition>
      </div>
    </section>

    <section class="lower-band">
      <div class="performance-panel panel"><Tracker :song="song" :position="state?.position ?? 0" @observe="(!opnaMode || $event <= 11) && voices(0, $event)" /></div>
      <div class="voice-grid">
        <div v-for="(voice, slot) in state?.voices ?? [1, 2, 3, 4, 5, 6]" :key="slot" class="voice-panel panel">
          <select class="voice-select" :value="voice" :aria-label="`波形 ${slot + 1} 声部`" @change="selectVoice(slot, $event)">
            <option v-for="id in (opnaMode ? 11 : 18)" :key="id" :value="id">{{ opnaMode ? opnaLabels[id - 1] : id.toString().padStart(2, '0') }}</option>
          </select>
          <Waveform :lines="[state?.waves[slot] ?? []]" :gain="opnaMode ? 8 : 1" :title="opnaMode ? 'YM2608 软件参考波形 · 显示 ×8' : undefined" />
        </div>
      </div>
    </section>
  </main>
</template>
