#!/usr/bin/env bash
# Test de chargement et de contenu : démarre un serveur Luanti headless (vrai moteur) avec xocean,
# dans un monde TEMPORAIRE hors du projet, laisse tourner quelques secondes, arrête, analyse le log.
# Un mod d'aide, écrit dans ce monde et jamais dans le projet, vérifie une fois tout chargé :
#   - textures (tiles, special_tiles, images d'inventaire, entités) présentes dans un textures/ ;
#   - modèles et sons des entités présents dans un models/ ou un sounds/ ;
#   - drops et ingrédients de recettes qui existent, groupes de recettes non vides ;
#   - objets d'autres mods utilisés sans être déclarés dans depends / optional_depends ;
#   - décorations : nœuds posés et supports (place_on) qui existent ;
#   - avec Mobs Redo : dauphin, 4 poissons et leurs œufs enregistrés ; sans : aucune entité xocean.
# Deux passes : SANS les dépendances optionnelles (toujours), puis AVEC si test_mods.txt ou
# EXTRA_WORLDMODS les fournissent (mobs).
# Sans joueur, aucun chunk n'est généré : la génération se teste avec smoke_test.sh.
#
# Usage : .claude/skills/luanti-test-debug/scripts/load_test.sh [secondes_après_démarrage]
# Variables : LUANTI_BIN, GAMEID (minetest), EXTRA_WORLDMODS, START_TIMEOUT (60),
#             ONLY (minimal | full : une seule passe)
# Codes : 0 = OK, 1 = erreurs/avertissements/problèmes du mod, 2 = impossible de lancer.

set -uo pipefail
. "$(dirname "$0")/lib.sh"

RUN_AFTER_START="${1:-3}"
START_TIMEOUT="${START_TIMEOUT:-60}"
HELPER_NAME="${MODNAME}_check"

LUANTI="$(find_luanti)" || { echo "ERREUR : binaire Luanti introuvable (définir LUANTI_BIN)."; exit 2; }
require_mods

OPTIONAL="$(optional_provided | tr '\n' ' ' | sed 's/ *$//')"
case "${ONLY:-}" in
	minimal) PASSES="minimal" ;;
	full) PASSES="full" ;;
	*) if [ -n "$OPTIONAL" ]; then PASSES="minimal full"; else PASSES="minimal"; fi ;;
esac

echo "Luanti : $("$LUANTI" --version 2>/dev/null | head -1)  |  jeu : $GAMEID  |  mod : $MODNAME"
[ -z "$OPTIONAL" ] && echo "Dépendances optionnelles non fournies ($(optional_depends | tr '\n' ' ')) : seule la passe sans elles tourne."

