#!/bin/sh
# Agent entrypoint: seed config PVC, sync hub data files, start crowdsec.
set -eu

PVC_PATH="${CS_LAPI_REGISTRATION_PVC_PATH:-/etc/crowdsec_data}"
PVC_BOOTSTRAP="${CS_AGENT_PVC_BOOTSTRAP:-false}"
HUB_UPGRADE="${CS_AGENT_HUB_UPGRADE:-true}"

ensure_config_tree() {
  if [ -f /tmp_config/local_api_credentials.yaml ]; then
    mkdir -p /staging/etc/crowdsec
    cp /tmp_config/local_api_credentials.yaml /staging/etc/crowdsec/local_api_credentials.yaml
  fi
  if [ ! -e /etc/crowdsec ] && [ -d /staging/etc/crowdsec ]; then
    ln -sf /staging/etc/crowdsec /etc/crowdsec
  fi
}

if [ "$PVC_BOOTSTRAP" = "true" ]; then
  ensure_config_tree
  for f in /staging/etc/crowdsec/*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    [ -e "$PVC_PATH/$base" ] || cp -a "$f" "$PVC_PATH/$base"
  done
  if [ ! -f "$PVC_PATH/config.yaml" ]; then
    echo "FATAL: $PVC_PATH/config.yaml missing before PVC bootstrap" >&2
    ls -la "$PVC_PATH/" >&2 || true
    exit 1
  fi
  if [ -d /etc/crowdsec ] && [ ! -L /etc/crowdsec ]; then
    rm -rf /etc/crowdsec
  fi
  ln -snf "$PVC_PATH" /etc/crowdsec
  rm -rf /staging/etc/crowdsec
else
  ensure_config_tree
fi

if [ "$HUB_UPGRADE" = "true" ] && [ -f /etc/crowdsec/config.yaml ]; then
  first_boot=false
  if [ "$PVC_BOOTSTRAP" = "true" ] && [ ! -d "$PVC_PATH/hub" ]; then
    first_boot=true
  fi
  echo "syncing hub (collections + scenario data)"
  if [ -n "${COLLECTIONS:-}" ]; then
    for collection in $COLLECTIONS; do
      if ! cscli collections install "$collection" --error-only 2>/dev/null \
        && ! cscli collections install "$collection" 2>/dev/null; then
        if [ "$first_boot" = true ]; then
          echo "FATAL: collections install failed for $collection on first boot" >&2
          exit 1
        fi
        echo "WARN: collections install $collection failed" >&2
      fi
    done
  fi
  if ! cscli hub upgrade; then
    if [ "$first_boot" = true ]; then
      echo "FATAL: hub upgrade failed on first boot" >&2
      exit 1
    fi
    echo "WARN: hub upgrade failed, retrying once" >&2
    cscli hub upgrade || echo "WARN: hub upgrade failed again" >&2
  fi
fi

exec ./docker_start.sh
