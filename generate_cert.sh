#!/bin/bash
set -e

# Cargar configuración desde .env
ENV_FILE="$(dirname "$0")/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: No se encontró .env en $ENV_FILE"
  exit 1
fi
source "$ENV_FILE"

# Validaciones básicas
if ! command -v openssl >/dev/null 2>&1; then
  echo "Error: openssl no está disponible en el PATH"
  exit 1
fi

REQUIRED_VARS=(CERTS_DIR CA_CERT CA_KEY DAYS_VALID ORGANIZATION)
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var}" ]]; then
    echo "Error: variable requerida vacía en .env: $var"
    exit 1
  fi
done

if [[ ! -f "$CA_CERT" ]]; then
  echo "Error: CA_CERT no existe: $CA_CERT"
  exit 1
fi

if [[ ! -f "$CA_KEY" ]]; then
  echo "Error: CA_KEY no existe: $CA_KEY"
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Uso: $0 <CN> [SAN1] [SAN2] [...]"
  echo "Ejemplo: $0 media.home.arpa jellyfin.home.arpa 192.168.1.50"
  exit 1
fi

CN="$1"
shift
SANS=("$@")  # SANs adicionales

# Validar CN básico (evita rutas inesperadas)
if [[ "$CN" =~ [/\ ] ]]; then
  echo "Error: el CN no puede contener '/' ni espacios"
  exit 1
fi

mkdir -p "$CERTS_DIR/$CN"

# 1. Generar clave privada
umask 077
openssl genrsa -out "$CERTS_DIR/$CN/$CN.key" 4096

# 2. Generar configuración con SANs
SAN_BLOCK=""
DNS_IDX=1
IP_IDX=1

for san in "${SANS[@]}"; do
  if [[ "$san" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    SAN_BLOCK+="IP.${IP_IDX} = ${san}\n"
    ((IP_IDX++))
  else
    SAN_BLOCK+="DNS.${DNS_IDX} = ${san}\n"
    ((DNS_IDX++))
  fi
done

# Agregar también el CN como SAN principal si no está en la lista
if [[ ! " ${SANS[@]} " =~ " ${CN} " ]]; then
  SAN_BLOCK="DNS.${DNS_IDX} = ${CN}\n${SAN_BLOCK}"
fi

cat > "$CERTS_DIR/$CN/$CN.cnf" <<EOF
[ req ]
default_bits       = 4096
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
CN = $CN
O  = $ORGANIZATION

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
$(echo -e "$SAN_BLOCK")
EOF

# 3. Crear CSR
openssl req -new -key "$CERTS_DIR/$CN/$CN.key" \
  -out "$CERTS_DIR/$CN/$CN.csr" \
  -config "$CERTS_DIR/$CN/$CN.cnf"

# 4. Firmar certificado
openssl x509 -req -in "$CERTS_DIR/$CN/$CN.csr" \
  -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
  -out "$CERTS_DIR/$CN/$CN.crt" \
  -days "$DAYS_VALID" -sha256 \
  -extensions req_ext -extfile "$CERTS_DIR/$CN/$CN.cnf"

echo "✅ Certificado generado: $CERTS_DIR/$CN/$CN.crt con SANs:"
printf '   - %s\n' "$CN" "${SANS[@]}"
