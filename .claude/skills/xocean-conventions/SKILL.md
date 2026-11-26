---
name: xocean-conventions
description: Conventions et structure du mod Luanti xocean (océan, coraux, poissons) - arborescence, namespace global, nœuds de Minetest Game surchargés, dépendance optionnelle Mobs Redo, spawn personnalisé, décorations du mapgen, traductions. À charger avant de modifier, relire ou tester le mod.
user-invocable: false
---

# Conventions de xocean

Mod **`xocean`** pour Luanti, jeu **Minetest Game**. Ajoute des poissons, un dauphin, des récifs de corail, des blocs décoratifs océaniques. Fork du mod de starninjas (licence MIT, `LICENSE.md`), maintenu par amelaye. Version affichée dans `README.md` : 2.4.

## La racine EST le mod
Le dossier racine s'installe tel quel dans `mods/xocean`. À la racine : uniquement des fichiers du mod. **Jamais** de `tests/`, de mod annexe ni de mod de test : tout l'outillage Claude vit dans `.claude/` (ignoré par Luanti).

## Arborescence
```
mod.conf            depends = default · optional_depends = mobs
init.lua            table globale `xocean` (S, modpath, log, dofile, has.mobs, custom_spawn), puis chargement
craftitems.lua      varech séché, sushi, poisson tropical (groupe eatable)
nodes/init.lua      charge coral, misc, ocean_stone, plants
nodes/coral.lua     register_coral : bloc, squelette, corail enraciné, squelette enraciné (×5 espèces)
nodes/plants.lua    herbier, cornichon de mer (plantlike_rooted sur sable) ; surcharge default:sand_with_kelp
nodes/ocean_stone.lua  pierre, pavé, taillée, circulaire, pilier, brique
nodes/misc.lua      lanterne marine (lumière 14), bloc de varech séché
mobs/init.lua       ne charge dolphin.lua et fish.lua que si xocean.has.mobs (Mobs Redo)
crafts.lua          recettes (dont bucket:bucket_water : mod bucket non déclaré dans mod.conf)
mapgen.lua          minerai de pierre océanique, schémas de récifs (schems/*.mts), plantes de corail, herbier, cornichon
spawn_example.lua   modèle de spawn.lua (non chargé)
schems/             récifs .mts (sunken*.mts non utilisés)
models/ sounds/ textures/ locale/ (template.txt, xocean.ru.tr)
```

## Règles
- **Une seule globale écrite** : `xocean`. Le code utilise l'alias historique `minetest.*` : le garder cohérent dans un même fichier ; `core.*` est accepté dans le code neuf.
- Noms : `xocean:<objet>`, textures `xocean_<objet>.png` (celles des mobs : `mobs_*.png`).
- Chaînes affichées au joueur dans `S()` (= `xocean.S`), présentes dans `locale/template.txt` et `xocean.ru.tr`.
- **Nœuds de Minetest Game surchargés** (avec `override_item` s'ils existent) : `default:coral_pink` (corail cerveau enraciné), `default:coral_cyan` (tube enraciné), `default:coral_brown` (bloc de corail corne), `default:coral_orange` (bloc de corail feu), `default:sand_with_kelp` (varech). Toute modification touche aussi les mondes existants.
- **Mobs Redo est optionnel** : tout appel à `mobs:` doit rester derrière `xocean.has.mobs` (vérifie `mobs.mod == "redo"`). Le mod doit charger et générer sans lui.
- **Spawn personnalisé** : si un fichier `spawn.lua` existe à la racine, `xocean.custom_spawn = true`, les `mobs:spawn_specific` par défaut sont sautés et `spawn.lua` est exécuté à la fin (modèle : `spawn_example.lua`).
- **Mapgen** : décorations limitées aux biomes océaniques de MTG listés dans `register_decoration` (7 biomes tempérés ou froids ; pas `desert_ocean`, `savanna_ocean`, `rainforest_ocean`), `force_placement`, `place_offset_y = -1` (la plante remplace le bloc support). Les noms de décorations doivent être **uniques** (doublon actuel : `xocean:tube_plant`).
- **Poissons** (`mobs/fish.lua`) : `stepheight = 0` et `do_custom = keep_in_water` (ils ne quittent pas leur eau, voir `shore_test.sh`). Ne pas les retirer : sans eux, Mobs Redo laisse les poissons sortir par la surface ou sur la plage, où ils meurent en une seconde.
- Plantes enracinées (`plantlike_rooted`) : posées seulement sur leur support avec de l'eau source au-dessus (`on_place`), elles rendent leur support quand on les détruit (`after_destruct`).

## Tests
Voir le skill `luanti-test-debug` (lint, chargement avec et sans mobs, génération d'un océan, monde de dev).
