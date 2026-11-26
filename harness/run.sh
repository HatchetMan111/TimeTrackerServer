#!/usr/bin/env bash
# =============================================================================
#  🧪 TimeTracker-Proxmox – Mock-Harness
#  Testet install/timetracker.sh End-to-End gegen gemockte Proxmox-Umgebung:
#   - `unshare -rm` mappt den Harness-User auf root (EUID-Prüfung des Scripts)
#   - pct/pveam/wget/curl/sleep als Host-Mocks (Fakebin)
#   - Inner-Mocks: apt-get, systemctl, node/npm, git, python3, curl, getent …
#   - Inner-Script läuft ECHT (Pfade auf Mock-Root umgeschrieben): Basis-apt,
#     Node-Bootstrap, PostgreSQL-Init, App-Klon, venv/pip, npm build:docker,
#     .env, systemd-Unit, Health-Poll
#  Usage: bash harness/run.sh [-v]   (Exit 0 = alle Cases grün)
# =============================================================================
set -u
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install/timetracker.sh"
[[ -f "$SCRIPT" ]] || { echo "✘ Installer nicht gefunden: $SCRIPT"; exit 1; }

MK=$(mktemp -d /tmp/timetracker-harness.XXXXXX)
chmod 755 "$MK"   # uid 0 im unshare-Namespace braucht Schreibrecht auf MK
KEEP="${HARNESS_KEEP:-0}"
trap 'if [[ "$KEEP" == "1" ]]; then echo "(Behalten: $MK)"; else rm -rf "$MK"; fi' EXIT
HS="$MK/state"
HOSTBIN="$MK/bin-host"
INNERBIN="$MK/bin-inner"
FIX="$MK/fixtures"
CASES="$MK/cases"; mkdir -p "$HS" "$HOSTBIN" "$INNERBIN" "$CASES" "$FIX" \
    "$MK/etc" "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp"
CT_IP="10.120.5.77"

PASSED=0; FAILED=0; CUR_NAME=""; CUR_DIR=""

pass() { PASSED=$((PASSED+1)); echo "  ✔ $CUR_NAME – $1"; }
fail() { FAILED=$((FAILED+1)); echo "  ✘ $CUR_NAME – $1"; [[ -n "${2:-}" ]] && echo "      ↳ $2"; }
t()    { CUR_NAME="$1"; CUR_DIR=$(mktemp -d "$CASES/case.XXXXXX"); }

assert_exit() {
    local want="$1" got="$2"
    if [[ "$got" == "$want" ]]; then pass "exit=$got (erwartet $want)"
    else fail "exit=$got, erwartet $want"; fi
}
assert_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then pass "Ausgabe enthält: $1"
    else fail "Ausgabe enthält NICHT: $1"; fi
}
assert_no_out() {
    if /bin/grep -qF -- "$1" "$CUR_DIR/out.log" 2>/dev/null; then fail "Ausgabe enthält (sollte nicht): $1"
    else pass "Ausgabe enthält nicht: $1"; fi
}
assert_file() {
    if [[ -e "$1" ]]; then pass "existiert: ${1#"$MK"/}"
    else fail "fehlt: ${1#"$MK"/}"; fi
}
assert_no_file() {
    if [[ -e "$1" ]]; then fail "Datei existiert (sollte nicht): ${1#"$MK"/}"
    else pass "Datei fehlt (korrekt): ${1#"$MK"/}"; fi
}
assert_fcontains() {
    if [[ -f "$1" ]] && /bin/grep -qF -- "$2" "$1"; then pass "${1#"$MK"/} enthält: $2"
    else fail "${1#"$MK"/} enthält NICHT: $2"; fi
}
assert_fregex() {
    if [[ -f "$1" ]] && /bin/grep -qE -- "$2" "$1"; then pass "${1#"$MK"/} matcht: $2"
    else fail "${1#"$MK"/} matcht NICHT: $2"; fi
}
assert_calls() { # ≥COUNT needle im Mock-Calls-Log
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" -ge "$want" ]]; then pass "Calls ≥$want: $needle (ist $got)"
    else fail "Calls <$want: $needle (ist $got)"; fi
}
assert_calls_eq() {
    local want="$1" needle="$2" got
    got=$(/bin/grep -cF -- "$needle" "$HS/calls.log" 2>/dev/null || true)
    if [[ "$got" == "$want" ]]; then pass "Calls ==$want: $needle"
    else fail "Calls ==$want erwartet, ist $got: $needle"; fi
}
assert_no_calls() {
    if /bin/grep -qF -- "$1" "$HS/calls.log" 2>/dev/null; then fail "Unerwarteter Call: $1"
    else pass "Kein Call: $1"; fi
}
dump_case() {
    echo "---- out.log ($CUR_NAME) ----"; tail -n 50 "$CUR_DIR/out.log" 2>/dev/null
    echo "---- calls.log ----"; tail -n 30 "$HS/calls.log" 2>/dev/null
}

