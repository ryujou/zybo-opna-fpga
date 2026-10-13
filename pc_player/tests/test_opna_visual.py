from array import array
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from opna import PC98
from opna_visual import OpnaVisual, CAPACITY


class OpnaVisualTests(unittest.TestCase):
    def test_reference_and_voice_sum(self):
        if not (PC98 / "build/usb_dual/volume-fix/references/CT_maintheme.f32").exists():
            self.skipTest("Private music/reference fixtures are not distributed")
        path = PC98 / "build/native_music/CT_maintheme.vgm"
        core = OpnaVisual(path.read_bytes())
        try:
            core.advance_to(2)
            frame = core.snapshot([1, 2, 3, 7, 10, 11])
            self.assertTrue(all(len(lane) == 512 for lane in frame["total"] + frame["waves"]))
            self.assertGreater(max(map(abs, frame["waves"][-1])), .001)
            reference = array("f")
            with (PC98 / "build/usb_dual/volume-fix/references/CT_maintheme.f32").open("rb") as file:
                file.seek((96000 - CAPACITY) * 8)
                reference.fromfile(file, CAPACITY * 2)
            for i in range(CAPACITY):
                for lane in range(2):
                    # Different render block sizes round the linear resampler differently.
                    self.assertLess(abs(core.samples[lane * CAPACITY + i] - reference[i * 2 + lane] / 32768 / 8), 1 / 32768)
                total = (core.samples[i] + core.samples[CAPACITY + i]) / 2
                parts = sum(core.samples[lane * CAPACITY + i] for lane in range(2, 13))
                self.assertLess(abs(total - parts), .00002)
            core.advance_to(2)
            self.assertEqual(frame, core.snapshot([1, 2, 3, 7, 10, 11]))
            core.advance_to(2.1)
            self.assertNotEqual(frame["total"], core.snapshot([1, 2, 3, 7, 10, 11])["total"])
        finally:
            core.close()


if __name__ == "__main__":
    unittest.main()
