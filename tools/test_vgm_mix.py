"""File-header regressions, with actual files checked against full libvgm loading."""
import gzip
import json
from pathlib import Path
import re
import struct
import unittest
import vgm_mix
import play_pc98

ROOT = Path(__file__).resolve().parents[1]


def fixture(entries=(), global_volume=0, version=0x171, start=0x100):
    data=bytearray(start)
    data[:4]=b'Vgm '
    struct.pack_into('<I',data,8,version)
    struct.pack_into('<I',data,0x34,start-0x34)
    struct.pack_into('<I',data,0x48,8000000)
    if start>0x7c: data[0x7c]=global_volume
    if entries:
        struct.pack_into('<I',data,0xbc,4)
        struct.pack_into('<III',data,0xc0,12,0,4)
        data[0xcc]=len(entries)
        for i,entry in enumerate(entries): struct.pack_into('<BBH',data,0xcd+4*i,*entry)
    data.extend(b'\x56\x08\x0f\x61\x44\xac\x66')
    struct.pack_into('<I',data,4,len(data)-4)
    return bytes(data)


class MixTests(unittest.TestCase):
    def test_defaults_and_short_header(self):
        self.assertEqual(vgm_mix.parse_mix(fixture()),(131072,21845,8192))
        self.assertEqual(vgm_mix.parse_mix(fixture(start=0x4c)),(131072,21845,8192))

    def test_absolute_relative_pair_and_instance(self):
        self.assertEqual(vgm_mix.parse_mix(fixture([(0x87,0,72)])),(131072,12288,8192))
        self.assertEqual(vgm_mix.parse_mix(fixture([(0x87,0,40)])),(262144,13653,8192))
        self.assertEqual(vgm_mix.parse_mix(fixture([(0x87,0,0x814c)])),(131072,28331,8192))
        self.assertEqual(vgm_mix.parse_mix(fixture([(7,0,64),(0x87,0,128)])),(131072,43691,8192))
        self.assertEqual(vgm_mix.parse_mix(fixture([(0x87,1,40)])),(131072,21845,8192))

    def test_zero_and_large_device_weights(self):
        self.assertEqual(vgm_mix.parse_mix(fixture([(7,0,0),(0x87,0,0)])),(0,0,8192))
        self.assertEqual(vgm_mix.parse_mix(fixture([(7,0,1024),(0x87,0,1024)])),(131072,21845,8192))

    def test_global(self):
        for byte,gain in [(0,8192),(32,16384),(0xe0,4096),(0xc1,2048),(0xc0,524288)]:
            self.assertEqual(vgm_mix.parse_mix(fixture(global_volume=byte))[2],gain)
        self.assertEqual(vgm_mix.parse_mix(fixture(global_volume=32,version=0x151))[2],8192)

    def test_gzip_events_and_truncated(self):
        original=fixture()
        changed=fixture([(0x87,0,40)],32)
        self.assertEqual(play_pc98.parse_vgm(original),play_pc98.parse_vgm(changed))
        self.assertEqual(vgm_mix.parse_mix(changed),vgm_mix.parse_mix(gzip.compress(changed)))
        damaged=bytearray(changed); struct.pack_into('<I',damaged,0xc8,0xffff)
        with self.assertRaises(ValueError): vgm_mix.parse_mix(damaged)

    def test_protocol_mismatch_and_echo(self):
        class USB:
            hello=b'\x02\x01'+bytes(22)
            wrong=False
            @classmethod
            def request(cls,d,i,command,payload=b''):
                return cls.hello if command==1 else bytes(12) if cls.wrong else payload
        with self.assertRaises(RuntimeError): vgm_mix.set_mix(USB,None,None,(1,2,3))
        USB.hello=b'\x02\x02'+bytes(22)
        vgm_mix.set_mix(USB,None,None,(1,2,3))
        USB.wrong=True
        with self.assertRaises(RuntimeError): vgm_mix.set_mix(USB,None,None,(1,2,3))

    def test_actual_files(self):
        directory=ROOT/'build/usb_dual/volume-fix'
        results=[]
        for name in json.loads((directory/'songs.json').read_text(encoding='utf-8')):
            path=Path(name)
            log=(directory/'references'/path.with_suffix('.log').name).read_text(encoding='utf-8')
            volumes=list(map(int,re.findall(r'volume_after=(\d+)',log)))
            expected=(round(2*volumes[0]/256*65536),round(volumes[1]/768*65536),8192)
            music,gains=play_pc98.load_music_with_mix(path)
            self.assertEqual(gains,expected,path.name)
            self.assertEqual(music,play_pc98.load_music(path))
            results.append(dict(file=name,gains_q16=list(gains),event_bytes=len(music[0]),sample_bytes=len(music[1])))
        (directory/'file-gains.json').write_text(json.dumps(results,indent=2),encoding='utf-8')


if __name__=='__main__':
    unittest.main()