# ── Mock-Umgebung bauen (env -i: Profil-Funktionen wie grep→ugrep meiden) ──
realbin() { env -i /bin/sh -c "command -v $1" || { echo "✘ real binary fehlt: $1"; exit 1; }; }
link_real() {
    local dest="$1"; shift
    local b
    for b in "$@"; do ln -sf "$(realbin "$b")" "$dest/$b"; done
}
link_real "$HOSTBIN" bash sh env awk sed grep cut head tail tr od mktemp tee openssl \
    seq cat mv cp rm mkdir chmod dirname basename sort uniq readlink date printf ls touch \
    stat id du find tar hostname
ln -sf "$MK/mock-uname"  "$HOSTBIN/uname"
ln -sf "$MK/mock-wget"   "$HOSTBIN/wget"
ln -sf "$MK/mock-pct"    "$HOSTBIN/pct"
ln -sf "$MK/mock-pveam"  "$HOSTBIN/pveam"
ln -sf "$MK/mock-pvesh"  "$HOSTBIN/pvesh"
ln -sf "$MK/mock-sleep"  "$HOSTBIN/sleep"
ln -sf "$MK/mock-sleep"  "$INNERBIN/sleep"

# Inner-Fakebin: nacktes Debian simulieren (KEIN curl, KEIN node, KEIN python3)
link_real "$INNERBIN" bash sh env awk sed grep cut head tail tr od seq cat mv cp rm \
    mkdir chmod dirname basename sort uniq printf ls touch readlink stat uname \
    tee openssl wc ln du find tar xargs gzip gunzip date install
ln -sf "$MK/mock-aptget"    "$INNERBIN/apt-get"
ln -sf "$MK/mock-systemctl" "$INNERBIN/systemctl"
ln -sf "$MK/mock-getent"    "$INNERBIN/getent"
ln -sf "$MK/mock-hostname"  "$INNERBIN/hostname"
ln -sf "$MK/mock-su"        "$INNERBIN/su"
ln -sf "$MK/mock-lsb"       "$INNERBIN/lsb_release"
ln -sf "$MK/mock-useradd"   "$INNERBIN/useradd"
ln -sf "$MK/mock-chown"     "$INNERBIN/chown"
ln -sf "$MK/mock-journalctl" "$INNERBIN/journalctl"

seed_inner_tools() { # simuliert bereits installierte Tools (Update-Pfad)
    ln -sf "$MK/mock-curl"    "$INNERBIN/curl"
    ln -sf "$MK/mock-python3" "$INNERBIN/python3"
    ln -sf "$MK/mock-node"    "$INNERBIN/node"
    ln -sf "$MK/mock-npm"     "$INNERBIN/npm"
    ln -sf "$MK/mock-git"     "$INNERBIN/git"
}
unseed_inner_tools() {
    rm -f "$INNERBIN/curl" "$INNERBIN/python3" "$INNERBIN/node" \
          "$INNERBIN/npm" "$INNERBIN/npx" "$INNERBIN/git"
}

# ══════════════════════════ Fixtures ══════════════════════════════════════
# Repo-Klon: git-Mock "klont" ein Fixture-Repo mit den vom Inner-Script
# erwarteten Dateien (requirements.txt, docker/start-fixed.py, package.json …)
mk_fixtures() {
    local src="$MK/fixture-repo"
    rm -rf "$src"
    mkdir -p "$src/docker" "$src/app/static"
    printf '#!/usr/bin/env python3\nprint("fixture-start")\n' > "$src/docker/start-fixed.py"
    printf 'Flask==3.1.3\n' > "$src/requirements.txt"
    printf '{"name":"timetracker-frontend","scripts":{"build:docker":"node build.js"}}\n' > "$src/package.json"
    printf 'body{}\n' > "$src/app/static/src.css"
}
mk_fixtures

# ══════════════════════════ Mock-Binaries ══════════════════════════════════
cat > "$MK/mock-sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$MK/mock-uname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
arch="x86_64"
[[ -f "$HS/host_arch" ]] && arch=$(/bin/sed -n 's/^//p' "$HS/host_arch")
if [[ "${1:-}" == "-m" ]]; then echo "$arch"; exit 0; fi
echo "Linux harness 6.8.0 mock ${arch} GNU/Linux"
exit 0
EOF

cat > "$MK/mock-wget" <<'EOF'
#!/usr/bin/env bash
# wget-Mock: -qLO - <url> gibt den Installer-Inhalt aus (wie echtes wget -O -)
set -u
HS="${HARNESS_STATE:?}"
echo "wget $*" >> "$HS/calls.log"
# letzten Parameter als URL nehmen
url="${*: -1}"
case "$url" in
    *install/timetracker.sh) /bin/cat "$HS/installer_src" 2>/dev/null || true ;;
    *) : ;;
esac
exit 0
EOF

