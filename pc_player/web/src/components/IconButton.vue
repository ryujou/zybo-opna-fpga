<script setup lang="ts">
defineProps<{ icon: string; label: string; disabled?: boolean; active?: boolean }>()
const paths: Record<string, string> = {
  open: 'M2 6h7l2 2h11l-3 12H2V6Zm0 0V3h7l2 3',
  play: 'm7 3 14 9-14 9Z',
  pause: 'M7 4v16M17 4v16',
  stop: 'M5 5h14v14H5Z',
  restart: 'M3 10a9 9 0 1 1 2 9M3 3v7h7',
  list: 'M8 5h13M8 12h13M8 19h13M3 5h1M3 12h1M3 19h1',
  follow: 'M12 3v18M3 12h18M8 8h8v8H8Z',
  close: 'm5 5 14 14M19 5 5 19',
}
</script>

<template>
  <button class="icon-button" :class="{ active }" :aria-label="label" :title="label" :disabled="disabled" type="button">
    <svg viewBox="0 0 24 24" aria-hidden="true"><path :d="paths[icon]" /></svg>
  </button>
</template>
