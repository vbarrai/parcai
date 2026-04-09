# Ce que parcai peut emprunter a hazmat

Analyse comparative de [dredozubov/hazmat](https://github.com/dredozubov/hazmat) pour identifier les fonctionnalites, techniques et patterns transposables a parcai.

---

## Table des matieres

1. [Blocklist DNS/domaines integree](#1-blocklist-dnsdomaines-integree)
2. [Blocklist de ports (pf firewall)](#2-blocklist-de-ports-pf-firewall)
3. [Commande `explain` (contrat de session)](#3-commande-explain-contrat-de-session)
4. [Support du clipboard dans le sandbox](#4-support-du-clipboard-dans-le-sandbox)
5. [Execution depuis /tmp (langages compiles)](#5-execution-depuis-tmp-langages-compiles)
6. [Metadata ancestors pour git](#6-metadata-ancestors-pour-git)
7. [Generation dynamique du profil SBPL](#7-generation-dynamique-du-profil-sbpl)
8. [Systeme d'integrations par manifests](#8-systeme-dintegrations-par-manifests)
9. [Safe-list pour les variables d'environnement](#9-safe-list-pour-les-variables-denvironnement)
10. [Snapshots pre-session](#10-snapshots-pre-session)
11. [Appel direct a sandbox_init()](#11-appel-direct-a-sandbox_init)
12. [Runner pattern (verbose/dry-run)](#12-runner-pattern-verbosedry-run)
13. [Support multi-agent](#13-support-multi-agent)
14. [Matrice de priorisation](#14-matrice-de-priorisation)

---

## 1. Blocklist DNS/domaines integree

### Ce que fait hazmat

hazmat bloque ~40 domaines connus d'exfiltration via `/etc/hosts` (mapping vers `0.0.0.0`). Categories :

| Categorie | Domaines |
|-----------|----------|
| **Tunnels** (21) | `ngrok.io`, `ngrok.com`, `ngrok-free.app`, `tunnel.cloudflare.com`, `trycloudflare.com`, `serveo.net`, `localtunnel.me`, `localhost.run`, `localxpose.io`, `pagekite.me`, `bore.digital`, `localtonet.com`, `zrok.io`, `devtunnels.ms`, `loca.lt`, `tunnelmole.com`, `playit.gg`, `pinggy.io`, `lokal.so`, `telebit.cloud`, `loophole.cloud` |
| **Paste** (8) | `pastebin.com`, `paste.ee`, `ghostbin.com`, `hastebin.com`, `dpaste.org`, `justpaste.it`, `rentry.co`, `ix.io` |
| **File sharing** (5) | `transfer.sh`, `file.io`, `gofile.io`, `catbox.moe`, `filebin.net` |
| **Webhook capture** (5) | `webhook.site`, `requestbin.com`, `pipedream.com`, `hookbin.com`, `beeceptor.com` |
| **Supply-chain C2** (1) | `sfrclak.com` (compromission axios 2026) |

### Ce que parcai fait aujourd'hui

parcai a deja `--blocked-domains` et `--allowed-domains` dans le proxy MITM, mais aucune liste par defaut. L'utilisateur doit tout configurer manuellement.

### Comment l'integrer

**Avantage parcai : le proxy MITM est superieur a `/etc/hosts`** car il voit le hostname complet dans les requetes CONNECT, donc il bloque aussi les sous-domaines (`sub.ngrok.io`), ce que `/etc/hosts` ne fait pas.

- Ajouter une blocklist par defaut dans le proxy, activee automatiquement quand `--secrets` est actif
- Rendre la liste configurable via `.parcai.json` (`"default_blocklist": true/false`)
- Permettre d'etendre la liste via `"extra_blocked_domains": [...]`
- Stocker la liste dans un fichier separe (`blocklist/exfiltration.txt`) pour faciliter les mises a jour

**Effort : faible** -- la mecanique de filtrage existe deja dans le proxy, il suffit d'ajouter la liste par defaut.

---

## 2. Blocklist de ports (pf firewall)

### Ce que fait hazmat

Regles `pf` scopees a l'utilisateur `agent` bloquant les protocoles d'exfiltration non-HTTP :

| Port(s) | Protocole | Risque |
|----------|-----------|--------|
| 25, 465, 587 | SMTP | Envoi d'emails avec secrets |
| 6660-6669, 6697 | IRC | Canal C2 |
| 20, 21 | FTP | Upload de fichiers |
| 23 | Telnet | Acces distant non chiffre |
| 445 | SMB | Partage reseau |
| 3389 | RDP | Bureau distant |
| 5900, 5901 | VNC | Controle distant |
| 9050, 9150 | Tor SOCKS | Trafic anonymise |
| 1080 | SOCKS | Proxy generique |
| 1194, 1723, 4500 | VPN | Tunnel VPN |
| 5222, 5269 | XMPP | Messagerie |
| ICMP | Ping | Tunnel ICMP |

### Ce que parcai fait aujourd'hui

parcai utilise `(deny network*)` ou `(allow network*)` dans sandbox-exec -- c'est tout ou rien. Quand le reseau est actif (mode par defaut), tous les ports sont ouverts.

### Comment l'integrer

Deux approches possibles :

**Option A -- Via le proxy MITM (recommande)** : Quand `--secrets` est actif, tout le trafic passe par le proxy. Le proxy peut rejeter les connexions CONNECT vers des ports non-standard. Ajouter une allowlist de ports (`80, 443, 8080, 8443`) et rejeter le reste.

**Option B -- Via sandbox-exec** : Remplacer `(allow network*)` par des regles plus fines :
```scheme
(allow network-outbound (remote tcp "*:80"))
(allow network-outbound (remote tcp "*:443"))
(allow network-outbound (remote tcp "*:8080"))
(allow network-outbound (remote tcp "*:8443"))
(allow network-outbound (local tcp "*:*"))  ;; loopback pour le proxy
```

L'option A est plus simple et deja dans le chemin d'execution existant. L'option B fonctionne meme sans `--secrets`.

**Effort : faible a moyen** selon l'option choisie.

---

## 3. Commande `explain` (contrat de session)

### Ce que fait hazmat

`hazmat explain` affiche un resume complet de ce que la session va faire **avant** de la lancer :

```
hazmat: session
  Mode:                 Native containment
  Why this mode:        using native containment because no Docker requirement was detected
  Project (read-write): /Users/dr/workspace/myproject
  Integrations:         go
  Host changes:         project ACL repair, git safe.directory trust
  Auto read-only:       /Users/dr/go/pkg/mod
  Pre-session snapshot: on
  Snapshot excludes:    vendor/
  Env passthrough:      GOPROXY
  Warnings:
    - Go module cache is shared read-only...
```

Supporte aussi `--json` pour l'integration CI/automation.

### Ce que parcai fait aujourd'hui

parcai a `--dry-run` qui affiche le profil sandbox et le chemin du clone, mais pas de vue synthetique "voici ce qui va se passer". Le verbose affiche des details techniques, pas un contrat lisible.

### Comment l'integrer

Ajouter une commande `parcai explain` (ou enrichir `--dry-run`) qui affiche :

```
parcai: session contract
  Project:           myproject
  Clone:             /tmp/parcai-clone-xxx
  Network:           allowed
  Secrets masking:   active (.env, .env.local)
  Blocked domains:   40 default + 2 custom
  Read-only access:  /opt/homebrew (system)
  Read-write access: clone only
  Denied paths:      ~/.ssh, ~/.aws, ... (28 paths)
  Custom allows:     /usr/local/share/fonts
  Custom denies:     ~/other-project
  Env overrides:     NODE_ENV=test
  On exit:           ask
```

**Effort : faible** -- les donnees sont deja disponibles dans les variables globales, il suffit de les formater.

---

## 4. Support du clipboard dans le sandbox

### Ce que fait hazmat

Regles SBPL explicites pour le clipboard :

```scheme
(allow mach-lookup (global-name "com.apple.pboard"))
(allow ipc-posix-shm-read-data (ipc-posix-name-regex #"^com\\.apple\\.pasteboard\\."))
(allow ipc-posix-shm-write-data (ipc-posix-name-regex #"^com\\.apple\\.pasteboard\\."))
```

### Ce que parcai fait aujourd'hui

parcai autorise `(allow mach-lookup)` globalement (toutes les services Mach). Le clipboard fonctionne implicitement mais la regle est trop large.

### Comment l'integrer

Si parcai restreint `mach-lookup` a l'avenir (ce qui serait une amelioration securitaire), il faudra explicitement autoriser le clipboard. Pour l'instant, **noter comme dette technique** : le `(allow mach-lookup)` global est un point de durcissement futur.

**Effort : nul maintenant, faible quand mach-lookup sera restreint.**

---

## 5. Execution depuis /tmp (langages compiles)

### Ce que fait hazmat

```scheme
(allow process-exec (subpath "/private/tmp"))
```

Les compilateurs (gcc, rustc, go) ecrivent des binaires temporaires dans `/tmp` puis les executent. Sans cette regle, la compilation echoue.

### Ce que parcai fait aujourd'hui

parcai autorise `file-write*` sur `/tmp` mais PAS `process-exec`. Un agent qui compile du Go, Rust ou C dans le sandbox echouera a l'execution du binaire.

### Comment l'integrer

Ajouter dans `profiles/macos.sb.tpl` :

```scheme
(allow process-exec (subpath "/private/tmp"))
```

**Effort : trivial** -- une ligne dans le template.

**Risque** : un agent pourrait ecrire un binaire malveillant dans `/tmp` et l'executer. Acceptable car le sandbox restreint tout ce que le binaire peut faire (filesystem, reseau, process).

---

## 6. Metadata ancestors pour git

### Ce que fait hazmat

Pour chaque repertoire expose (read ou write), hazmat ajoute des regles `file-read-metadata` (stat seul, pas le contenu) pour chaque repertoire ancetre :

```scheme
;; Si le projet est /Users/dr/workspace/myproject :
(allow file-read-metadata (literal "/Users"))
(allow file-read-metadata (literal "/Users/dr"))
(allow file-read-metadata (literal "/Users/dr/workspace"))
```

**Pourquoi** : `git` fait de la canonicalisation de chemins (`realpath`) et a besoin de `stat()` sur les repertoires parents. Sans ca, certaines operations git echouent silencieusement.

### Ce que parcai fait aujourd'hui

parcai autorise `(allow file-read* (subpath "{{HOME}}"))` globalement, donc le probleme ne se pose pas. Mais c'est une regle trop large.

### Comment l'integrer

Si parcai restreint le `file-read*` sur `$HOME` (durcissement recommande), il faudra ajouter les regles metadata ancestors. Pattern :

```bash
path="$CLONE_DIR"
while [ "$path" != "/" ]; do
  path=$(dirname "$path")
  echo "(allow file-read-metadata (literal \"$path\"))"
done
```

**Effort : faible** -- utile quand le profil sera durci.

---

## 7. Generation dynamique du profil SBPL

### Ce que fait hazmat

Au lieu d'un template statique avec substitution de placeholders, hazmat genere le profil SBPL **programmatiquement** en Go. Chaque session a un profil unique calcule a partir de :
- Le repertoire projet
- Les integrations actives (read dirs, write dirs)
- Les extensions CLI (`-R`, `-W`)
- La resolution Homebrew
- Les regles de credential deny

Le code utilise un pattern "last-match-wins" : il ecrit les regles read d'abord, puis les regles write (qui reaffirment l'acces), puis les deny credentials en dernier (qui l'emportent sur tout).

### Ce que parcai fait aujourd'hui

Template statique (`profiles/macos.sb.tpl`) avec 5 placeholders : `{{CLONE}}`, `{{HOME}}`, `{{NETWORK_POLICY}}`, `{{PROXY_LOOPBACK_RULE}}`, `{{CLAUDE_EXEC_RULE}}`. Les regles custom (`--allow`, `--rw`, `--deny`) sont injectees par concatenation dans `generate_profile()`.

### Comment l'integrer

Deux niveaux :

**Niveau 1 (pragmatique)** : Garder le template mais enrichir la substitution. Ajouter des placeholders pour les read dirs, write dirs, et les regles d'integration auto-detectees. `generate_profile()` devient plus intelligent sans changer d'architecture.

**Niveau 2 (refonte)** : Passer a une generation programmatique complete. Necessiterait de reecrire la logique de profil en bash (faisable mais verbeux) ou de migrer vers un langage plus structure.

**Recommandation** : niveau 1 pour maintenant, niveau 2 si parcai depasse ~100 regles dynamiques.

**Effort : moyen (niveau 1) / eleve (niveau 2).**

---

## 8. Systeme d'integrations par manifests

### Ce que fait hazmat

Manifests YAML embarques dans le binaire, un par toolchain :

```yaml
# integrations/go.yaml
integration:
  name: go
  version: 1
  description: Go project defaults

detect:
  files: [go.mod]

session:
  read_dirs:
    - ~/go/pkg/mod
  env_passthrough:
    - GOPATH
    - GOPROXY

backup:
  excludes:
    - vendor/

warnings:
  - "Go module cache is shared read-only"
```

**13 integrations built-in** : go, node, rust, python-poetry, python-uv, ruby-bundler, java-gradle, java-maven, haskell-cabal, elixir-mix, opentofu-plan, terraform-plan, tla-java.

**Auto-detection** : si `go.mod` existe dans le projet -> integration go activee automatiquement.

**Securite** : chaque `read_dir` est valide contre une liste de credential deny paths. Si un manifest essaie d'exposer `~/.ssh`, il est rejete.

### Ce que parcai fait aujourd'hui

Aucun systeme d'integration. L'utilisateur doit configurer manuellement chaque `--allow` pour les caches de modules, les toolchains, etc.

### Comment l'integrer

Ajouter un systeme de detection dans `run_macos()` :

```bash
# Detection automatique
[ -f "$CWD/go.mod" ]      && auto_allow_read "$HOME/go/pkg/mod"
[ -f "$CWD/package.json" ] && auto_allow_read "$HOME/.npm/_cacache"
[ -f "$CWD/Cargo.toml" ]   && auto_allow_read "$HOME/.cargo/registry"
[ -f "$CWD/pyproject.toml" ] && auto_allow_read "$HOME/.cache/uv"
```

**Phase 1** : Detection inline dans le script bash (5-10 toolchains).
**Phase 2** : Fichiers de config externes (`integrations/*.json`) charges dynamiquement.

L'auto-detection ameliorerait significativement l'experience utilisateur -- plus besoin de savoir quels chemins autoriser pour chaque langage.

**Effort : faible (phase 1) / moyen (phase 2).**

---

## 9. Safe-list pour les variables d'environnement

### Ce que fait hazmat

Liste explicite de variables d'environnement "sures" autorisees en passthrough. Toutes les autres sont filtrees :

**Autorisees** : `GOPATH`, `GOROOT`, `GOPROXY`, `RUSTUP_HOME`, `CARGO_HOME`, `NVM_DIR`, `PYENV_ROOT`, `JAVA_HOME`, `GEM_HOME`, `MIX_HOME`, `HEX_HOME`, `CABAL_DIR`, `STACK_ROOT`, `NPM_CONFIG_REGISTRY`, `PIP_INDEX_URL`, etc.

**Explicitement exclues** (dangereuses) : `NODE_OPTIONS`, `PYTHONPATH`, `GOFLAGS`, `MAVEN_OPTS`, `CGO_CFLAGS`, `CGO_LDFLAGS`, `RUBYOPT`, `PERL5OPT`, `LD_PRELOAD`, `DYLD_*`.

**Pourquoi** : `NODE_OPTIONS=--require=/path/to/malicious.js` permet d'injecter du code dans tout processus Node. `LD_PRELOAD` permet d'intercepter n'importe quel appel systeme.

### Ce que parcai fait aujourd'hui

parcai injecte un `PATH` controle dans `.zshenv` et transmet les `env` overrides de `.parcai.json` sans filtrage. Les variables dangereuses de l'environnement host ne sont pas nettoyees.

### Comment l'integrer

Dans la generation du `.zshenv`, ajouter un `unset` explicite des variables dangereuses :

```bash
# Dans inject_env_into_shell_config()
for dangerous in NODE_OPTIONS PYTHONPATH LD_PRELOAD DYLD_INSERT_LIBRARIES \
                 DYLD_LIBRARY_PATH GOFLAGS MAVEN_OPTS CGO_CFLAGS CGO_LDFLAGS \
                 RUBYOPT PERL5OPT BASH_ENV ENV; do
  echo "unset $dangerous" >> "$file"
done
```

**Effort : trivial** -- quelques lignes dans le script.

**Impact securitaire : eleve** -- ferme un vecteur d'injection actuellement ouvert.

---

## 10. Snapshots pre-session

### Ce que fait hazmat

Avant chaque session, Kopia prend un snapshot incremental du projet. Politique de retention : 20 derniers, 7 quotidiens, 4 hebdomadaires. `hazmat restore --session=N` restaure N sessions en arriere (avec snapshot pre-restore pour pouvoir annuler).

### Ce que parcai fait aujourd'hui

parcai utilise des clones APFS (copy-on-write) -- l'original n'est jamais modifie pendant la session. Les changements sont appliques explicitement par l'utilisateur apres la session. Pas d'historique au-dela de la session courante.

### Comment l'integrer

L'architecture clone de parcai rend les snapshots moins critiques (l'original est protege). Mais un historique serait utile pour :
- Annuler un `--apply` accidentel
- Comparer l'etat du projet entre plusieurs sessions d'agent

**Approche legere (sans Kopia)** :

```bash
# Avant apply_changes()
snapshot_dir="$SESS_DIR/snapshots/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$snapshot_dir"
rsync -a --link-dest="$CWD" "$CWD/" "$snapshot_dir/"
```

Avec `--link-dest`, rsync utilise des hard links -- le snapshot ne consomme de l'espace que pour les fichiers modifies.

**Commande de restauration** : `parcai restore [--session=N]`

**Effort : moyen.**

---

## 11. Appel direct a sandbox_init()

### Ce que fait hazmat

`hazmat-launch` est un binaire CGO qui appelle `sandbox_init()` directement au lieu de passer par `sandbox-exec`. Avantages :
- **Signal forwarding correct** : le processus sandbox EST le processus cible (pas de wrapper)
- **PTY handling natif** : pas besoin de hacks pour le terminal interactif
- **Une couche de moins** : `sudo -> hazmat-launch -> target` au lieu de `sudo -> sandbox-exec -> target`

Validations de securite avant l'appel :
- Chemin du fichier policy restreint par regex
- Proprietaire du fichier verifie (doit etre l'invocateur, pas root)
- Mode du fichier verifie (0644 exact)
- Contenu verifie (doit contenir `(deny default)`)

### Ce que parcai fait aujourd'hui

parcai utilise `sandbox-exec -f profile.sb /bin/zsh -i`. Le TTY est gere via un hack : Claude est lance depuis `.zshrc` (pas `zsh -c`) pour preserver `setRawMode`.

### Comment l'integrer

Deux options :

**Option A -- Helper binaire minimal** : Un petit programme C (~50 lignes) qui :
1. Lit le fichier policy
2. Appelle `sandbox_init(policy, 0, &err)`
3. `exec()` le shell cible

```c
#include <sandbox.h>
#include <stdio.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    char *err = NULL;
    char *policy = read_file(argv[1]);  // policy path
    if (sandbox_init(policy, 0, &err) != 0) {
        fprintf(stderr, "sandbox_init: %s\n", err);
        return 1;
    }
    execvp(argv[2], &argv[2]);  // exec target
    return 1;
}
```

Compile avec : `cc -o parcai-sandbox main.c -Wno-deprecated-declarations`

**Option B -- Rester sur sandbox-exec** : Le hack `.zshrc` fonctionne. Le gain ne justifie peut-etre pas l'ajout d'un binaire compile a un projet qui est volontairement 100% script.

**Recommandation** : Option B pour maintenant. Option A si des problemes de signaux ou de PTY sont remontes.

**Effort : faible (option A) mais change la philosophie du projet.**

---

## 12. Runner pattern (verbose/dry-run)

### Ce que fait hazmat

Toutes les commandes systeme passent par une abstraction `Runner` qui :
- Affiche la commande avant execution en mode verbose
- Affiche une **raison** humaine pour chaque sudo (`"creating agent user for sandbox isolation"`)
- En dry-run, affiche ce qui serait fait sans rien executer
- Distingue les commandes normales, sudo, et sudo-as-agent

### Ce que parcai fait aujourd'hui

parcai a `--verbose` et `--dry-run` mais l'implementation est ad-hoc : des `if [ "$VERBOSE" = true ]` eparpilles dans le code.

### Comment l'integrer

Creer une fonction wrapper :

```bash
run() {
  local reason="$1"; shift
  if [ "$DRY_RUN" = true ]; then
    info "[dry-run] $reason: $*"
    return 0
  fi
  [ "$VERBOSE" = true ] && info "$reason: $*"
  "$@"
}

# Usage :
run "Creating APFS clone of project" cp -c -R "$src" "$dst"
run "Generating sandbox profile" generate_profile "$clone" "$home"
```

**Effort : faible** -- refactoring progressif, fonction par fonction.

---

## 13. Support multi-agent

### Ce que fait hazmat

Abstraction `harness` supportant Claude, Codex et OpenCode. Chaque agent a :
- Sa commande de lancement
- Son repertoire de config
- Ses fichiers de bootstrap
- Sa logique d'installation

### Ce que parcai fait aujourd'hui

parcai est cable sur Claude (lancement via `.zshrc`, persistence de `~/.claude/`). `--shell` permet un shell generique mais sans support specifique d'autres agents.

### Comment l'integrer

**Phase 1** : Ajouter `--agent codex|opencode` qui modifie :
- La commande lancee dans `.zshrc`
- Les chemins de config persistes
- Le binaire autorise dans le profil sandbox

**Phase 2** : Abstraction plus formelle si le nombre d'agents supporte augmente.

**Effort : moyen (phase 1).**

---

## 14. Matrice de priorisation

| # | Feature | Impact securite | Impact UX | Effort | Priorite |
|---|---------|----------------|-----------|--------|----------|
| 9 | **Safe-list env vars** | **Eleve** | Faible | Trivial | **P0** |
| 5 | **Exec depuis /tmp** | Faible | **Eleve** | Trivial | **P0** |
| 1 | **Blocklist domaines par defaut** | **Eleve** | Moyen | Faible | **P1** |
| 3 | **Commande `explain`** | Faible | **Eleve** | Faible | **P1** |
| 12 | **Runner pattern** | Faible | Moyen | Faible | **P1** |
| 8 | **Integrations auto-detectees** | Moyen | **Eleve** | Faible-Moyen | **P1** |
| 2 | **Blocklist de ports** | Moyen | Faible | Faible-Moyen | **P2** |
| 6 | **Metadata ancestors** | Faible | Faible | Faible | **P2** |
| 7 | **SBPL dynamique** | Moyen | Moyen | Moyen | **P2** |
| 13 | **Multi-agent** | Faible | Moyen | Moyen | **P2** |
| 10 | **Snapshots pre-session** | Faible | Moyen | Moyen | **P3** |
| 11 | **sandbox_init() direct** | Faible | Faible | Faible | **P3** |
| 4 | **Clipboard (mach-lookup)** | Faible | Faible | Nul | **P3** |

### Recommandation d'execution

**Sprint 1 (quick wins)** : items P0 + P1 haut -- safe-list env, exec /tmp, blocklist domaines, commande explain. ~1-2 jours de travail.

**Sprint 2 (hardening)** : integrations auto, runner pattern, blocklist ports. ~2-3 jours.

**Sprint 3 (evolution)** : multi-agent, SBPL dynamique, snapshots. ~1 semaine.