cat > "$MK/mock-pvesh" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pvesh $*" >> "$HS/calls.log"
# pvesh get /cluster/nextid → nächste freie ID
nid=$(cat "$HS/nextid" 2>/dev/null || echo 150)
echo "$nid"
exit 0
EOF

cat > "$MK/mock-pct" <<'EOF'
#!/usr/bin/env bash
# pct-Mock: State in $HARNESS_STATE, Mock-Root = dirname davon
set -u
HS="${HARNESS_STATE:?HARNESS_STATE fehlt}"
MK="${HS%/*}"
echo "pct $*" >> "$HS/calls.log"
cmd="${1:-}"
# Argumente OHNE cmd/id parsen (pct <cmd> [id] …); id ist bei den meisten
# Befehlen $2, bei create $2 (id) und $3 (template).
id="${2:-}"

case "$cmd" in
    list)
        printf 'VMID       Status     Lock Name\n'
        [[ -s "$HS/ct_list" ]] && cat "$HS/ct_list"
        exit 0 ;;
    status)
        f="$HS/ct_${id}.status"
        [[ -f "$f" ]] || exit 2
        echo "status: $(cat "$f")"; exit 0 ;;
    create)
        echo "pct create $*" >> "$HS/calls.log"
        if [[ -f "$HS/create_fail" ]]; then echo "mock: create fehlgeschlagen" >&2; exit 255; fi
        # pct create <id> <template> … → id=$2, template=$3
        local_id="${2:-}"
        tmpl="${3:-}"
        tmpl_base="${tmpl##*/}"
        if [[ ! -f "$HS/templates/$tmpl_base" ]]; then
            echo "mock: Template $tmpl nicht vorhanden" >&2; exit 2
        fi
        { echo "TEMPLATE=$tmpl"; echo "ARGS=$*"; } > "$HS/ct_${local_id}.create"
        hostname="ct-$local_id"
        prev=""
        for a in "${@:4}"; do
            if [[ "$prev" == "--hostname" ]]; then hostname="$a"; fi
            prev="$a"
        done
        echo "$hostname" > "$HS/ct_${local_id}.hostname"
        if [[ -f "$HS/create_start_fail" ]]; then
            # Live-Grube 31a: pct create meldet Exit 0, Start schlug fehl
            echo "$local_id stopped $hostname" >> "$HS/ct_list"
            echo "stopped" > "$HS/ct_${local_id}.status"
            exit 0
        fi
        echo "$local_id running $hostname" >> "$HS/ct_list"
        echo "running" > "$HS/ct_${local_id}.status"
        exit 0 ;;
    start)
        if [[ -f "$HS/start_fail" ]]; then echo "mock: Start fehlgeschlagen" >&2; exit 255; fi
        if [[ -f "$HS/create_start_fail" ]]; then
            # Live-Grube 31a: create meldet Exit 0, Start schlug fehl → CT bleibt stopped
            echo "stopped" > "$HS/ct_${id}.status"
            /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
            exit 0
        fi
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "running" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id running $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    stop)
        [[ -f "$HS/ct_${id}.status" ]] || { echo "mock: CT $id unbekannt" >&2; exit 2; }
        echo "stopped" > "$HS/ct_${id}.status"
        /bin/sed -i "s|^$id .*|$id stopped $(cat "$HS/ct_${id}.hostname" 2>/dev/null || echo ct-$id)|" "$HS/ct_list"
        exit 0 ;;
    destroy)
        /bin/sed -i "/^$id /d" "$HS/ct_list"
        rm -f "$HS/ct_${id}".status "$HS/ct_${id}".create "$HS/ct_${id}.hostname"
        exit 0 ;;
    push)
        src="${3:-}"; dst="${4:-}"
        mkdir -p "$MK$(dirname "$dst")"
        # Reihenfolge WICHTIG: /tmp zuerst (Mock-Root liegt unter /tmp).
        # /usr/share + /usr/local: uid 0 im Namespace darf echte Systempfade nicht
        # schreiben → im Inner-Script auf Mock-Root umschreiben.
        /bin/sed -e "s|/tmp/|$MK/tmp/|g" -e "s|/etc/|$MK/etc/|g" \
            -e "s|/usr/share|$MK/usr/share|g" -e "s|/usr/local|$MK/usr/local|g" \
            -e "s|/opt/timetracker|$MK/opt/timetracker|g" \
            -e "s|/data|$MK/data|g" -e "s|/app|$MK/app|g" \
            "$src" > "$MK$dst"
        chmod 755 "$MK$dst" 2>/dev/null || true
        echo "pct push $id $src $dst" >> "$HS/calls.log"
        exit 0 ;;
    exec)
        # pct exec <id> [--] [env K=V …] <cmd …>  → args ab Index 3 (nach cmd + id)
        args=("${@:3}")
        if [[ "${args[0]:-}" == "--" ]]; then args=("${args[@]:1}"); fi
        envs=()
        if [[ "${args[0]:-}" == "env" ]]; then
            args=("${args[@]:1}")
            while [[ "${args[0]:-}" == *=* ]]; do envs+=("${args[0]}"); args=("${args[@]:1}"); done
        fi
        # Root-Rechte im CT simulieren: als uid 0 (unshare-Namespace) laufen lassen.
        # WICHTIG: /usr/share-Pfade im Skript-String auf Mock-Root umschreiben,
        # da uid 0 im Namespace keine echten Systempfade schreiben darf.
        if [[ "${args[0]:-}" == "bash" && "${args[1]:-}" == "-c" ]]; then
            if [[ -f "$HS/exec_fail" ]]; then echo "mock: exec erzwingt Fehler" >&2; exit 255; fi
            if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
                echo "mock: CT $id läuft nicht" >&2; exit 255
            fi
            INNERBIN="$MK/bin-inner"
            inner_cmd="${args[2]:-}"
            # /usr/share- und /usr/local-Pfade auf Mock-Root (uid 0 darf echte nicht schreiben)
            inner_cmd="${inner_cmd//\/usr\/share/$MK/usr/share}"
            inner_cmd="${inner_cmd//\/usr\/local/$MK/usr/local}"
            inner_cmd="${inner_cmd//\/root\//$MK/root/}"
            inner_cmd="${inner_cmd//\/var\/log/$MK/var/log}"
            inner_cmd="${inner_cmd//\/etc\//$MK/etc/}"
            inner_cmd="${inner_cmd//\/opt\/timetracker/$MK/opt/timetracker}"
            echo "pct exec $id bash -c (inner)" >> "$HS/calls.log"
            exec env -i PATH="$INNERBIN" \
                HARNESS_STATE="$HS" MKROOT="$MK" \
                HOME=/root TERM=dumb LANG=C.UTF-8 \
                ${envs[@]+"${envs[@]}"} \
                bash -c "$inner_cmd"
        fi
        if [[ -f "$HS/exec_fail" ]]; then echo "mock: exec erzwingt Fehler" >&2; exit 255; fi
        if [[ ! -f "$HS/ct_${id}.status" || "$(cat "$HS/ct_${id}.status" 2>/dev/null)" != "running" ]]; then
            echo "mock: CT $id läuft nicht" >&2
            echo "pct exec $id (ABGELEHNT – CT gestoppt)" >> "$HS/calls.log"
            exit 255
        fi
        INNERBIN="$MK/bin-inner"
        rewrite_path() {
            local a="$1"
            a="${a//\/opt\/timetracker/$MK/opt/timetracker}"
            a="${a//\/usr\/share/$MK/usr/share}"
            a="${a//\/usr\/local/$MK/usr/local}"
            a="${a//\/root\//$MK/root/}"
            a="${a//\/var\/log/$MK/var/log}"
            a="${a//\/etc\//$MK/etc/}"
            printf '%s' "$a"
        }
        newargs=()
        for a in "${args[@]}"; do newargs+=("$(rewrite_path "$a")"); done
        newenvs=()
        for a in ${envs[@]+"${envs[@]}"}; do newenvs+=("$(rewrite_path "$a")"); done
        exec env -i PATH="$INNERBIN" \
            HARNESS_STATE="$HS" MKROOT="$MK" \
            HOME=/root TERM=dumb LANG=C.UTF-8 \
            ${newenvs[@]+"${newenvs[@]}"} \
            "${newargs[@]}"
        ;;
    config)
        if [[ ! -f "$HS/ct_${id}.hostname" ]]; then echo "mock: CT $id unbekannt" >&2; exit 2; fi
        printf 'arch: amd64\ncores: 2\nhostname: %s\nonboot: 1\nunprivileged: 1\nfeatures: nesting=1\n' "$(cat "$HS/ct_${id}.hostname")"
        exit 0 ;;
    set) exit 0 ;;
    enter|rollback|clone|resume|suspend|reboot|snapshot|delvolume|mount|resize|move|reindex)
        exit 0 ;;
    *)
        echo "mock-pct: unbekannter Befehl $cmd" >&2; exit 1 ;;
