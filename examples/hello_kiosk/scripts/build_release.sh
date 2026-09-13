#!/bin/bash
# Build the hello_kiosk_brain release for the PW-SH6 Nerves SD.
# mix release (ERTS-less) + merge armv5 OTP apps from the nerves_system_brain
# staging tree (erlinit sets ROOTDIR=/srv/erlang, so $ROOT/lib must be complete).
set -eu
APP_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SYSTEM_ROOT=${NERVES_SYSTEM_BRAIN_DIR:-"$APP_ROOT/../.."}
NERVES_BUILD_DIR=${NERVES_BUILD_DIR:-"$SYSTEM_ROOT/o"}
cd "$APP_ROOT"

ERLANG_STAGING="$NERVES_BUILD_DIR/staging/usr/lib/erlang"
STAGING="$ERLANG_STAGING/lib"
NIF_INCLUDE_DIR=${ERTS_INCLUDE_DIR:-"$ERLANG_STAGING/usr/include"}
CROSSCOMPILE="$NERVES_BUILD_DIR/host/bin/arm-linux"
REL=_build/prod/rel/hello_kiosk_brain
NIF_SO=_build/prod/lib/hello_kiosk_brain/priv/kiosk_nif.so
ROOT_LIB_PATTERN="\\\$ROOT/lib/"

[ -d "$STAGING" ] || {
    echo "error: OTP staging tree not found: $STAGING" >&2
    echo "build nerves_system_brain first, or set NERVES_SYSTEM_BRAIN_DIR" >&2
    exit 1
}
[ -x "${CROSSCOMPILE}-g++" ] || {
    echo "error: ARMv5 C++ compiler not found: ${CROSSCOMPILE}-g++" >&2
    exit 1
}
[ -f "$NIF_INCLUDE_DIR/erl_nif.h" ] || {
    echo "error: target Erlang NIF header not found: $NIF_INCLUDE_DIR/erl_nif.h" >&2
    exit 1
}

MIX_ENV=prod mix compile
rm -f -- priv/kiosk_nif.so
CROSSCOMPILE="$CROSSCOMPILE" ERTS_INCLUDE_DIR="$NIF_INCLUDE_DIR" \
    MIX_APP_PATH="_build/prod/lib/hello_kiosk_brain" make

[ -s "$NIF_SO" ] || {
    echo "error: ARMv5 NIF was not built: $NIF_SO" >&2
    exit 1
}

MIX_ENV=prod mix release --overwrite

[ -f "$REL/releases/0.1.0/start.script" ] || {
    echo "error: release start.script not found: $REL/releases/0.1.0/start.script" >&2
    exit 1
}

while IFS= read -r app; do
    [ -n "$app" ] || continue
    [ -d "$REL/lib/$app" ] && continue
    [ -d "$STAGING/$app" ] || {
        echo "error: target OTP application not found: $STAGING/$app" >&2
        exit 1
    }
    cp -a "$STAGING/$app" "$REL/lib/"
done < <(grep -oE "${ROOT_LIB_PATTERN}[a-z0-9_.-]+/ebin" "$REL/releases/0.1.0/start.script" \
    | sed "s|${ROOT_LIB_PATTERN}||;s|/ebin||" | sort -u)

echo "release ready: $(du -sh "$REL" | cut -f1)"
