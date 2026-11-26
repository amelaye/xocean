#!/usr/bin/env bash
# Lint du mod xocean.
#  - luacheck s'il est installé, avec la config luacheckrc de ce dossier ;
#  - sinon : vérification syntaxique + détection des globales via le bytecode LuaJIT
#    (globales écrites = oubli de 'local', globales lues inconnues = faute de frappe ou
#    dépendance non déclarée) ;
#  - puis (sans fichiers en argument) : noms de décorations en double, sons (Vorbis, mono),
#    traductions. Chaînes S("…") absentes de
#    locale/template.txt ou d'un .tr, entrées devenues inutiles. Non bloquant.
# Usage : .claude/skills/luanti-test-debug/scripts/lint.sh [fichiers.lua...]

set -uo pipefail
. "$(dirname "$0")/lib.sh"
CFG="$SCRIPTS_DIR/luacheckrc"
cd "$MOD_DIR"

ALL=1
if [ "$#" -gt 0 ]; then FILES=("$@"); ALL=0; else
	FILES=(); while IFS= read -r f; do FILES+=("$f"); done < <(find . -name '*.lua' -not -path './.claude/*' -not -path './.git/*' | sort)
fi
[ "${#FILES[@]}" -eq 0 ] && { echo "Aucun fichier Lua."; exit 0; }

status=0
if command -v luacheck >/dev/null 2>&1; then
	luacheck --config "$CFG" --no-color "${FILES[@]}" || status=1
else
	command -v luajit >/dev/null 2>&1 || { echo "Ni luacheck ni luajit disponibles."; exit 2; }
	echo "(luacheck absent : fallback LuaJIT. Pour une analyse complète, installer luacheck, avec accord.)"

	# Globales autorisées : à tenir à jour avec luacheckrc.
	WRITE_OK=" $MODNAME "
	READ_OK=" core minetest vector ItemStack VoxelArea VoxelManip PseudoRandom PcgRandom SecureRandom
 PerlinNoise PerlinNoiseMap ValueNoise ValueNoiseMap Settings AreaStore Raycast dump dump2 DIR_DELIM INIT PLATFORM
 assert error pcall xpcall select next type tostring tonumber pairs ipairs print unpack rawget rawset rawequal rawlen
 setmetatable getmetatable dofile loadstring load _G _VERSION table string math os io debug bit jit coroutine
 collectgarbage require
 default stairs walls doors screwdriver creative dye bucket xpanes beds fire tnt player_api
 mobs $MODNAME "

	for f in "${FILES[@]}"; do
		if ! out="$(luajit -bl "$f" 2>&1)"; then
			echo "$f: ERREUR DE SYNTAXE"; echo "$out" | head -5 | sed 's/^/    /'; status=1; continue
		fi
		for g in $(echo "$out" | sed -n 's/.*GSET.*; "\(.*\)"$/\1/p' | sort -u); do
			case "$WRITE_OK" in *" $g "*) ;; *) echo "$f: globale ÉCRITE non autorisée : $g (oubli de 'local' ?)"; status=1 ;; esac
		done
		for g in $(echo "$out" | sed -n 's/.*GGET.*; "\(.*\)"$/\1/p' | sort -u); do
			case "$READ_OK" in *" $g "*) ;; *) echo "$f: globale lue inconnue : $g (faute de frappe ? dépendance manquante ?)"; status=1 ;; esac
		done
	done
	[ "$status" = 0 ] && echo "OK : ${#FILES[@]} fichier(s), syntaxe valide, aucune globale suspecte."
fi