esac
EOF

cat > "$MK/mock-pveam" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pveam $*" >> "$HS/calls.log"
TMPL="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
TMPL_ARM="local:vztmpl/debian-12-standard_12.7-1_arm64.tar.zst"
have_arm() { [[ -f "$HS/arm64_only" || -f "$HS/arm64_too" ]]; }
case "${1:-}" in
    list)
        if [[ -f "$HS/template_downloaded" && ! -f "$HS/pveam_empty" ]]; then
            if [[ -f "$HS/arm64_only" ]]; then echo "$TMPL_ARM  999"; else echo "$TMPL  123456789"; fi
            have_arm && [[ ! -f "$HS/arm64_only" ]] && echo "$TMPL_ARM  999"
        fi
        exit 0 ;;
    available)
        if [[ ! -f "$HS/pveam_empty" ]]; then
            if [[ -f "$HS/arm64_only" ]]; then echo "system          $TMPL_ARM  999"; else echo "system          $TMPL  123456789"; fi
            have_arm && [[ ! -f "$HS/arm64_only" ]] && echo "system          $TMPL_ARM  999"
        fi
        exit 0 ;;
    update)   exit 0 ;;
    download)
        # pveam download local <template> → Template ist $3!
        mkdir -p "$HS/templates"
        # Origin (available/list) liefert "local:vztmpl/<file>" → nur <file> merken
        tname="${3##*/}"
        touch "$HS/templates/$tname"
        touch "$HS/template_downloaded"
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-curl" <<'EOF'
#!/usr/bin/env bash
# curl-Mock: Health-Checks → 200/000 je nach Lever (fail_health);
# Download-Endpunkte (nodesource, postgres-Key, nodejs-Binary) → immer Erfolg
set -u
HS="${HARNESS_STATE:?}"
MK="${MKROOT:-$(dirname "$HS")}"
url=""; prev=""
for a in "$@"; do
    case "$a" in http://*|https://*) url="$a" ;; esac
    prev="$a"
