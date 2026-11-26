---
name: luanti-test-debug
description: Teste et débogue le mod xocean dans le vrai moteur Luanti 5.18 en headless - lint (luacheck ou fallback LuaJIT, doublons de décorations, traductions), test de chargement et de contenu (textures, recettes, drops, entités, avec et sans Mobs Redo), test de génération d'un océan (coraux, herbiers, plantes enracinées, mobs vivants dans l'eau), monde de dev pour le test en jeu, lecture du log. À utiliser après toute modification ou quand quelque chose plante.
---

# Tester xocean

On teste dans le **vrai moteur** (Luanti 5.18 en headless), comme pour paleocave et cavepatate : jamais de faux `core` réécrit à la main.
Ne rien installer ni télécharger (Luanti, luacheck, Mobs Redo…) sans accord explicite.

Scripts dans `.claude/skills/luanti-test-debug/scripts/`, utilisables depuis n'importe quel dossier :

| But | Commande | Durée |
|---|---|---|
| Lint, doublons de décorations, traductions | `lint.sh [fichiers.lua...]` | 1 s |
| Chargement + contenu, sans puis avec Mobs Redo | `[ONLY=minimal\|full] load_test.sh [secondes]` | ~15 s |
| Génération d'un océan + mobs | `[SEED=42] [HALF=48] [POS=x,z] [NO_MOBS=1] smoke_test.sh` | ~30 s à 1 min 30 |
| Survie des mobs au bord de l'eau | `[DURATION=60] [PER_TYPE=4] shore_test.sh` | ~1 min 15 |
| Monde de dev pour le test en jeu | `dev_world.sh [--new] [--launch]` | |

`lib.sh` regroupe le code commun (binaire Luanti, mods disponibles, monde temporaire, analyse du log). Les mondes de test sont dans `$TMPDIR/xocean_*`, jamais dans le projet. Les mods d'aide (`xocean_check`, `xocean_smoke`) sont écrits dans ces mondes temporaires : **jamais de mod de test dans le dépôt**.

## Environnement
- Luanti 5.18.0 : `~/Downloads/luanti.app/Contents/MacOS/luanti`, trouvé automatiquement (`LUANTI_BIN` pour en changer).
- Données utilisateur : `~/Library/Application Support/minetest/` (jeu `minetest_game` = gameid `minetest`, `mods/` vide, `worlds/`).
- Dépendance obligatoire : `default` (Minetest Game). Dépendance optionnelle : `mobs` (Mobs Redo), fournie par le clone local `~/Documents/Awards/.audit_src/mobs` (version 20261114), déclaré par son chemin dans `.claude/test_mods.txt`. Une entrée contenant `/` est un chemin lié dans le monde de test, sans installation. Une entrée sans `/` est un nom de mod installé dans `<données>/mods/`. `EXTRA_WORLDMODS=chemin1:chemin2` ajoute des chemins à la volée.
- LuaJIT 2.0.5 sur la machine (le moteur embarque LuaJIT 2.1), luacheck absent, Python 3.14 sans PIL, perl 5.34.

## 1. Lint (`lint.sh`, toujours)
luacheck avec `scripts/luacheckrc` s'il est installé. Sinon LuaJIT vérifie la syntaxe et repère dans le bytecode les globales **écrites** (oubli de `local` : seule `xocean` est permise) et **lues** inconnues. Une nouvelle globale légitime s'ajoute à `READ_OK` dans `lint.sh` **et** à `luacheckrc`.
Puis, sans argument (non bloquant) :
- **sons** : chaque `sounds/*.ogg` doit être en Ogg Vorbis (le seul format lu par Luanti) et **mono** (un son stéréo n'est pas spatialisé : il s'entend au même volume à toute distance, ce qui rendait l'ancien cri du dauphin insupportable) ;
- **décorations au nom en double**, invisibles en jeu : `core.registered_decorations` est indexé par nom et `core.get_decoration_id` n'en retrouve qu'une. Actuellement : `xocean:tube_plant`, deux fois dans `mapgen.lua` ;
- **traductions** : chaînes `S("…")` absentes de `locale/template.txt` ou d'un `.tr`, entrées inutiles, entrées non traduites.

## 2. Chargement et contenu (`load_test.sh`)
Serveur headless (mapgen v7, écoute sur 127.0.0.1 seulement), arrêt après quelques secondes, analyse du log. Un mod d'aide vérifie dans `register_on_mods_loaded` :
- textures de tous les objets `xocean:*` et des textures `xocean_*` posées sur des nœuds d'autres mods (le mod retexture `default:coral_*` et `default:sand_with_kelp`), cherchées dans les `textures/` de tous les mods ;
- modèles `.b3d`, textures et sons des entités (fichier `nom.ogg` ou `nom.N.ogg`, gain et pitch positifs), drops, ingrédients des recettes qui produisent ou utilisent un objet xocean, groupes de recettes non vides, nœuds des décorations et `place_on` ;
- **remarque** quand un objet d'un mod absent de `depends`/`optional_depends` est utilisé. Actuellement : `bucket:bucket_water` dans la recette de la lanterne marine (le mod `bucket` n'est pas déclaré) ;
- avec Mobs Redo : `xocean:dolphin`, `xocean:fish`, `fish2`, `fish3`, `fish4` et leurs œufs enregistrés. Sans : aucune entité xocean.

