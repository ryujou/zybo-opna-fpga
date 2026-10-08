<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import type { SongIndex } from '../types'
import IconButton from './IconButton.vue'

const props = defineProps<{ song: SongIndex | null; position: number; overview?: boolean }>()
const emit = defineEmits<{ observe: [channel: number] }>()
const scroll = ref<HTMLDivElement>()
const canvas = ref<HTMLCanvasElement>()
const following = ref(true)
const scrollLeft = ref(0)
const columns = computed(() => props.song?.columns ?? 16)
const rows = computed(() => props.song?.rows ?? [])
const rowHeight = computed(() => props.overview ? 17 : 20)
const columnWidth = computed(() => props.overview ? 18 : 100)
let observer: ResizeObserver
let animation = 0
let dirty = true

function currentRow() {
  let low = 0, high = rows.value.length
  while (low < high) {
    const middle = (low + high) >>> 1
    if (rows.value[middle].time <= props.position) low = middle + 1; else high = middle
  }
  return Math.max(0, low - 1)
}

function follow() {
  following.value = true
  if (scroll.value) scroll.value.scrollTop = Math.max(0, currentRow() * rowHeight.value - scroll.value.clientHeight / 3)
  dirty = true
}

function onScroll() {
  scrollLeft.value = scroll.value?.scrollLeft ?? 0
  dirty = true
}

watch(() => props.position, () => { if (following.value) follow(); dirty = true })
watch(() => props.song, () => { if (scroll.value) { scroll.value.scrollTop = 0; scroll.value.scrollLeft = 0 }; scrollLeft.value = 0; following.value = true; dirty = true })

function draw() {
  const element = canvas.value!, viewport = scroll.value!
  const width = viewport.clientWidth, height = viewport.clientHeight, dpr = devicePixelRatio
  element.width = Math.round(width * dpr); element.height = Math.round(height * dpr)
  element.style.width = `${width}px`; element.style.height = `${height}px`
  const ctx = element.getContext('2d')!
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  ctx.fillStyle = '#090E14'; ctx.fillRect(0, 0, width, height)
  ctx.font = `${props.overview ? 11 : 12}px Consolas, monospace`
  ctx.textBaseline = 'middle'
  const rh = rowHeight.value, cw = props.overview ? Math.max(15, (width - 38) / columns.value) : columnWidth.value
  const gutter = props.overview ? 38 : 52
  const top = viewport.scrollTop, left = viewport.scrollLeft
  const first = Math.floor(top / rh), count = Math.ceil(height / rh) + 1
  for (let row = first; row < first + count; row++) {
    const y = row * rh - top
    if (row === currentRow() && props.song) { ctx.fillStyle = '#173648'; ctx.fillRect(0, y, width, rh) }
    else if (row % 4 === 0) { ctx.fillStyle = '#0D141D'; ctx.fillRect(0, y, width, rh) }
    ctx.fillStyle = '#738398'
    ctx.fillText(row.toString(16).toUpperCase().padStart(4, '0'), 5, y + rh / 2)
    for (let ch = 0; ch < columns.value; ch++) {
      const x = gutter + ch * cw - left
      if (x + cw < gutter || x > width) continue
      ctx.save(); ctx.beginPath(); ctx.rect(Math.max(gutter, x), y, Math.min(cw, x + cw - gutter), rh); ctx.clip()
      ctx.strokeStyle = '#17212D'; ctx.beginPath(); ctx.moveTo(x + 0.5, y); ctx.lineTo(x + 0.5, y + rh); ctx.stroke()
      const events = rows.value[row]?.cells[String(ch)] ?? []
      const event = events[events.length - 1]
      ctx.fillStyle = !event ? '#334254' : ch === 9 && props.song?.format === 'MIDI' ? '#C3B96C' : event.startsWith('OFF') ? '#738398' : event.startsWith('@') || event.includes(':') ? '#A79ADB' : '#72C8CF'
      const text = props.overview ? (events.length ? events.length.toString(16).toUpperCase().padStart(2, '0') : '··')
        : event ? event + (events.length > 1 ? ` +${events.length - 1}` : '') : '··· ·· ··'
      ctx.fillText(text, x + 6, y + rh / 2)
      ctx.restore()
    }
  }
}

function tick() { if (dirty) { draw(); dirty = false }; animation = requestAnimationFrame(tick) }
onMounted(() => {
  observer = new ResizeObserver(() => { dirty = true })
  observer.observe(scroll.value!)
  animation = requestAnimationFrame(tick)
})
onUnmounted(() => { observer.disconnect(); cancelAnimationFrame(animation) })
</script>

<template>
  <div class="tracker" :class="{ overview }">
    <div class="tracker-head">
      <IconButton v-if="!overview" icon="follow" label="跟随播放" :active="following" @click="follow" />
      <span v-else class="overview-gutter" />
      <div class="channel-heads" :style="{ transform: `translateX(-${scrollLeft}px)` }">
        <button v-for="id in columns" :key="id" :style="overview ? { flex: '1' } : { width: `${columnWidth}px` }"
          :aria-label="`观察声部 ${id}`" @click="emit('observe', id)">{{ id.toString().padStart(2, '0') }}</button>
      </div>
    </div>
    <div class="tracker-body">
      <div ref="scroll" class="tracker-scroll" @scroll="onScroll" @wheel="following = false" @pointerdown="following = false" tabindex="0" aria-label="演奏时间轴">
        <div :style="{ height: `${Math.max(rows.length, 80) * rowHeight}px`, width: overview ? '100%' : `${52 + columns * columnWidth}px` }" />
      </div>
      <canvas ref="canvas" class="tracker-canvas" aria-hidden="true" />
    </div>
  </div>
</template>
