#!/usr/bin/env bash
# Test de survie des mobs au bord de l'eau (vrai moteur, Mobs Redo obligatoire). Dans un monde
# TEMPORAIRE vide (mapgen singlenode), un mod d'aide construit un bassin :
#   x 0..19 : eau de 4 de profondeur (y -3..0) sur du sable ;
#   x 20..22 : plage en pente (eau de 3, 2 puis 1 de profondeur) ;
#   x 23..31 : sable à y=0, air au-dessus ; murs de pierre sur les autres côtés.
# Il charge de force la zone, fait apparaître PER_TYPE exemplaires de chaque poisson près de la
# plage et sous la surface, plus 2 dauphins, puis observe pendant DURATION secondes (toutes les
# 0,25 s) : sorties de l'eau par la surface ou sur la plage, temps passé hors de l'eau, morts,
# distance parcourue (un poisson qui ne meurt plus doit encore nager).
# L'IA des mobs est aléatoire : les chiffres varient d'un lancement à l'autre.
#
# Usage : .claude/skills/luanti-test-debug/scripts/shore_test.sh
# Variables : DURATION (60), PER_TYPE (4), LUANTI_BIN, GAMEID (minetest), EXTRA_WORLDMODS
# Codes : 0 = aucun mob mort, 1 = au moins un mort (ou erreur), 2 = impossible de lancer
#         (dont Mobs Redo absent).

set -uo pipefail
. "$(dirname "$0")/lib.sh"

DURATION="${DURATION:-60}"
PER_TYPE="${PER_TYPE:-4}"
HELPER_NAME="${MODNAME}_shore"

LUANTI="$(find_luanti)" || { echo "ERREUR : binaire Luanti introuvable (définir LUANTI_BIN)."; exit 2; }
require_mods
if ! optional_provided | grep -qx mobs; then
	echo "ERREUR : Mobs Redo n'est pas fourni (test_mods.txt ou EXTRA_WORLDMODS) : rien à tester."
	exit 2
fi

WORK="${TMPDIR:-/tmp}/${MODNAME}_shoretest"
WORLD="$WORK/world"
LOG="$WORK/debug.txt"
CONF="$WORK/test.conf"
rm -rf "$WORK"
make_world "$WORLD" false full
HELPER="$WORLD/worldmods/$HELPER_NAME"
mkdir -p "$HELPER"
printf 'name = %s\ndepends = %s, mobs\n' "$HELPER_NAME" "$MODNAME" > "$HELPER/mod.conf"
cat > "$HELPER/init.lua" <<'LUA'
-- Mod d'aide du test de rivage de xocean (monde temporaire uniquement).
local TAG = "[xocean_shore] "
local DURATION = tonumber(core.settings:get("xocean_shore_duration")) or 60
local PER_TYPE = tonumber(core.settings:get("xocean_shore_per_type")) or 4
local P1, P2 = vector.new(-1, -8, -1), vector.new(32, 4, 16)

local function log(msg)
	core.log("action", TAG .. msg)
end

local function build()
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map(P1, P2)
	local area = VoxelArea:new({MinEdge = e1, MaxEdge = e2})
	local data = vm:get_data()
	local id = core.get_content_id
	local c_air, c_stone, c_sand, c_water = id("air"), id("default:stone"), id("default:sand"),
		id("default:water_source")
	-- hauteur du sable par colonne x : fond du bassin, pente, plage
	local function sand_top(x)
		if x <= 19 then return -4 end
		if x == 20 then return -3 end
		if x == 21 then return -2 end
		if x == 22 then return -1 end
		return 0
	end
	for z = P1.z, P2.z do
		for y = P1.y, P2.y do
			for x = P1.x, P2.x do
				local c = c_air
				local wall = x == P1.x or z == P1.z or z == P2.z or x == P2.x
				if y <= -5 then
					c = c_stone
				elseif wall then
					c = y <= 2 and c_stone or c_air
				elseif y <= sand_top(x) then
					c = c_sand
				elseif y <= 0 then
					c = c_water
				end
				data[area:index(x, y, z)] = c
			end
		end
	end
	vm:set_data(data)
	vm:write_to_map(true)
end

local function in_water(name)
	return core.get_item_group(name, "water") > 0
end