**Deux passes** : SANS dépendance optionnelle (toujours, c'est là que cassent les `if mobs then`), puis AVEC si `test_mods.txt` la fournit. `ONLY=minimal|full` pour une seule. Codes : 0 OK, 1 erreur / avertissement du mod / `PROBLÈME`, 2 impossible de lancer. Sans joueur, aucun chunk n'est généré : voir le test suivant.

## 3. Génération (`smoke_test.sh`)
Monde temporaire, mapgen v7, graine fixe (`SEED`). Le mod d'aide :
1. cherche un **océan d'un biome visé par les décorations du mod** (point refusé par `core.get_spawn_level`, biome au centre et aux 4 coins dans la liste `biomes` des décorations), et passe au candidat suivant si moins de `OCEAN_MIN` % (60) des colonnes ont de l'eau en surface. `POS=x,z` impose la zone. **Attention** : les océans chauds de MTG (`desert_ocean`, `savanna_ocean`, `rainforest_ocean`) ne sont pas dans cette liste, donc aucun corail xocean n'y pousse ;
2. génère ±`HALF` nœuds de y=-60 à y=8 (`core.emerge_area`) et compte par **gennotify** combien de fois chaque décoration a été posée (sur tous les mapchunks générés, plus larges que la zone) ;
3. dans la zone : nœuds xocean et coraux, **plantes enracinées** (`plantlike_rooted`) dont le dessus n'est pas de l'eau, **blocs de corail flottants** (eau ou air dessous), pierre océanique (minerai) ;
4. avec Mobs Redo : charge de force 3×3×3 blocs d'eau (`max_forceloaded_blocks = 64`, `remove_far_mobs = false` dans la config de test, sinon Mobs Redo supprime tout mob qui sort de la zone chargée), fait apparaître le dauphin et les 4 poissons, vérifie toutes les 0,5 s pendant `MOB_WAIT` s (8) qu'ils sont dans l'eau, puis qu'ils sont vivants. `sorti_de_la_zone_chargée` n'est pas un défaut.

Échec si : erreur, plante enracinée **à l'air libre**, aucun contenu xocean, créature morte ou plus d'1 s hors de l'eau, pas d'océan trouvé, test inachevé avant `SMOKE_TIMEOUT` (300 s).
Avertissements (non bloquants) : plantes **enfouies** sous un bloc, décorations jamais posées, coraux flottants, pas de pierre océanique.

Référence (SEED=42, ±48, en (400,600) `deciduous_forest_ocean`, 98 % d'océan, résultats identiques d'un lancement à l'autre) :

| Config | contenu | enracinées | à l'air | enfouies | coraux flottants | pierre océanique | décorations |
|---|---|---|---|---|---|---|---|
| avec Mobs Redo (défaut) | 766 | 201 | 0 | 52 | 79 | 310 | 22/23 |
| `NO_MOBS=1` | 585 | 122 | 0 | 17 | 48 | 310 | 22/23 |

Les chiffres changent avec la liste des mods chargés : l'ordre de chargement, et donc le rang d'enregistrement des décorations dont Luanti dérive leurs graines, n'est plus le même (Mobs Redo n'enregistre aucune décoration). Comparer seulement à configuration égale.
`enfouies` : coraux enracinés posés sur les blocs des récifs, puis recouverts par un autre bloc du schéma. `xocean:tube3` n'est jamais posé (`scale = 0.000001`). 5 mobs vivants. Ce sont des défauts du mod tel qu'il est, pas des erreurs du test : comparer à ces chiffres après une modification de `mapgen.lua`.

## 4. Bord de l'eau (`shore_test.sh`, après toute modification des mobs)
Monde vide (singlenode). Le mod d'aide construit un bassin de 4 de profondeur, bordé d'une plage en pente (3, 2, 1 de profondeur puis du sable à y=0) et de murs. Il fait apparaître `PER_TYPE` exemplaires de chaque poisson près de la plage et sous la surface, plus 2 dauphins, et observe pendant `DURATION` s : sorties par la surface ou sur la plage, temps hors de l'eau, morts (avec l'endroit et le nœud), **distance parcourue**. Un poisson qui ne meurt plus doit encore nager. Mobs Redo est obligatoire (code 2 sinon). Échec si un mob meurt. L'IA est aléatoire : les chiffres varient d'un lancement à l'autre.