done
echo "curl $*" >> "$HS/calls.log" 2>/dev/null || true

case "$url" in
    */_health*)
        code="200"
        if [[ -f "$HS/fail_health" ]]; then code="000"; fi
        echo "$code"; [[ "$code" == "200" ]] && exit 0 || exit 7 ;;
esac
# Download-Endpunkte → Erfolg
exit 0
EOF

cat > "$MK/mock-systemctl" <<'EOF'
#!/usr/bin/env bash
# systemctl-Mock (inner): timetracker-Service mit Active-Marker
set -u
HS="${HARNESS_STATE:?}"
MK="${HS%/*}"
echo "systemctl $*" >> "$HS/calls.log"
unitdir="$MK/etc/systemd/system"
case "${1:-}" in
    daemon-reload) exit 0 ;;
    enable) mkdir -p "$unitdir"; echo "${2:-}" >> "$HS/enabled_units"; exit 0 ;;
    start|restart)
        if [[ "${2:-}" == "timetracker" || "${3:-}" == "timetracker" ]]; then
            [[ -f "$unitdir/timetracker.service" ]] || { echo "mock: unit fehlt" >&2; exit 1; }
            touch "$HS/timetracker_active"
        fi
        exit 0 ;;
    stop) rm -f "$HS/timetracker_active"; exit 0 ;;
    is-active)
        # pct exec ID -- systemctl is-active NAME  → NAME ist $2
        svc="${2:-}"
        if [[ "$svc" == "timetracker" && -f "$HS/timetracker_active" ]]; then echo "active"; exit 0; fi
        echo "inactive"; exit 3 ;;
    status) echo "mock: ${2:-} active-ish"; exit 0 ;;
    *) exit 0 ;;
esac
EOF

cat > "$MK/mock-aptget" <<'EOF'
#!/usr/bin/env bash
# apt-Mock: installiert curl/node/python3/git real in die Inner-Fakebin
set -u
HS="${HARNESS_STATE:?}"
MK="${HS%/*}"
INNERBIN_DIR="$MK/bin-inner"
echo "apt-get $*" >> "$HS/calls.log"
if [[ "${1:-}" == "install" ]]; then
    for a in "$@"; do
        case "$a" in
            curl)
                [[ -e "$INNERBIN_DIR/curl" ]] || ln -sf "$MK/mock-curl" "$INNERBIN_DIR/curl" ;;
            nodejs)
                [[ -e "$INNERBIN_DIR/node" ]] || ln -sf "$MK/mock-node" "$INNERBIN_DIR/node"
                [[ -e "$INNERBIN_DIR/npm" ]] || ln -sf "$MK/mock-npm" "$INNERBIN_DIR/npm" ;;
            python3)
                [[ -e "$INNERBIN_DIR/python3" ]] || ln -sf "$MK/mock-python3" "$INNERBIN_DIR/python3" ;;
            git)
                [[ -e "$INNERBIN_DIR/git" ]] || ln -sf "$MK/mock-git" "$INNERBIN_DIR/git" ;;
        esac
    done
fi
exit 0
EOF

cat > "$MK/mock-node" <<'EOF'
#!/usr/bin/env bash
echo "v20.18.1"
exit 0
EOF

cat > "$MK/mock-npm" <<'EOF'
#!/usr/bin/env bash
# npm-Mock: install/build → legt app/static/dist + vendor an (wie build:docker)
set -u
HS="${HARNESS_STATE:?}"
echo "npm $*" >> "$HS/calls.log"
if [[ "${1:-}" == "run" && "${2:-}" == "build:docker" ]]; then
    mkdir -p app/static/dist app/static/vendor
    echo "body{}" > app/static/dist/output.css
    echo "//bundle" > app/static/dist/app.min.js
    echo "/*vendor*/" > app/static/vendor/chart.js
