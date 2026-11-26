# Aperçu de ce que joue Luanti : pitch 0,7 (lecture plus lente et plus grave, comme le moteur) et gain 0,4.
import sys, numpy as np, soundfile as sf
src, dst = sys.argv[1], sys.argv[2]
d, sr = sf.read(src, always_2d=True)
sf.write(dst, (d * 0.4).astype(np.float32), int(sr * 0.7))
