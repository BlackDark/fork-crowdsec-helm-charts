#!/bin/sh
# Seed agent config on PVC and symlink /etc/crowdsec without blocking on extraVolumeMounts.
set -eu

PVC_PATH="${CS_LAPI_REGISTRATION_PVC_PATH:-/etc/crowdsec_data}"

cp /tmp_config/local_api_credentials.yaml /staging/etc/crowdsec/local_api_credentials.yaml

if [ ! -f "$PVC_PATH/config.yaml" ]; then
  cp -a /staging/etc/crowdsec/. "$PVC_PATH/"
else
  for f in /staging/etc/crowdsec/*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    [ -e "$PVC_PATH/$base" ] || cp -a "$f" "$PVC_PATH/$base"
  done
fi

if [ -d /etc/crowdsec ] && [ ! -L /etc/crowdsec ]; then
  rm -rf /etc/crowdsec
fi
ln -snf "$PVC_PATH" /etc/crowdsec

if [ ! -f /etc/crowdsec/config.yaml ]; then
  echo "FATAL: /etc/crowdsec/config.yaml missing after bootstrap" >&2
  ls -la "$PVC_PATH/" >&2 || true
  exit 1
fi

rm -rf /staging/etc/crowdsec
exec ./docker_start.sh