fi
exit 0
EOF

cat > "$MK/mock-git" <<'EOF'
#!/usr/bin/env bash
# git-Mock: clone/fetch/reset → Fixture-Repo an Zielpfad kopieren
set -u
HS="${HARNESS_STATE:?}"
MK="${HS%/*}"
echo "git $*" >> "$HS/calls.log"
case "${1:-}" in
    clone)
        # git clone --depth 1 <repo> <dir>  → dir ist $4
        dst="${4:-}"
        [[ -n "$dst" ]] || exit 1
        mkdir -p "$dst"
        cp -a "$MK/fixture-repo/." "$dst/" 2>/dev/null || true
        # .git-Marker + HEAD
        mkdir -p "$dst/.git"
        echo "ref: refs/heads/main" > "$dst/.git/HEAD"
        echo "abc123def456" > "$dst/.git/HEAD.sha"
        exit 0 ;;
    -C)
        # git -C <dir> rev-parse --short HEAD
        if [[ "${3:-}" == "rev-parse" ]]; then echo "abc123"; exit 0; fi
        exit 0 ;;
    fetch|reset) exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-python3" <<'EOF'
#!/usr/bin/env bash
# python3-Mock: -m venv DIR erzeugt venv mit pip/python-Mocks
set -u
HS="${HARNESS_STATE:?}"
MK="${HS%/*}"
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
    dir="${3:-}"
    [[ -n "$dir" ]] || exit 1
    mkdir -p "$dir/bin"
    ln -sf "$MK/mock-pip"    "$dir/bin/pip"
    ln -sf "$MK/mock-python3" "$dir/bin/python"
    exit 0
fi
echo "mock python3: $*"; exit 0
EOF

cat > "$MK/mock-pip" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
echo "pip $*" >> "$HS/calls.log"
for a in "$@"; do
    if [[ -f "$a" ]]; then echo "pip: requirements gefunden: $a"; fi
done
exit 0
EOF

cat > "$MK/mock-getent" <<'EOF'
#!/usr/bin/env bash
# DNS-Mock: ok | fail | flaky (jeder 3. failt) | fail_then_ok.
# Nach Fallback (resolv.conf enthält 1.1.1.1) antwortet der Mock immer ok.
set -u
HS="${HARNESS_STATE:?}"
MK="${HS%/*}"
if [[ -f "$MK/etc/resolv.conf" ]] && /bin/grep -q 'nameserver 1.1.1.1' "$MK/etc/resolv.conf"; then
    exit 0
fi
mode="ok"
[[ -f "$HS/getent_mode" ]] && mode=$(/bin/sed -n 's/^getent_mode=//p' "$HS/getent_mode")
case "$mode" in
    ok) exit 0 ;;
    fail) exit 2 ;;
    flaky)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        if [[ $((n % 3)) -eq 0 ]]; then exit 2; fi
        exit 0 ;;
    fail_then_ok)
        n=$(cat "$HS/getent_count" 2>/dev/null || echo 0)
        n=$((n+1)); echo "$n" > "$HS/getent_count"
        [[ "$n" -le 6 ]] && exit 2
        exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-hostname" <<'EOF'
#!/usr/bin/env bash
set -u
HS="${HARNESS_STATE:?}"
if [[ -f "$HS/no_ip" ]]; then exit 0; fi
IP=$(cat "$HS/ct_ip" 2>/dev/null || echo "10.120.5.77")
if [[ "${1:-}" == "-I" ]]; then printf '%s 2601:db8::1 \n' "$IP"; exit 0; fi
echo "timetracker"; exit 0
EOF

cat > "$MK/mock-su" <<'EOF'
#!/usr/bin/env bash
# su-Mock (inner): su - postgres -c "<cmd>" → cmd ausführen (psql/createdb)
set -u
HS="${HARNESS_STATE:?}"
echo "su $*" >> "$HS/calls.log"
# su - postgres -c '…' → letztes Argument ist das Kommando
cmd="${*: -1}"
case "$cmd" in
    psql*|*psql*)
        # SELECT 1 … → "0" (Rolle/DB existiert noch nicht)
        echo "0"
        exit 0 ;;
    createdb*) exit 0 ;;
esac
# SHOW server_encoding / pg_encoding_to_char → UTF8 melden
case "$cmd" in
    *server_encoding*) echo "UTF8"; exit 0 ;;
    *pg_encoding_to_char*) echo "UTF8"; exit 0 ;;
esac
exit 0
EOF

cat > "$MK/mock-lsb" <<'EOF'
#!/usr/bin/env bash
# lsb_release-Mock: Debian 12 (trixie fallback)
echo "Debian GNU/Linux 12 (bookworm)"
exit 0
EOF

