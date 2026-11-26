#!/usr/bin/env bash
# Test de génération dans le vrai moteur : monde TEMPORAIRE hors du projet (mapgen v7, graine fixe).
# Un mod d'aide, écrit dans ce monde et jamais dans le projet :
#   1. cherche un vrai océan (point où le mapgen refuse d'apparaître, biome *_ocean, eau en surface
#      sur au moins OCEAN_MIN % des colonnes), en essayant plusieurs candidats si besoin ;
#   2. génère la zone (±HALF nœuds, de y=-60 à y=8) avec core.emerge_area et compte, par
#      gennotify, combien de fois chaque décoration xocean a été posée ;
#   3. vérifie dans la zone : plantes enracinées (coraux, algues, herbiers, cornichons) avec de
#      l'eau au-dessus (sinon : à l'air libre = échec, enfouies sous un bloc = avertissement),
#      blocs de corail flottants (eau ou air dessous), pierre océanique (minerai) ;
#   4. avec Mobs Redo : force le chargement d'un bloc d'eau, y fait apparaître le dauphin et les
#      4 poissons, et vérifie après MOB_WAIT secondes qu'ils sont vivants et toujours dans l'eau.
# Puis il arrête le serveur.
#
# Usage : .claude/skills/luanti-test-debug/scripts/smoke_test.sh
# Variables : SEED (42), HALF (48), OCEAN_MIN (60), MOB_WAIT (8), POS ("x,z" : zone imposée, pas
#             de recherche), SMOKE_TIMEOUT (300 s), LUANTI_BIN, GAMEID (minetest), EXTRA_WORLDMODS,
#             NO_MOBS=1 (ne pas charger Mobs Redo même s'il est fourni)
# Codes : 0 = OK (avertissements possibles), 1 = erreur, plante à l'air libre, aucun contenu xocean
#         généré, mob mort ou sorti de l'eau, pas d'océan trouvé, génération inachevée ;
#         2 = impossible de lancer.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

SEED="${SEED:-42}"
HALF="${HALF:-48}"
OCEAN_MIN="${OCEAN_MIN:-60}"
MOB_WAIT="${MOB_WAIT:-8}"
POS="${POS:-}"
TIMEOUT="${SMOKE_TIMEOUT:-300}"
HELPER_NAME="${MODNAME}_smoke"
MODE=full; [ "${NO_MOBS:-0}" = 1 ] && MODE=minimal

LUANTI="$(find_luanti)" || { echo "ERREUR : binaire Luanti introuvable (définir LUANTI_BIN)."; exit 2; }
require_mods

# --- Monde temporaire et mod d'aide -----------------------------------------
WORK="${TMPDIR:-/tmp}/${MODNAME}_smoketest"
WORLD="$WORK/world"
LOG="$WORK/debug.txt"
CONF="$WORK/test.conf"
rm -rf "$WORK"
make_world "$WORLD" false "$MODE"
HELPER="$WORLD/worldmods/$HELPER_NAME"
mkdir -p "$HELPER"
printf 'name = %s\ndepends = %s\noptional_depends = mobs\n' "$HELPER_NAME" "$MODNAME" > "$HELPER/mod.conf"
cat > "$HELPER/init.lua" <<'LUA'
-- Mod d'aide du smoke test de xocean (monde temporaire uniquement).
local TAG = "[xocean_smoke] "
local HALF = tonumber(core.settings:get("xocean_smoke_half")) or 48
local OCEAN_MIN = tonumber(core.settings:get("xocean_smoke_ocean_min")) or 60
local MOB_WAIT = tonumber(core.settings:get("xocean_smoke_mob_wait")) or 8
local FORCED = core.settings:get("xocean_smoke_pos") or ""
local Y_MIN, Y_MAX = -60, 8
local MAX_TRIES = 6
local WL = tonumber(core.settings:get("water_level")) or 1

local function log(msg)
	core.log("action", TAG .. msg)
end
local function finish(msg)
	log("fin (" .. msg .. ")")
	core.after(0.5, core.request_shutdown, msg, false, 0)
end

-- Décorations du mod : comptées pendant la génération grâce à gennotify. On note aussi les
-- biomes qu'elles visent, pour chercher un océan où elles ont une chance d'apparaître.
local deco_ids, deco_count, target_biomes, n_targets = {}, {}, {}, 0
for _, d in pairs(core.registered_decorations) do
	if d.name and d.name:find("^xocean:") then
		for _, b in ipairs(type(d.biomes) == "table" and d.biomes or {d.biomes}) do
			if type(b) == "string" and not target_biomes[b] then
				target_biomes[b] = true
				n_targets = n_targets + 1
			end
		end
		local id = core.get_decoration_id(d.name)
		if id then
			deco_ids[id] = d.name
			deco_count[d.name] = 0
		end
	end
