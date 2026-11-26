# Sources des sons de xocean

`sounds/dolphin_call.{1,2,3}.ogg` sont synthétisés par `synth_dolphin.py` (26/11/2026) : sifflements
glissés doux, mono (donc positionnels en jeu), Ogg Vorbis 48 kHz, -18 dB RMS, rien au-dessus de 4 kHz.
Les fréquences sont pensées pour le `pitch = 0.7` de `mobs/dolphin.lua` (entendu ≈ 0,7 × la valeur).

1. Le cri ouii-ou : montée puis descente (950 → 1420 → 1020 Hz).
2. Deux petits gazouillis.
3. Le roucoulement : une trille lente qui descend puis remonte un peu.

## Régénérer
Il faut numpy et soundfile, installés avec accord dans un venv **hors du projet** (rien dans le dépôt) :

```bash
VENV="$TMPDIR/xocean_venv"
python3 -m venv "$VENV" && "$VENV/bin/pip" install -q numpy soundfile
"$VENV/bin/python" -I .claude/sounds_src/synth_dolphin.py <dossier_de_sortie>   # écrit .ogg + .wav
"$VENV/bin/python" -I .claude/sounds_src/apercu.py <son.ogg> <apercu.wav>       # rendu en jeu : pitch 0,7, gain 0,4
afplay <apercu.wav>
```

Copier ensuite les `.ogg` dans `sounds/`, puis lancer `lint.sh` (Vorbis + mono) et `load_test.sh` (sons trouvés).