write_helper() {
	local helper="$1/worldmods/$HELPER_NAME"
	mkdir -p "$helper"
	printf 'name = %s\ndepends = %s\noptional_depends = %s\n' "$HELPER_NAME" "$MODNAME" \
		"$(optional_depends | paste -sd ',' - | sed 's/,/, /g')" > "$helper/mod.conf"
	cat > "$helper/init.lua" <<'LUA'
-- Mod d'aide du test de chargement de xocean (monde temporaire uniquement).
local MOD = "xocean"
local TAG = "[xocean_check] "
local problems, notes = 0, 0

local function problem(fmt, ...)
	problems = problems + 1
	core.log("action", TAG .. "PROBLÈME : " .. fmt:format(...))
end
local function note(fmt, ...)
	notes = notes + 1
	core.log("action", TAG .. "remarque : " .. fmt:format(...))
end

-- Fichiers présents dans <mod>/<sub>/ (sous-dossiers compris) de tous les mods chargés.
local function files_in(sub)
	local found = {}
	local function scan(dir)
		for _, f in ipairs(core.get_dir_list(dir, false) or {}) do
			found[f] = true
		end
		for _, d in ipairs(core.get_dir_list(dir, true) or {}) do
			scan(dir .. DIR_DELIM .. d)
		end
	end
	for _, m in ipairs(core.get_modnames()) do
		scan(core.get_modpath(m) .. DIR_DELIM .. sub)
	end
	return found
end

-- Dépendances déclarées dans mod.conf.
local declared = {[MOD] = true}
do
	local conf = Settings(core.get_modpath(MOD) .. DIR_DELIM .. "mod.conf")
	for _, key in ipairs({"depends", "optional_depends"}) do
		for _, m in ipairs((conf:get(key) or ""):split(",")) do
			declared[m:trim()] = true
		end
	end
end

local function resolve(name)
	return core.registered_aliases[name] or name
end

core.register_on_mods_loaded(function()
	local textures, models, sounds = files_in("textures"), files_in("models"), files_in("sounds")
	local engine_textures = {["blank.png"] = true, ["no_texture.png"] = true}
	local undeclared = {}

	local function check_texture_string(owner, s, only_own)
		if type(s) ~= "string" then
			return
		end
		for file in s:gmatch("([%w_%-%.]+%.png)") do
			if (not only_own or file:find("^" .. MOD .. "_"))
					and not textures[file] and not engine_textures[file] then
				problem("%s : texture introuvable « %s »", owner, file)
			end
		end
	end
	local function check_tiles(owner, list, only_own)
		for _, t in ipairs(list or {}) do
			check_texture_string(owner, type(t) == "table" and (t.name or t.image) or t, only_own)
		end
	end

	-- l'objet existe-t-il ? note si son mod n'est pas déclaré
	local function check_item(owner, what, name)
		if name == "" or name:find("^group:") then
			return
		end
		name = resolve(ItemStack(name):get_name())
		local def = core.registered_items[name]
		if not def then
			problem("%s : %s inconnu « %s »", owner, what, name)
			return
		end
		local origin = def.mod_origin or name:match("^([^:]+):")
		if origin and origin ~= "??" and not declared[origin] and not undeclared[origin .. name] then
			undeclared[origin .. name] = true
			note("%s : %s « %s » vient du mod « %s », absent de depends/optional_depends", owner, what, name, origin)
		end
	end

	-- 1. Objets et nœuds du mod (et nœuds d'autres mods retexturés par lui)
	local n_items, n_nodes = 0, 0
	for name, def in pairs(core.registered_items) do
		local own = name:find("^" .. MOD .. ":") ~= nil
		if own then
			n_items = n_items + 1
			if core.registered_nodes[name] then
				n_nodes = n_nodes + 1
			end
			if not def.description or def.description == "" then
				note("%s : pas de description", name)
			end
		end
		check_tiles(name, def.tiles, not own)
		check_tiles(name, def.overlay_tiles, not own)
		check_tiles(name, def.special_tiles, not own)
		for _, field in ipairs({"inventory_image", "wield_image", "inventory_overlay", "wield_overlay"}) do
			check_texture_string(name .. "." .. field, def[field], not own)
		end
		if own then
			local drop = def.drop
			if type(drop) == "string" then
				check_item(name, "drop", drop)
			elseif type(drop) == "table" then
				for _, entry in ipairs(drop.items or {}) do
					for _, it in ipairs(entry.items or {}) do
						check_item(name, "drop", it)
					end
				end
			end
		end
	end

	-- 2. Recettes qui produisent un objet du mod ou en utilisent un
	local groups = {}
	for _, def in pairs(core.registered_items) do
		for g in pairs(def.groups or {}) do
			groups[g] = true
		end
	end
	local n_recipes = 0
	for name in pairs(core.registered_items) do
		for _, r in ipairs(core.get_all_craft_recipes(name) or {}) do
			local uses_mod = name:find("^" .. MOD .. ":") ~= nil
			for _, it in pairs(r.items or {}) do
				if it:find("^" .. MOD .. ":") then
					uses_mod = true
				end
			end
			if uses_mod then
				n_recipes = n_recipes + 1
				local owner = ("recette de %s (%s)"):format(r.output or name, r.method or "normal")
				for _, it in pairs(r.items or {}) do
					local g = it:match("^group:(.+)$")
					if g then
						for one in g:gmatch("[^,]+") do
							if not groups[one] then
								problem("%s : aucun objet dans le groupe « %s »", owner, one)
							end
						end
					else
						check_item(owner, "ingrédient", it)
					end
				end
			end
		end
	end

	-- 3. Décorations : nœuds posés et supports existants. (core.registered_decorations est indexé
	-- par nom : un nom en double y est invisible, c'est lint.sh qui le repère.)
	local n_deco = 0
	for _, d in pairs(core.registered_decorations) do
		if d.name and d.name:find("^" .. MOD .. ":") then
			n_deco = n_deco + 1
			for _, n in ipairs(type(d.decoration) == "table" and d.decoration or {d.decoration}) do
				if type(n) == "string" and not core.registered_nodes[resolve(n)] then
					problem("décoration %s : nœud inconnu « %s »", d.name, n)
				end
			end
			for _, n in ipairs(type(d.place_on) == "table" and d.place_on or {d.place_on}) do
				if type(n) == "string" and not n:find("^group:") and not core.registered_nodes[resolve(n)] then
					problem("décoration %s : place_on inconnu « %s »", d.name, n)
				end
			end
		end
	end

	-- 4. Entités (Mobs Redo)
	local mobs_on = core.get_modpath("mobs") ~= nil
	local expected = {"xocean:dolphin", "xocean:fish", "xocean:fish2", "xocean:fish3", "xocean:fish4"}
	local n_ent = 0
	for name, def in pairs(core.registered_entities) do
		if name:find("^" .. MOD .. ":") then
			n_ent = n_ent + 1
			local props = def.initial_properties or def
			local mesh = props.mesh or def.mesh
			if mesh and not models[mesh] then
				problem("%s : modèle introuvable « %s »", name, mesh)
			end
			local function walk(t)
				if type(t) == "table" then
					for _, v in pairs(t) do walk(v) end
				else
					check_texture_string(name, t, false)
				end
			end
			walk(props.textures)
			walk(def.textures)
			for _, d in ipairs(def.drops or {}) do
				check_item(name, "drop", d.name)
			end
			-- sons (Mobs Redo : sounds = {random = "nom" ou {name, gain, pitch}, distance = n})
			for key, snd in pairs(def.sounds or {}) do
				local sname = type(snd) == "table" and snd.name or snd
				if type(sname) == "string" and sname ~= "" then
					local found = sounds[sname .. ".ogg"]
					for i = 0, 9 do
						found = found or sounds[("%s.%d.ogg"):format(sname, i)]
					end
					if not found then
						problem("%s : son « %s » (%s) introuvable dans un sounds/", name, sname, key)
					end
					if type(snd) == "table" and ((snd.gain or 1) <= 0 or (snd.pitch or 1) <= 0) then
						problem("%s : son « %s » avec gain ou pitch nul ou négatif", name, sname)
					end
				end
			end
		end
	end
	if mobs_on then
		for _, name in ipairs(expected) do
			if not core.registered_entities[name] then
				problem("Mobs Redo chargé mais entité %s absente", name)
			end
			if not core.registered_items[name] then
				problem("Mobs Redo chargé mais œuf %s absent", name)
			end
		end
	elseif n_ent > 0 then
		problem("%d entité(s) xocean enregistrée(s) alors que Mobs Redo est absent", n_ent)
	end

	core.log("action", TAG .. ("bilan : mobs=%s objets=%d noeuds=%d recettes=%d decorations=%d entites=%d problemes=%d remarques=%d")
		:format(mobs_on and "oui" or "non", n_items, n_nodes, n_recipes, n_deco, n_ent, problems, notes))
end)
LUA
}

status=0
for pass in $PASSES; do
	WORK="${TMPDIR:-/tmp}/${MODNAME}_loadtest_$pass"
	WORLD="$WORK/world"
	LOG="$WORK/debug.txt"
	CONF="$WORK/test.conf"
	rm -rf "$WORK"
	make_world "$WORLD" false "$pass"
	write_helper "$WORLD"
	cat > "$CONF" <<CONF
mg_name = v7
bind_address = 127.0.0.1
server_announce = false
enable_rollback_recording = false
deprecated_lua_api_handling = log
debug_log_level = action
CONF

	echo "=================================================================="
	if [ "$pass" = minimal ]; then
		echo "Passe SANS dépendances optionnelles (jeu + $MODNAME seulement)"
	else
		echo "Passe AVEC : $OPTIONAL $(test_mods | tr '\n' ' ')"
		extra="$(extra_worldmods | tr '\n' ' ')"
		[ -n "$extra" ] && echo "Mods par chemin : $extra"
	fi

	PID="$(start_server "$WORLD" "$CONF" "$LOG" "$WORK/console.txt")"
	started=0; t=0
	while kill -0 "$PID" 2>/dev/null; do
		if grep -q "listening on" "$LOG" 2>/dev/null; then started=1; break; fi
		[ "$t" -ge "$START_TIMEOUT" ] && break
		sleep 1; t=$((t + 1))
	done
	[ "$started" = 1 ] && sleep "$RUN_AFTER_START"   # laisse tourner core.after / timers
	stop_server "$PID"

	echo "------------------------------------------------------------------"
	pstatus=0
	if [ "$started" != 1 ]; then
		echo "ÉCHEC : le serveur n'a pas démarré (crash au chargement ou timeout ${START_TIMEOUT}s)."
		tail -20 "$WORK/console.txt" 2>/dev/null | sed 's/^/  /'
		pstatus=1
	fi
	analyse_log "$LOG" || pstatus=1
	bilan="$(grep "\[$HELPER_NAME\] bilan" "$LOG")"
	if [ -z "$bilan" ]; then
		[ "$started" = 1 ] && echo "ÉCHEC : le mod d'aide n'a pas rendu de bilan."
		pstatus=1
	elif ! echo "$bilan" | grep -q "problemes=0 "; then
		echo "ÉCHEC : problèmes de contenu (lignes PROBLÈME ci-dessus)."
		pstatus=1
	fi
	[ "$pstatus" = 0 ] && echo "OK ($pass) : '$MODNAME' se charge sans erreur ni problème de contenu."
	echo "Log complet : $LOG"
	[ "$pstatus" = 0 ] || status=1
done
exit $status
