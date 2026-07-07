-- Exécuté par le gestionnaire de mods à chaque activation (voir
-- core_modmanager.lua : activateMod()). Nécessaire car monter le zip du
-- mod dans le système de fichiers virtuel ne recharge PAS automatiquement
-- les extensions Lua tant que le jeu tourne déjà (seul un redémarrage
-- complet du jeu déclencherait le scan initial des extensions) ; sans cet
-- appel explicite, l'extension GE de Beam-RemotePlus ne serait jamais
-- chargée après une (dés)activation via le gestionnaire de mods.
--
-- extensions.reload() (et non extensions.load()) est indispensable : load()
-- est un no-op si le module est déjà en mémoire (ex: mise à jour du mod
-- pendant que le jeu tourne encore depuis une session précédente), et
-- laisserait tourner l'ancien code au lieu de relire le fichier sur disque.
log('I', 'beamRemotePlus.modScript', 'reloading extensions.beamRemotePlus_main from disk')
if extensions.reload then
  extensions.reload('beamRemotePlus_main')
else
  extensions.load('beamRemotePlus_main')
end