# --- Noms de décorations en double (non bloquant) ----------------------------
# Une décoration enregistrée deux fois sous le même nom est invisible dans core.registered_decorations
# et core.get_decoration_id n'en retrouve qu'une : seul l'examen du code la repère.
if [ "$ALL" = 1 ]; then
	# fichiers qui enregistrent des décorations, directement ou par une fonction d'aide
	# (register_coral_plant({…}) etc.) : le champ name de chaque appel register_*({…})
	dups="$(grep -rl --include='*.lua' --exclude-dir=.claude --exclude-dir=.git 'register_decoration' . \
		| tr '\n' '\0' \
		| xargs -0 perl -0777 -ne 'while (/register_\w+\s*\(\s*\{(.*?)\n\}\)/sg) { my $b = $1; print "$1\n" if $b =~ /^\s*name\s*=\s*"([^"]+)"/m }' \
		| sort | uniq -d)"
	[ -n "$dups" ] && echo "Décorations au nom en double (non bloquant) : $(echo $dups)"
fi

# --- Sons (non bloquant) ------------------------------------------------------
# Luanti ne lit que l'Ogg Vorbis, et ne place dans l'espace que les sons MONO : un son stéréo
# attaché à un mob s'entend au même volume quelle que soit la distance.
if [ "$ALL" = 1 ] && [ -d sounds ]; then
	snd="$(python3 -I - sounds <<'PY'
import os, sys
d = sys.argv[1]
for f in sorted(os.listdir(d)):
    if not f.endswith(".ogg"):
        continue
    head = open(os.path.join(d, f), "rb").read(64)
    i = head.find(b"\x01vorbis")
    if not head.startswith(b"OggS") or i < 0:
        print(f"  {f} : pas de l'Ogg Vorbis (illisible par Luanti)")
    elif head[i + 11] != 1:
        print(f"  {f} : {head[i + 11]} canaux, non positionnel en jeu (le passer en mono)")
PY
)"
	if [ -n "$snd" ]; then echo "Sons (non bloquant) :"; echo "$snd"; else echo "Sons : $(ls sounds/*.ogg 2>/dev/null | wc -l | tr -d ' ') fichier(s) .ogg, tous Vorbis mono."; fi
fi

# --- Traductions (non bloquant) ---------------------------------------------
if [ "$ALL" = 1 ] && [ -d locale ]; then
	tmp="$(mktemp -d)"
	# chaînes passées à S("…") ou S('…') dans le code chargé
	find . -name '*.lua' -not -path './.claude/*' -not -path './.git/*' -print0 \
		| xargs -0 perl -ne 'while (/\bS\(\s*"((?:[^"\\]|\\.)*)"/g) { print "$1\n" } while (/\bS\(\s*'"'"'((?:[^'"'"'\\]|\\.)*)'"'"'/g) { print "$1\n" }' \
		| sort -u > "$tmp/code"
	keys() { grep -v -E '^(#|$)' "$1" | perl -ne 'chomp; if (/^((?:[^=@]|@.)*)=/) { print "$1\n" }' | sed 's/@=/=/g' | sort -u; }
	report=""
	if [ -f locale/template.txt ]; then
		keys locale/template.txt > "$tmp/tpl"
		miss="$(comm -23 "$tmp/code" "$tmp/tpl")"
		extra="$(comm -13 "$tmp/code" "$tmp/tpl")"
		[ -n "$miss" ] && report="$report\n  absentes de template.txt : $(echo "$miss" | paste -sd '|' - | sed 's/|/ | /g')"
		[ -n "$extra" ] && report="$report\n  inutiles dans template.txt : $(echo "$extra" | paste -sd '|' - | sed 's/|/ | /g')"
	else
		report="$report\n  locale/template.txt absent"
	fi
	for tr in locale/*.tr; do
		[ -f "$tr" ] || continue
		keys "$tr" > "$tmp/tr"
		miss="$(comm -23 "$tmp/code" "$tmp/tr")"
		empty="$(grep -E '=$' "$tr" | grep -v '^#' | wc -l | tr -d ' ')"
		[ -n "$miss" ] && report="$report\n  absentes de $(basename "$tr") : $(echo "$miss" | wc -l | tr -d ' ') ($(echo "$miss" | head -5 | paste -sd '|' - | sed 's/|/ | /g')…)"
		[ "$empty" != 0 ] && report="$report\n  non traduites dans $(basename "$tr") : $empty"
	done
	if [ -n "$report" ]; then
		echo -e "Traductions (non bloquant) : $(wc -l < "$tmp/code" | tr -d ' ') chaînes S() dans le code$report"
	else
		echo "Traductions : $(wc -l < "$tmp/code" | tr -d ' ') chaînes S(), toutes présentes dans template.txt et les .tr."
	fi
	rm -rf "$tmp"
fi
exit $status