end
local ids = {}
for id in pairs(deco_ids) do
	ids[#ids + 1] = id
end
core.set_gen_notify({decoration = true}, ids)
core.register_on_generated(function()
	local gn = core.get_mapgen_object("gennotify") or {}
	for key, list in pairs(gn) do
		local id = tonumber(key:match("^decoration#(%d+)$"))
		if id and deco_ids[id] then
			deco_count[deco_ids[id]] = deco_count[deco_ids[id]] + #list
		end
	end
end)

local function listing(counts, limit)
	local list = {}
	for name, n in pairs(counts) do
		list[#list + 1] = {name = name, n = n}
	end
	table.sort(list, function(a, b) return a.n > b.n or (a.n == b.n and a.name < b.name) end)
	local out = {}
	for k, e in ipairs(list) do
		if limit and k > limit then
			break
		end
		out[#out + 1] = e.name .. "=" .. e.n
	end
	return #out > 0 and table.concat(out, " ") or "aucun"
end

-- Candidats : grille autour de l'origine, du plus proche au plus loin. Un point convient si le
-- mapgen n'y fait pas apparaître de joueur (sous l'eau ou trop haut) et si le biome est un océan
-- visé par les décorations du mod (ou n'importe quel *_ocean si elles n'en visent aucun), aux
-- 4 coins de la zone aussi.
local function biome_at(x, z)
	local data = core.get_biome_data({x = x, y = WL - 8, z = z})
	return data and core.get_biome_name(data.biome) or "?"
end
local function oceanish(x, z)
	if core.get_spawn_level(x, z) then
		return false
	end
	local name = biome_at(x, z)
	if n_targets > 0 then
		return target_biomes[name] == true
	end
	return name:find("_ocean$") ~= nil
end
local function candidates()
	if FORCED ~= "" then
		local x, z = FORCED:match("^%s*(-?%d+)%s*,%s*(-?%d+)%s*$")
		return {{x = tonumber(x), z = tonumber(z)}}
	end
	local pts = {}
	for x = -6000, 6000, 200 do
		for z = -6000, 6000, 200 do
			pts[#pts + 1] = {x = x, z = z, d = x * x + z * z}
		end
	end
	table.sort(pts, function(a, b) return a.d < b.d end)
	local out = {}
	for _, p in ipairs(pts) do
		if oceanish(p.x, p.z) and oceanish(p.x - HALF, p.z - HALF) and oceanish(p.x + HALF, p.z + HALF)
				and oceanish(p.x - HALF, p.z + HALF) and oceanish(p.x + HALF, p.z - HALF) then
			out[#out + 1] = p
			if #out >= MAX_TRIES then
				break
			end
		end
	end
	return out
end

-- Mobs : apparition dans un bloc d'eau chargé de force, contrôle après MOB_WAIT secondes.
local function test_mobs(water_pos, after)
	if not core.get_modpath("mobs") then
		log("mobs : Mobs Redo absent, test des créatures sauté")
		return after()
	end
	if not water_pos then
		core.log("error", TAG .. "mobs : aucune eau assez profonde pour le test des créatures")
		return after()
	end
	-- cube de 3x3x3 blocs autour du point (max_forceloaded_blocks relevé dans la config)
	local blocks = {}
	for dx = -16, 16, 16 do
		for dy = -16, 16, 16 do
			for dz = -16, 16, 16 do
				local b = vector.offset(water_pos, dx, dy, dz)
				core.forceload_block(b, true)
				blocks[#blocks + 1] = b
			end
		end
	end
	core.after(3, function() -- les blocs deviennent actifs au pas de gestion suivant
		local names = {"xocean:dolphin", "xocean:fish", "xocean:fish2", "xocean:fish3", "xocean:fish4"}
		local mobs_t, elapsed = {}, 0
		for k, name in ipairs(names) do
			local obj = core.add_entity(vector.offset(water_pos, (k - 3) * 2, 0, 0), name)
			mobs_t[k] = {name = name, obj = obj, ent = obj and obj:get_luaentity(), dry = 0, where = nil}
		end
		-- toutes les 0,5 s : la créature est-elle encore dans l'eau ?
		local function sample()
			elapsed = elapsed + 0.5
			for _, m in ipairs(mobs_t) do
				local pos = m.obj and m.obj:get_pos()
				if pos then
					local node = core.get_node(vector.round(pos)).name
					if core.get_item_group(node, "water") == 0 then
						m.dry, m.where = m.dry + 1, node
					end
				end
			end
			if elapsed < MOB_WAIT then
				return core.after(0.5, sample)
			end
			local states, bad = {}, 0
			for _, m in ipairs(mobs_t) do
				local state
				local hp = m.ent and m.ent.health
				if not m.obj then
					state, bad = "non_créé", bad + 1
				elseif hp and hp <= 0 then
					state, bad = "mort", bad + 1
				elseif m.dry > 2 then -- plus d'une seconde hors de l'eau
					state, bad = ("hors_eau(%s, %.1f s)"):format(m.where, m.dry / 2), bad + 1
				elseif not m.obj:get_pos() then
					state = "sorti_de_la_zone_chargée" -- désactivé, pas un défaut
				else
					state = ("vivant(pv=%s)"):format(hp or "?")
				end
				states[#states + 1] = m.name .. "=" .. state
			end
			log(("mobs : %s ; problemes_mobs=%d"):format(table.concat(states, " "), bad))
			for _, b in ipairs(blocks) do
				core.forceload_free_block(b, true)
			end
			after()
		end
		core.after(0.5, sample)
	end)
end

local function analyse(p1, p2, seconds)
	local id = core.get_content_id
	local c_air, c_water, c_sand = id("air"), id("default:water_source"), id("default:sand")
	local rooted, coral_block, liquid, own = {}, {}, {}, {}
	for name, def in pairs(core.registered_nodes) do
		local cid = id(name)
		if def.drawtype == "plantlike_rooted" then
			rooted[cid] = true
		elseif (def.groups or {}).coral then
			coral_block[cid] = true
		end
		if def.liquidtype == "source" or def.liquidtype == "flowing" then
			liquid[cid] = true
		end
		own[cid] = name:find("^xocean:") or (def.groups or {}).coral or name == "default:sand_with_kelp"
	end
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map(p1, p2)
	local area = VoxelArea:new({MinEdge = e1, MaxEdge = e2})
	local data = vm:get_data()
	local ys = area.ystride
	local by_id, n_rooted, dry, buried, floating, columns, wet = {}, 0, {}, {}, 0, 0, 0
	local water_pos
	for z = p1.z, p2.z do
		for x = p1.x, p2.x do
			columns = columns + 1
			if data[area:index(x, WL - 1, z)] == c_water then
				wet = wet + 1
			end
			for y = p1.y + 1, p2.y - 1 do
				local vi = area:index(x, y, z)
				local cid = data[vi]
				if own[cid] then
					by_id[cid] = (by_id[cid] or 0) + 1
				end
				if rooted[cid] then
					n_rooted = n_rooted + 1
					local above = data[vi + ys]
					if not liquid[above] then
						-- à l'air libre (visible, anormal sous l'océan) ou enfouie sous un bloc
						local list = above == c_air and dry or buried
						list[#list + 1] = ("%s@(%d,%d,%d) sous %s"):format(core.get_name_from_content_id(cid),
							x, y, z, core.get_name_from_content_id(above))
					end
				elseif coral_block[cid] then
					local below = data[vi - ys]
					if below == c_air or below == c_water then
						floating = floating + 1
					end
				elseif not water_pos and cid == c_water and y <= WL - 5 and y >= WL - 9
						and data[vi + ys] == c_water and data[vi - ys] == c_water
						and data[vi + 2 * ys] == c_water and data[vi - 2 * ys] == c_water
						and math.abs(x - (p1.x + p2.x) / 2) < HALF / 2 then
					water_pos = vector.new(x, y, z)
				end
			end
		end
	end
	local by_name, total = {}, 0
	for cid, n in pairs(by_id) do
		by_name[core.get_name_from_content_id(cid)] = n
		total = total + n
	end
	local active, never = 0, {}
	for name, n in pairs(deco_count) do
		if n > 0 then
			active = active + 1
		else
			never[#never + 1] = name
		end
	end
	table.sort(never)
	local ocean = math.floor(100 * wet / columns + 0.5)
	log(("zone générée en %.1f s : %s à %s, océan en surface %d%%"):format(seconds,
		core.pos_to_string(p1), core.pos_to_string(p2), ocean))
	log("nœuds xocean/coraux : " .. listing(by_name, 40))
	log("décorations posées (toute la zone générée) : " .. listing(deco_count))
	if #never > 0 then
		log("décorations jamais posées : " .. table.concat(never, " "))
	end
	for k = 1, math.min(5, #dry) do
		log("plante à l'air libre : " .. dry[k])
	end
	for k = 1, math.min(3, #buried) do
		log("plante enfouie : " .. buried[k])
	end
	log(("bilan : ocean=%d%% contenu=%d enracinees=%d a_l_air=%d enfouies=%d coraux_flottants=%d pierre_ocean=%d decorations_actives=%d/%d")
		:format(ocean, total, n_rooted, #dry, #buried, floating, by_name["xocean:ocean_stone"] or 0, active, active + #never))
	return ocean, water_pos
end

core.after(1, function()
	local list = candidates()
	if #list == 0 then
		core.log("error", TAG .. "aucun océan visé par le mod à moins de 6000 nœuds (essayer une autre SEED ou POS=x,z)")
		return finish("xocean smoke test failed")
	end
	local where = {}
	for _, p in ipairs(list) do
		where[#where + 1] = ("(%d,%d) %s"):format(p.x, p.z, biome_at(p.x, p.z))
	end
	log("océans candidats : " .. table.concat(where, " "))
	local function try(k)
		local c = list[k]
		if not c then
			core.log("error", TAG .. "aucun candidat n'a assez d'eau en surface (OCEAN_MIN=" .. OCEAN_MIN .. "%)")
			return finish("xocean smoke test failed")
		end
		local p1 = vector.new(c.x - HALF, Y_MIN, c.z - HALF)
		local p2 = vector.new(c.x + HALF, Y_MAX, c.z + HALF)
		log(("candidat %d : génération de %s à %s"):format(k, core.pos_to_string(p1), core.pos_to_string(p2)))
		local t0 = core.get_us_time()
		core.emerge_area(p1, p2, function(_, _, remaining)
			if remaining > 0 then
				return
			end
			local ocean, water_pos = analyse(p1, p2, (core.get_us_time() - t0) / 1e6)
			if ocean < OCEAN_MIN and FORCED == "" then
				log(("candidat %d : seulement %d%% d'océan, candidat suivant"):format(k, ocean))
				return try(k + 1)
			end
			test_mobs(water_pos, function()
				finish("xocean smoke test done")
			end)
		end)
	end
	try(1)
end)
LUA

cat > "$CONF" <<CONF
mg_name = v7
fixed_map_seed = $SEED
bind_address = 127.0.0.1
server_announce = false
enable_rollback_recording = false
deprecated_lua_api_handling = log
debug_log_level = action
max_forceloaded_blocks = 64
remove_far_mobs = false
xocean_smoke_half = $HALF
xocean_smoke_ocean_min = $OCEAN_MIN
xocean_smoke_mob_wait = $MOB_WAIT
xocean_smoke_pos = $POS
CONF

echo "Luanti : $("$LUANTI" --version 2>/dev/null | head -1)  |  jeu : $GAMEID  |  graine : $SEED  |  zone ±$HALF${POS:+  |  POS=$POS}"
[ "$MODE" = full ] && [ -n "$(optional_provided)" ] && echo "Avec : $(optional_provided | tr '\n' ' ')"
PID="$(start_server "$WORLD" "$CONF" "$LOG" "$WORK/console.txt")"
wait_server "$PID" "$TIMEOUT"

# --- Analyse -----------------------------------------------------------------
echo "------------------------------------------------------------------"
status=0
analyse_log "$LOG" || status=1
bilan="$(grep "\[$HELPER_NAME\] bilan" "$LOG" | tail -1)"
if ! grep -q "\[$HELPER_NAME\] fin" "$LOG"; then
	echo "ÉCHEC : test inachevé en ${TIMEOUT}s (ou serveur arrêté avant)."
	status=1
fi
if [ -n "$bilan" ]; then
	if echo "$bilan" | grep -q " contenu=0 "; then
		echo "ÉCHEC : aucun nœud xocean ni corail généré dans l'océan."
		status=1
	fi
	if ! echo "$bilan" | grep -q " a_l_air=0 "; then
		echo "ÉCHEC : des plantes enracinées sont à l'air libre (air au-dessus au lieu d'eau)."
		status=1
	fi
	if ! echo "$bilan" | grep -q " enfouies=0 "; then
		echo "Attention : des plantes enracinées sont enfouies sous un bloc (plante cachée dans le bloc du dessus)."
	fi
	if grep -q "\[$HELPER_NAME\] décorations jamais posées" "$LOG"; then
		echo "Attention : des décorations ne sont jamais posées dans la zone (voir la ligne « jamais posées »)."
	fi
	if ! echo "$bilan" | grep -q " coraux_flottants=0 "; then
		echo "Attention : des blocs de corail flottent (eau ou air dessous), à vérifier en jeu."
	fi
	if echo "$bilan" | grep -q " pierre_ocean=0 "; then
		echo "Attention : pas de pierre océanique (minerai rare) dans la zone."
	fi
fi
mobs="$(grep "\[$HELPER_NAME\] mobs :" "$LOG" | tail -1)"
if echo "$mobs" | grep -q "problemes_mobs=" && ! echo "$mobs" | grep -q "problemes_mobs=0"; then
	echo "ÉCHEC : au moins une créature est morte, a disparu ou est sortie de l'eau."
	status=1
fi
[ "$status" = 0 ] && echo "OK : océan généré avec le contenu xocean, sans erreur ni plante à l'air libre."
echo "Log complet : $LOG"
exit $status
