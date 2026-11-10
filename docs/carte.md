# Carte de fresque

## But et place
Tableau blanc collaboratif : serveur Go (hub trame, éléments de tableau, fichier de tableau) et client Flutter
(outils de dessin, stylet, hors ligne, export). Dépend de **trame** (`v0.5.0`).
Dépendants : **server** (`go.mod`, `v0.1.1`) et **app** (`pubspec.yaml`, ref `v0.6.0`, uniquement `features/office/`).

## Arborescence
- `.` : paquet Go `fresque` ; `fresque.go` le hub, `board.go` le tableau et ses éléments.
- `dart/lib/` : client Flutter ; `src/` session, contrôleur, vue du tableau, rendu, formes, images, export PDF.
- `dart/test/` : tests Dart (`dart/test/fakes.dart` : faux de session) ; `dart/build/` : sortie de build, hors git.

## Où est X ?
- Session Dart : `dart/lib/src/session.dart` (s'appuie sur celle de trame)
- Hub Go : `fresque.go` ; tableau : `board.go`
- Présence (curseurs, sélections) : `dart/lib/src/session.dart`, `dart/lib/src/controller.dart`
- Brouillon hors ligne : `dart/lib/src/session.dart` (`DocDrafts` de trame)
- Format sur le fil : `README.md` § Protocol (champs `c`, `sw`, `f`, `d`, `tx`, `fs`, `src`), `dart/lib/src/element.dart`
- Format de fichier : `README.md` § File format, `board.go`, `dart/lib/src/board.dart`
- Éléments, formes, géométrie : `dart/lib/src/element.dart`, `dart/lib/src/shapes.dart`, `dart/lib/src/geometry.dart`
- Vue, rendu, export : `dart/lib/src/board_view.dart`, `dart/lib/src/render.dart`, `dart/lib/src/pdf.dart`
- Presse-papiers, images : `dart/lib/src/clipboard.dart`, `dart/lib/src/images.dart`
- Versions : tags `vX.Y.Z` ; `dart/pubspec.yaml` (`version:`, 0.8.0)
- Changelog : `CHANGELOG.md` et `dart/CHANGELOG.md`
- Épinglage de trame : `go.mod`, `dart/pubspec.yaml` (`ref: v0.5.0`) ; de fresque : `server/go.mod`, `app/pubspec.yaml`

## Construire et tester vite
Go (`GOWORK=off`) :
- vet : `GOWORK=off go vet ./...` (~1 s)
- un test : `GOWORK=off go test -run Board .` (1 s, `ok`)
Dart (via nix-shell, `flutter test`, pas `dart test`) :
- analyse : `cd dart && TMPDIR=/data/tmp nix-shell ../../app/shell.nix --run 'flutter analyze'` (23 s, `No issues found!`)
- un fichier : `cd dart && TMPDIR=/data/tmp nix-shell ../../app/shell.nix --run 'flutter test test/geometry_test.dart'`
  mesuré : 35 s au total (nix-shell compris, 1 s de test), `+4: All tests passed!`
Contre un trame local : `dart/pubspec_overrides.yaml` non suivi (`dependency_overrides`).

## Publier
Lecture seule, rien n'est poussé sans l'humain. 1. Si trame change, son tag dans `go.mod` et `dart/pubspec.yaml`.
2. Entrée en tête de `CHANGELOG.md` et `dart/CHANGELOG.md`. 3. `version:` de `dart/pubspec.yaml`.
4. Commit puis `git tag vX.Y.Z`. 5. Server (`go.mod`) et app (`pubspec.yaml`) changent ensuite leur version.

## Renvois
`README.md` (fonctions, protocole, format de fichier, développement), `dart/README.md`, `CHANGELOG.md`.
