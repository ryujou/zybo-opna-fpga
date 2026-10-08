import { computed, onMounted, onUnmounted, ref, shallowRef, watch } from 'vue'
import type { Action, Snapshot, SongIndex } from './types'

export function formatTime(seconds: number): string {
  return `${Math.floor(seconds / 60).toString().padStart(2, '0')}:${Math.floor(seconds % 60).toString().padStart(2, '0')}`
}

export function noteName(note: number | null): string {
  if (note === null) return '···'
  return ['C-', 'C#', 'D-', 'D#', 'E-', 'F-', 'F#', 'G-', 'G#', 'A-', 'A#', 'B-'][((note % 12) + 12) % 12] + (Math.floor(note / 12) - 1)
}

export function usePlayer() {
  const state = shallowRef<Snapshot | null>(null)
  const song = shallowRef<SongIndex | null>(null)
  const error = ref('')
  const busy = ref(false)
  const connected = ref(false)
  const deviceId = ref('')
  let socket: WebSocket | undefined
  const selected = computed(() => state.value?.playlist.find(s => s.id === state.value?.selected))

  async function request<T>(url: string, init?: RequestInit): Promise<T> {
    const response = await fetch(url, init)
    const data = await response.json()
    if (!response.ok) throw new Error(typeof data.detail === 'string' ? data.detail : '操作失败')
    return data as T
  }

  async function report(work: () => Promise<void>) {
    busy.value = true
    error.value = ''
    try { await work() } catch (exception) { error.value = String(exception instanceof Error ? exception.message : exception) }
    finally { busy.value = false }
  }

  async function control(action: Action, id?: string) {
    await report(async () => {
      state.value = await request<Snapshot>('/api/control', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action, id, device_id: deviceId.value || null }),
      })
    })
  }

  async function load(files: FileList | File[]) {
    await report(async () => {
      for (const file of Array.from(files)) {
        await request(`/api/files?name=${encodeURIComponent(file.name)}`, { method: 'POST', body: file })
      }
      state.value = await request<Snapshot>('/api/state')
    })
  }

  async function voices(slot: number, value: number) {
    await report(async () => {
      const mapping = [...(state.value?.voices ?? [1, 2, 3, 4, 5, 6])]
      mapping[slot] = value
      state.value = await request<Snapshot>('/api/voices', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ voices: mapping }),
      })
    })
  }

  watch(() => state.value?.selected, async id => {
    song.value = null
    deviceId.value = ''
    if (id) {
      try {
        const index = await request<SongIndex>(`/api/song?id=${encodeURIComponent(id)}`)
        if (state.value?.selected === id) song.value = index
      } catch (exception) { error.value = String(exception instanceof Error ? exception.message : exception) }
    }
  })

  onMounted(async () => {
    await report(async () => {
      state.value = await request<Snapshot>('/api/state')
      socket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws`)
      socket.onopen = () => { connected.value = true }
      socket.onmessage = event => { state.value = JSON.parse(event.data) as Snapshot }
      socket.onclose = () => { connected.value = false; error.value = '播放器连接已断开' }
      socket.onerror = () => { error.value = '播放器连接失败' }
    })
  })
  onUnmounted(() => { if (socket) { socket.onclose = null; socket.close() } })
  return { state, song, selected, error, busy, connected, deviceId, control, load, voices }
}