cat > "$MK/mock-useradd" <<'EOF'
#!/usr/bin/env bash
# useradd-Mock: legt Home-Verzeichnis an (id-Check weiter unten)
exit 0
EOF

cat > "$MK/mock-chown" <<'EOF'
#!/usr/bin/env bash
# chown-Mock: no-op (uid 0 im Namespace darf nicht chownen)
exit 0
EOF

cat > "$MK/mock-journalctl" <<'EOF'
#!/usr/bin/env bash
# journalctl-Mock: gibt Setup-Log aus
exit 0
EOF

chmod +x "$MK"/mock-* "$MK"/bin-host/* "$MK"/bin-inner/* 2>/dev/null

# ── Runner ─────────────────────────────────────────────────────────────────
reset_state() {
    rm -rf "$HS" "${MK:?}/opt" "${MK:?}/etc" "${MK:?}/root" "${MK:?}/var/log" "${MK:?}/tmp" \
        "${MK:?}/usr" "${MK:?}/data" "${MK:?}/app"
    mkdir -p "$HS" "$HS/templates" "$MK/etc/systemd/system" "$MK/etc/apt/sources.list.d" \
        "$MK/opt" "$MK/root" "$MK/var/log" "$MK/tmp" "$MK/usr/share" "$MK/usr/local" "$MK/data" "$MK/app"
    echo "$CT_IP" > "$HS/ct_ip"
    echo "150" > "$HS/nextid"
    : > "$HS/ct_list"
    echo "getent_mode=ok" > "$HS/getent_mode"
    cp "$SCRIPT" "$HS/installer_src"
    unseed_inner_tools
}
run_installer() {
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_as_arg0() { # Produktions-Pattern: bash -c "$(…)" --flag → $0 ist die Flag
    ( unshare -rm env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
run_installer_nonroot() {
    ( env -i PATH="$HOSTBIN:/usr/sbin:/usr/bin:/sbin:/bin" \
        HARNESS_STATE="$HS" HOME=/root TERM=dumb LANG=C.UTF-8 \
        bash "$SCRIPT" "$@" > "$CUR_DIR/out.log" 2>&1 )
    echo $?
}
seed_ct() { # laufender CT mit installiertem TimeTracker-Stack
    reset_state
    echo "150 running timetracker" > "$HS/ct_list"
    echo "running" > "$HS/ct_150.status"
    echo "timetracker" > "$HS/ct_150.hostname"
    mkdir -p "$MK/opt/timetracker/docker" "$MK/opt/timetracker/venv/bin" \
        "$MK/etc/systemd/system" "$MK/var/log" "$MK/data"
    printf '#!/usr/bin/env python3\nprint("fixture")\n' > "$MK/opt/timetracker/docker/start-fixed.py"
    printf 'Flask==3.1.3\n' > "$MK/opt/timetracker/requirements.txt"
    ln -sf "$MK/mock-python3" "$MK/opt/timetracker/venv/bin/python"
    ln -sf "$MK/mock-pip"     "$MK/opt/timetracker/venv/bin/pip"
    touch "$MK/etc/systemd/system/timetracker.service" "$HS/timetracker_active"
    seed_inner_tools
}

# ══════════════════════════ Cases ═════════════════════════════════════════
echo "🧪 TimeTracker-Installer-Harness gegen $SCRIPT"
echo

# ── Argumente & Modi ───────────────────────────────────────────────────────
t "root-check schlägt fehl (EUID≠0)"
ec=$(run_installer_nonroot)
assert_exit 1 "$ec"
assert_out "als root"

t "--help zeigt Optionen und Einzeiler"
ec=$(run_installer --help)
assert_exit 0 "$ec"
assert_out "--id"
assert_out "timetracker.sh"
assert_out "--update"

t "unbekannte Option → die()"
ec=$(run_installer --falsch)
assert_exit 1 "$ec"
assert_out "Unbekannte Option"

# ── Install: Happy Path ────────────────────────────────────────────────────
t "Install: Happy Path (nächste freie ID, Arch amd64)"
reset_state
ec=$(run_installer --yes)
dump_case
assert_exit 0 "$ec"
assert_out "CT-ID: 150"
assert_out "Host-Architektur: amd64"
assert_out "Template: debian-12-standard_12.7-1_amd64.tar.zst"
assert_out "CT-IP: 10.120.5.77"
assert_out "systemctl is-active: active"
assert_out "HTTP /_health = 200"
assert_out "http://10.120.5.77:8080"
assert_out "TimeTracker ist installiert"
assert_calls 1 "pvesh get /cluster/nextid"
assert_calls 1 "pct create 150"
assert_file "$MK/etc/systemd/system/timetracker.service"
assert_fcontains "$MK/etc/systemd/system/timetracker.service" "Restart=always"
assert_fcontains "$MK/etc/systemd/system/timetracker.service" "After=network-online.target postgresql.service"
assert_fcontains "$MK/etc/systemd/system/timetracker.service" "start-fixed.py"
assert_fcontains "$MK/etc/systemd/system/timetracker.service" "PYTHONPATH="
assert_fcontains "$MK/etc/systemd/system/timetracker.service" "LANG=C.UTF-8"
assert_file "$MK/opt/timetracker/.env"
assert_fcontains "$MK/opt/timetracker/.env" "DATABASE_URL=postgresql+psycopg2://timetracker:"
assert_fcontains "$MK/opt/timetracker/.env" "PORT=8080"
assert_file "$MK/opt/timetracker/app/static/dist/output.css"
assert_file "$MK/opt/timetracker/app/static/vendor/chart.js"

t "Install: pct create bekommt onboot/nesting/unprivileged"
assert_fregex "$HS/ct_150.create" "ARGS=.*--onboot 1"
assert_fregex "$HS/ct_150.create" "ARGS=.*--features nesting=1"
assert_fregex "$HS/ct_150.create" "ARGS=.*--unprivileged 1"

# ── Install: Arch-Falle (arm64-Template auf amd64-Host) ────────────────────
t "Install: arm64-Template wird auf amd64-Host NICHT gewählt (Grube 31a)"
reset_state
touch "$HS/arm64_too"
ec=$(run_installer --yes)
assert_exit 0 "$ec"
assert_out "amd64"
assert_no_out "arm64"

t "Install: create_start_fail → verify_ct_started stirbt mit Reinstall-Hinweis"
reset_state
touch "$HS/create_start_fail"
ec=$(run_installer --yes)
assert_exit 1 "$ec"
assert_out "nicht 'running'"
assert_out "pct destroy"

# ── Install: Fehlerpfade ───────────────────────────────────────────────────
t "Install: exec_fail → Fehlerkette mit Exit-Code + bash -x-Angebot"
reset_state
seed_inner_tools
touch "$HS/exec_fail"
ec=$(run_installer --yes)
assert_exit 1 "$ec"
assert_out "CT bekam keine IP"

t "Install: fail_health → Verifikation stirbt (HTTP != 200)"
reset_state
seed_inner_tools
touch "$HS/fail_health"
ec=$(run_installer --yes)
assert_exit 1 "$ec"
assert_out "nicht healthy"

t "Install: keine IP (DHCP tot) → die()"
reset_state
touch "$HS/no_ip"
ec=$(run_installer --yes)
assert_exit 1 "$ec"
assert_out "keine IP"

# ── Update ─────────────────────────────────────────────────────────────────
t "Update: findet laufenden CT per Hostname, baut neu, Service active"
seed_ct
ec=$(run_installer --update)
assert_exit 0 "$ec"
assert_out "Update auf CT 150"
assert_out "http://10.120.5.77:8080"
assert_calls 1 "pct exec 150"

t "Update: --id erzwingt CT-ID"
seed_ct
ec=$(run_installer --update --id 150)
assert_exit 0 "$ec"

t "Update: kein CT → die() mit --id-Hinweis"
reset_state
ec=$(run_installer --update)
assert_exit 1 "$ec"
assert_out "Nutze --id"

t "Update: gestoppten CT starten (ensure_ct_running, Grube 10)"
seed_ct
echo "stopped" > "$HS/ct_150.status"
/bin/sed -i 's/^150 .*/150 stopped timetracker/' "$HS/ct_list"
ec=$(run_installer --update)
assert_exit 0 "$ec"
assert_calls 1 "pct start 150"
assert_out "http://10.120.5.77:8080"

