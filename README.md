# BeamNG RemotePlus — mod

Mod BeamNG.drive qui étend le contrôle à distance intégré au jeu avec une
**télémétrie réelle**, des **pédales analogiques**, le **changement de
véhicule**, la **rotation caméra**, le **passage de rapports** et la
**récupération de véhicule**. C'est le mod compagnon de l'application Android
[Beam-RemotePlus-Mobile](https://github.com/LucienLassalle/Beam-RemotePlus-Mobile).

L'ensemble forme un **remplacement moderne de l'application officielle
[remotecontrol](https://github.com/BeamNG/remotecontrol) de BeamNG**, qui n'est
plus maintenue.

---

## Pourquoi ce mod

Le canal de contrôle à distance natif de BeamNG a deux limites de longue date :

1. son appel de télémétrie est cassé et n'envoie jamais aucune donnée à l'app ;
2. son périphérique virtuel n'a qu'**un seul axe** de direction et **deux
   boutons tout-ou-rien** — pas d'accélérateur ni de frein analogiques.

Ce mod corrige les deux, en **réutilisant le code de sécurité natif** de BeamNG
(`core_remoteController`) : aucune configuration supplémentaire côté jeu.

---

## Fonctionnalités

- **Télémétrie live** envoyée au téléphone : vitesse, régime, régime de rupteur,
  rapport engagé, niveau de carburant, températures eau **et huile**, et témoins
  (feux de route/croisement, frein à main, clignotants, témoin d'huile, ABS,
  **antipatinage / TC**, shift light).
- **Accélérateur et frein entièrement analogiques**, plus la direction, via un
  périphérique d'entrée virtuel à 3 axes.
- **Changement de véhicule** (précédent / suivant) depuis le téléphone.
- **Rotation de caméra** (précédente / suivante) depuis le téléphone.
- **Passage de rapports** (montée / descente) pour boîte manuelle.
- **Récupération de véhicule** (reset / désembourbage), reproduisant la touche
  « Inser » native : appui bref = petit repositionnement, appui long =
  rembobinage plus loin dans l'historique de positions.
- **Découverte automatique** : le mod répond aux sondes de l'app sur le réseau
  local en renvoyant l'adresse du PC et le code d'appairage — connexion sans QR
  code ni caméra.
- **Affichage du code d'appairage in-game** au démarrage (message toast +
  console), indispensable depuis que l'UI QR de BeamNG est cassée (0.39).
- **Activation automatique au démarrage** : une fois activé dans le gestionnaire
  de mods, le mod recharge son extension à chaque lancement du jeu (via
  `scripts/modScript.lua`), sans avoir à le désactiver/réactiver.

---

## Ce mod nécessite l'application compagnon

Le mod **n'a pas d'interface propre** et ne fait rien seul. Il fonctionne
uniquement avec l'app
[Beam-RemotePlus-Mobile](https://github.com/LucienLassalle/Beam-RemotePlus-Mobile),
qui s'y connecte via le réseau local. Installez les deux.

---

## Installation

1. Récupérez `Beam-RemotePlus.zip` :
   - depuis la [page Releases](https://github.com/LucienLassalle/Beam-RemotePlus-Mod/releases),
   - ou directement depuis `out/Beam-RemotePlus.zip` de ce dépôt (buildé et suivi
     par Git : toujours à jour).
2. Placez le `.zip` dans le dossier `mods/` de BeamNG.drive (ou glissez-le sur la
   fenêtre du jeu / le gestionnaire de mods).
3. Dans le **gestionnaire de mods**, activez **Beam-RemotePlus**. C'est la seule
   étape manuelle : ensuite le mod se relance tout seul à chaque démarrage.
4. Chargez un niveau avec un véhicule. Le mod écoute sur le port UDP **4446** et
   affiche le code d'appairage. Connectez-vous depuis l'app (connexion
   automatique recommandée).

---

## Utilisation depuis l'app

| Depuis l'app | Effet en jeu |
|---|---|
| Connexion automatique | Sonde `beamngremoteplus\|discover` (broadcast 4446) → le mod répond `hello\|<code>\|<nom PC>` sur 4447. |
| Volant / pédales | Axes analogiques du périphérique virtuel `BeamRemotePlus`. |
| Boutons de rapport | Impulsions boutons virtuels `shiftUp` / `shiftDown`. |
| Véhicule préc./suiv. | `core_input_vehicleSwitching.switchCycleVehicle`. |
| Caméra préc./suiv. | `core_camera.setVehicleCameraByIndexOffset`. |
| Récupération | `recovery.startRecovering()` / `stopRecovering()` sur le véhicule du joueur. |

Le périphérique virtuel apparaît dans **Options > Contrôles** ; ses associations
par défaut sont dans `src/settings/inputmaps/bngremoteplusv1.json` (passthrough
direct, sans courbe de réponse).

---

## Compatibilité BeamNG 0.39+

BeamNG 0.39 **n'a pas cassé le protocole** — le backend natif
`core_remoteController` et `getQRCode()` fonctionnent toujours (vérifié en 0.39.4).
Ce qui est cassé, c'est **l'UI in-game** « Remote Control » (Options > Contrôles >
Matériel) : le QR code ne se rend pas de façon fiable (race condition au rendu du
canvas côté jeu). Sans QR affichable, l'app ne pouvait plus s'appairer.

Ce mod contourne le problème :

- il **appelle `getQRCode()` au démarrage**, ce qui ouvre le socket natif (port
  4444) et génère le code même si l'utilisateur n'ouvre jamais le panneau Options ;
- il **affiche le code** en jeu (toast + console) ;
- il **répond à la découverte automatique** de l'app, qui n'a alors besoin ni du
  QR ni du code.

> **Note de sécurité :** la découverte renvoie le code d'appairage à quiconque
> envoie une sonde sur le réseau local. C'est équivalent en pratique au
> brute-force du code à 5 chiffres et acceptable sur un LAN domestique. À rendre
> optionnel si le mod est utilisé sur un réseau non fiable.

---

## Problème connu : l'app dit « installez le mod » alors qu'il est activé

BeamNG ne recharge pas toujours l'extension côté jeu juste après une
(ré)activation dans le gestionnaire de mods. **Contournement :** désactivez puis
réactivez le mod — cela force le rechargement de l'extension, et l'app le détecte
en quelques secondes. L'activation automatique au démarrage évite ce souci sur
les lancements suivants.

---

## Développement

```bash
bash scripts/build_mod.sh   # empaquette src/ -> out/, Package/, et déploie
                            # dans le dossier mods/ BeamNG local + trigger hot-reload
bash scripts/test_mod.sh    # tests unitaires du protocole (luajit requis)
```

Le hot-reload : `build_mod.sh` écrit le zip puis crée
`Beam-RemotePlus-reload.trigger` dans le dossier mods. Si le jeu tourne avec le
mod actif, l'extension détecte le trigger sous ~3 s, remonte le zip et se
recharge — sans passer par le gestionnaire de mods.

| Chemin | Rôle |
|---|---|
| `src/lua/ge/extensions/beamRemotePlus/main.lua` | Extension GE : sockets, handshake, contrôle, télémétrie, découverte. |
| `src/lua/ge/extensions/beamRemotePlus/protocol.lua` | Logique pure du protocole (testable sans BeamNG). |
| `src/scripts/modScript.lua` | Exécuté à l'activation / au démarrage : recharge l'extension. |
| `src/settings/inputmaps/bngremoteplusv1.json` | Associations par défaut du périphérique virtuel. |
| `test/protocol_test.lua` | Tests unitaires (format binaire, messages, découverte). |

Le format binaire (contrôle 12 octets, télémétrie 36 octets, little-endian) est
un **miroir exact** des classes Dart côté app.

---

## Signaler un problème

[Ouvrez une issue](https://github.com/LucienLassalle/Beam-RemotePlus-Mod/issues)
sur ce dépôt, en **français ou en anglais**.