Cause du bug corrigé le 26/11/2026 dans `mobs/fish.lua` :
- Mobs Redo n'arrête jamais un mob nageur au bord de son eau : `is_at_cliff` est désactivé pour `fly`, et la vitesse verticale est conservée ;
- il ne le ramène dans l'eau qu'une fois par seconde, et applique `air_damage` une fois par seconde aussi ;
- les poissons avaient `stepheight` 1,1 par défaut (ils escaladaient la plage), 5 PV et `air_damage = 8` (une seconde dehors suffit à les tuer).

Correctif : `stepheight = 0` et un `do_custom` (`keep_in_water`) qui, à chaque pas, coupe la montée avant la surface et fait demi-tour avant le rivage.

Mesures (120 s, 24 poissons) : avant, 16 morts et 15 à 33 nœuds parcourus en moyenne ; après, 0 mort, aucune sortie de l'eau, 147 à 160 nœuds parcourus.

## 5. En jeu (`dev_world.sh`, puis l'utilisateur joue)
Lie le mod dans `<données>/mods/xocean` (le code est lu en direct) et crée le monde créatif `xocean_dev` avec les mods de `test_mods.txt` (Mobs Redo lié dans `worldmods/`). `--new` le recrée : **obligatoire après une modification de `mapgen.lua`**, les chunks déjà générés ne changent plus. `--launch` ouvre une fenêtre Luanti : seulement si l'utilisateur le demande. Aucun autre monde n'est touché.

Checklist à proposer : `/grantme all`, puis `/teleport 400 5 600` (océan de référence pour la graine 42 ; sinon chercher un océan tempéré ou froid) :
- récifs : blocs de corail cerveau / tube / bulle / corne / feu, squelettes, coraux enracinés qui ondulent ; pas de bloc qui flotte nettement au-dessus du sable ;
- herbiers, cornichons de mer lumineux (lumière 3), varech ;
- pierre océanique dans le sable peu profond ; recettes (pierre taillée, circulaire, briques, piliers, lanterne marine, bloc de varech, sushi) dans le guide de craft ;
- poser : herbier / cornichon sur du sable **sous l'eau** seulement, varech (4 à 6 de haut) sur du sable avec assez d'eau, corail enraciné sur son bloc avec de l'eau au-dessus ; creuser un corail enraciné rend son bloc ;
- mobs : œufs du dauphin et des 4 poissons dans l'inventaire créatif ; ils nagent, restent dans l'eau, y compris près d'une plage ou contre un mur, et font demi-tour au bord sans saccade visible ; posés hors de l'eau, ils meurent (`air_damage`) ; le dauphin donne de la viande ;
- cri du dauphin (refait le 26/11/2026 : sifflements doux synthétisés, mono, sources dans `.claude/sounds_src/` ; `gain = 0.4`, `pitch = 0.7`, audible à 24 nœuds au lieu de 700) : doux, plus fort de près et plus faible en s'éloignant, inaudible depuis l'autre bout de l'océan ; il est rare (1 chance sur 100 par seconde et par dauphin), on peut en faire apparaître plusieurs avec l'œuf pour l'entendre plus vite ;
- textures : aucun damier (texture manquante), noms traduits (le mod n'a qu'une traduction russe).

Après la session : `grep -n "ERROR\|xocean" ~/Library/Application\ Support/minetest/debug.txt | tail -50`.

## Lire une erreur
`Runtime error from mod 'x'` donne le mod, et la pile `stack traceback` donne `fichier:ligne`. Remonter jusqu'au premier fichier de xocean. Une erreur dans un `on_place`, un `after_destruct` ou un mob n'apparaît qu'en jeu ; une erreur de décoration ou de schéma qu'à la génération (`smoke_test.sh`).

## Compte rendu
Dire exactement ce qui a tourné (lint ? chargement sans / avec mobs ? génération ? en jeu ?) en recopiant les vraies sorties et les chiffres du bilan comparés à la référence, avec quels mods, et ce qui reste à tester en jeu.