# ── Status ─────────────────────────────────────────────────────────────────
t "Status: laufender CT → URL + http=200"
seed_ct
ec=$(run_installer --status)
assert_exit 0 "$ec"
assert_out "running"
assert_out "service=active"
assert_out "http=200"
assert_out "http://10.120.5.77:8080"

t "Status: kein CT → die()"
reset_state
ec=$(run_installer --status)
assert_exit 1 "$ec"
assert_out "Kein CT gefunden"

# ── Uninstall ──────────────────────────────────────────────────────────────
t "Uninstall: zerstört CT nach Bestätigung"
seed_ct
ec=$(run_installer --uninstall --yes)
assert_exit 0 "$ec"
assert_calls 1 "pct destroy 150"
assert_out "entfernt"

t "Uninstall: ohne CT → nichts zu tun"
reset_state
ec=$(run_installer --uninstall --yes)
assert_exit 0 "$ec"
assert_no_calls "pct destroy"

# ══════════════════════════ Ergebnis ══════════════════════════════════════
echo
echo "════════════════════════════════════════"
if [[ $FAILED -eq 0 ]]; then
    echo "✅ ALLE CASES GRÜN: $PASSED Assertions bestanden"
    exit 0
else
    echo "❌ $FAILED Assertions FEHLGESCHLAGEN ($PASSED bestanden)"
    echo "   (HARNESS_KEEP=1 bash harness/run.sh behält Mock-Root: $MK)"
    exit 1
fi