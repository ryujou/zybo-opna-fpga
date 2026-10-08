<script setup lang="ts">
import { onMounted, onUnmounted, ref, watch } from 'vue'
const props = defineProps<{ lines: number[][]; stereo?: boolean; gain?: number }>()
const canvas = ref<HTMLCanvasElement>()
let observer: ResizeObserver
let animation = 0
let dirty = true
watch(() => props.lines, () => { dirty = true })

function draw() {
  const element = canvas.value
  if (!element) return
  const { width, height } = element.getBoundingClientRect()
  const dpr = window.devicePixelRatio
  if (element.width !== Math.round(width * dpr) || element.height !== Math.round(height * dpr)) {
    element.width = Math.round(width * dpr)
    element.height = Math.round(height * dpr)
  }
  const ctx = element.getContext('2d')!
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  ctx.clearRect(0, 0, width, height)
  ctx.lineWidth = 1
  const centers = props.stereo ? [height * 0.28, height * 0.74] : [height / 2]
  centers.forEach(center => {
    ctx.strokeStyle = '#17212D'
    ctx.beginPath(); ctx.moveTo(0, center + 0.5); ctx.lineTo(width, center + 0.5); ctx.stroke()
  })
  props.lines.forEach((data, lane) => {
    const center = centers[lane] ?? height / 2
    ctx.strokeStyle = props.stereo ? ['#72C8CF', '#A79ADB'][lane] : '#C9D4DF'
    ctx.beginPath()
    if (!data.length) { ctx.moveTo(0, center); ctx.lineTo(width, center) }
    else data.forEach((sample, index) => {
      const x = index * width / Math.max(1, data.length - 1)
      const y = center - Math.max(-1, Math.min(1, sample * 3 * (props.gain ?? 1))) * height * (props.stereo ? 0.21 : 0.4)
      if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
    })
    ctx.stroke()
  })
}

function tick() { if (dirty) { draw(); dirty = false }; animation = requestAnimationFrame(tick) }
onMounted(() => {
  observer = new ResizeObserver(() => { dirty = true })
  observer.observe(canvas.value!)
  animation = requestAnimationFrame(tick)
})
onUnmounted(() => { observer.disconnect(); cancelAnimationFrame(animation) })
</script>

<template><canvas ref="canvas" class="wave-canvas" aria-hidden="true" /></template>
