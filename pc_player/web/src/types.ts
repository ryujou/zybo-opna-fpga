export interface SongInfo {
  id: string
  name: string
  title: string
  format: 'MIDI' | 'VGM' | 'VGZ' | 'PMD'
  mode: 'midi' | 'vgm' | 'opna'
  duration: number
  metadata: Record<string, string>
}

export interface TimelineRow { time: number; cells: Record<string, string[]> }
export interface SongIndex extends SongInfo { columns: number; rows: TimelineRow[] }
export interface Device { id: string; name: string; mode: 'midi' | 'vgm' | 'opna' }
export interface Channel { id: number; program: number; name: string; active: boolean; note: number | null }
export interface OplChannel { id: number; pair: number; kind: number; active: boolean; note: number | null; frequency: number }

export interface Snapshot {
  test_mode: boolean
  status: 'empty' | 'ready' | 'uploading' | 'playing' | 'paused' | 'ended'
  error: string
  position: number
  cursor: number
  voices: number[]
  selected: string | null
  playlist: SongInfo[]
  devices: { items: Device[]; error: string }
  device: Device | null
  upload: number
  channels: Channel[]
  opl: OplChannel[]
  total: number[][]
  waves: number[][]
}

export type Action = 'select' | 'play' | 'pause' | 'resume' | 'stop' | 'restart'