local function run()
	local names = {"xocean:fish", "xocean:fish2", "xocean:fish3", "xocean:fish4"}
	local mobs_t = {}
	local function spawn(name, pos)
		local obj = core.add_entity(pos, name)
		mobs_t[#mobs_t + 1] = {name = name, obj = obj, ent = obj and obj:get_luaentity(),
			out = 0, surface = 0, shore = 0, was_out = false, dead = nil, minhp = nil, dist = 0}
	end
	for k, name in ipairs(names) do
		for i = 1, PER_TYPE do
			-- près de la plage (x 15..19), juste sous la surface (y -1 et 0)
			spawn(name, vector.new(15 + (i - 1) % 5, -(i % 2), 2 + 3 * (k - 1)))
		end
	end
	spawn("xocean:dolphin", vector.new(12, -2, 5))
	spawn("xocean:dolphin", vector.new(12, -2, 11))

	local elapsed = 0
	local function sample()
		elapsed = elapsed + 0.25
		for _, m in ipairs(mobs_t) do
			if m.ent and not m.dead then
				local pos = m.obj:get_pos()
				local hp = m.ent.health or 0
				m.minhp = math.min(m.minhp or hp, hp)
				if not pos or hp <= 0 then
					m.dead = ("à %.1f s, dans « %s » en %s"):format(elapsed, m.ent.standing_in or "?",
						m.last and core.pos_to_string(m.last, 1) or "?")
				else
					if m.last then
						m.dist = m.dist + vector.distance(m.last, pos)
					end
					m.last = pos
					local here = core.get_node(vector.round(pos)).name
					if in_water(here) then
						m.was_out = false
					else
						m.out = m.out + 0.25
						if not m.was_out then
							m.was_out = true
							-- sortie par la surface (eau dessous) ou sur la plage (sable dessous)
							local below = core.get_node(vector.round(vector.offset(pos, 0, -1, 0))).name
							if in_water(below) then m.surface = m.surface + 1 else m.shore = m.shore + 1 end
						end
					end
				end
			end
		end
		if elapsed < DURATION then
			return core.after(0.25, sample)
		end
		local per_name, dead_total = {}, 0
		for _, m in ipairs(mobs_t) do
			local s = per_name[m.name] or {n = 0, dead = 0, out = 0, surface = 0, shore = 0, dist = 0}
			per_name[m.name] = s
			s.n = s.n + 1
			s.out, s.surface, s.shore = s.out + m.out, s.surface + m.surface, s.shore + m.shore
			s.dist = s.dist + m.dist
			if m.dead then
				s.dead = s.dead + 1
				dead_total = dead_total + 1
				log(("mort : %s %s"):format(m.name, m.dead))
			end
		end
		local order = {"xocean:fish", "xocean:fish2", "xocean:fish3", "xocean:fish4", "xocean:dolphin"}
		for _, name in ipairs(order) do
			local s = per_name[name]
			if s then
				log(("%s : %d/%d morts, sorties surface=%d plage=%d, %.1f s hors de l'eau au total, %.0f nœuds parcourus en moyenne")
					:format(name, s.dead, s.n, s.surface, s.shore, s.out, s.dist / s.n))
			end
		end
		log(("bilan : mobs=%d morts=%d duree=%d"):format(#mobs_t, dead_total, DURATION))
		core.request_shutdown("xocean shore test done", false, 0)
	end
	core.after(0.25, sample)
end

core.after(1, function()
	core.emerge_area(vector.offset(P1, -16, -16, -16), vector.offset(P2, 16, 16, 16), function(_, _, remaining)
		if remaining > 0 then
			return
		end
		build()
		for x = P1.x, P2.x + 15, 16 do
			for y = P1.y, P2.y + 15, 16 do
				for z = P1.z, P2.z + 15, 16 do
					core.forceload_block(vector.new(math.min(x, P2.x), math.min(y, P2.y), math.min(z, P2.z)), true)
				end
			end
		end
		log(("bassin construit, observation pendant %d s"):format(DURATION))
		core.after(3, run) -- les blocs deviennent actifs au pas de gestion suivant
	end)
end)
LUA

cat > "$CONF" <<CONF
mg_name = singlenode
bind_address = 127.0.0.1
server_announce = false
enable_rollback_recording = false
deprecated_lua_api_handling = log
debug_log_level = action
max_forceloaded_blocks = 64
remove_far_mobs = false
mobs_spawn = false
xocean_shore_duration = $DURATION
xocean_shore_per_type = $PER_TYPE
CONF

echo "Luanti : $("$LUANTI" --version 2>/dev/null | head -1)  |  $PER_TYPE × 4 poissons + 2 dauphins  |  ${DURATION} s"
PID="$(start_server "$WORLD" "$CONF" "$LOG" "$WORK/console.txt")"
wait_server "$PID" $((DURATION + 90))

echo "------------------------------------------------------------------"
status=0
analyse_log "$LOG" || status=1
bilan="$(grep "\[$HELPER_NAME\] bilan" "$LOG")"
if [ -z "$bilan" ]; then
	echo "ÉCHEC : test inachevé."
	status=1
elif ! echo "$bilan" | grep -q " morts=0 "; then
	echo "ÉCHEC : des mobs meurent au bord de l'eau."
	status=1
fi
[ "$status" = 0 ] && echo "OK : aucun mob mort en ${DURATION} s au bord de l'eau."
echo "Log complet : $LOG"
exit $status
