#!/bin/sh
# Idempotent LAPI registration for agents with optional config PVC.
set -eu

until nc "$LAPI_HOST" "$LAPI_PORT" -z; do
  echo "waiting for lapi to start"
  sleep 5
done

PVC_PATH="${CS_LAPI_REGISTRATION_PVC_PATH:-/etc/crowdsec_data}"
PVC_ENABLED="${CS_LAPI_REGISTRATION_PVC_ENABLED:-false}"
REUSE="${CS_LAPI_REGISTRATION_REUSE:-true}"
VALIDATE="${CS_LAPI_REGISTRATION_VALIDATE:-true}"
RETRY="${CS_LAPI_REGISTRATION_RETRY:-true}"
RETRY_MAX="${CS_LAPI_REGISTRATION_RETRY_MAX:-90}"
RETRY_INTERVAL="${CS_LAPI_REGISTRATION_RETRY_INTERVAL:-10}"

register() {
  cscli lapi register --machine "$USERNAME" -u "$LAPI_URL" --token "$REGISTRATION_TOKEN"
}

persist_credentials() {
  cp /etc/crowdsec/local_api_credentials.yaml /tmp_config/local_api_credentials.yaml
  if [ "$PVC_ENABLED" = "true" ]; then
    cp /etc/crowdsec/local_api_credentials.yaml "$PVC_PATH/local_api_credentials.yaml"
  fi
}

validate_stored_credentials() {
  valdir=/tmp/lapi-validate
  rm -rf "$valdir"
  mkdir -p "$valdir/etc/crowdsec"
  cp "$PVC_PATH/local_api_credentials.yaml" "$valdir/etc/crowdsec/local_api_credentials.yaml"
  if [ -f "$PVC_PATH/config.yaml" ]; then
    cp "$PVC_PATH/config.yaml" "$valdir/etc/crowdsec/config.yaml"
  else
    cp /staging/etc/crowdsec/config.yaml "$valdir/etc/crowdsec/config.yaml"
  fi
  cscli -c "$valdir/etc/crowdsec/config.yaml" lapi status >/tmp/lapi-check.err 2>&1
}

if [ "$PVC_ENABLED" = "true" ] && [ "$REUSE" = "true" ] && [ -s "$PVC_PATH/local_api_credentials.yaml" ]; then
  if [ ! -f "$PVC_PATH/config.yaml" ]; then
    cp -a /staging/etc/crowdsec/. "$PVC_PATH/"
  fi
  saved_login=$(grep -E '^login:' "$PVC_PATH/local_api_credentials.yaml" | awk '{print $2}' | tail -1)
  if [ "$saved_login" != "$USERNAME" ]; then
    echo "clearing stale credentials: PVC login $saved_login != pod $USERNAME"
    rm -f "$PVC_PATH/local_api_credentials.yaml"
  elif [ "$VALIDATE" = "true" ]; then
    if ! validate_stored_credentials; then
      echo "LAPI rejected stored credentials for $USERNAME; re-registering"
      cat /tmp/lapi-check.err >&2 || true
      rm -f "$PVC_PATH/local_api_credentials.yaml"
    else
      if [ ! -f "$PVC_PATH/config.yaml" ]; then
        echo "FATAL: config.yaml missing on PVC after init seed" >&2
        exit 1
      fi
      cp "$PVC_PATH/local_api_credentials.yaml" /tmp_config/local_api_credentials.yaml
      echo "reusing persisted LAPI credentials for $USERNAME"
      exit 0
    fi
  else
    cp "$PVC_PATH/local_api_credentials.yaml" /tmp_config/local_api_credentials.yaml
    echo "reusing persisted LAPI credentials for $USERNAME"
    exit 0
  fi
fi

if [ -e /etc/crowdsec ] && [ ! -L /etc/crowdsec ]; then
  rm -rf /etc/crowdsec
fi
ln -s /staging/etc/crowdsec /etc/crowdsec

if register 2>/tmp/register.err; then
  persist_credentials
  exit 0
fi

if [ "$RETRY" = "true" ] && grep -q "already exist" /tmp/register.err; then
  echo "machine $USERNAME already registered; waiting for autodelete or retrying"
  i=0
  while [ "$i" -lt "$RETRY_MAX" ]; do
    sleep "$RETRY_INTERVAL"
    i=$((i + 1))
    if register 2>/tmp/register.err; then
      persist_credentials
      exit 0
    fi
    grep -q "already exist" /tmp/register.err || { cat /tmp/register.err; exit 1; }
  done
fi

cat /tmp/register.err
exit 1
