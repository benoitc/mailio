#!/bin/sh
# Generate a private CA and a server certificate for "localhost" that Mailpit
# uses for STARTTLS in the tests. The tests trust only the CA.
# Run once before `docker compose up`. The files are git-ignored.
set -e
cd "$(dirname "$0")"
rm -rf certs
mkdir -p certs
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout certs/ca.key -out certs/ca.pem -days 825 \
    -subj "/CN=mailio test CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout certs/mailpit.key -out certs/mailpit.csr -subj "/CN=localhost"
printf 'subjectAltName=DNS:localhost\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth\n' > certs/ext.cnf
openssl x509 -req -in certs/mailpit.csr -CA certs/ca.pem -CAkey certs/ca.key -CAcreateserial \
    -out certs/mailpit.pem -days 825 -extfile certs/ext.cnf
rm -f certs/mailpit.csr certs/ext.cnf certs/ca.srl
chmod 644 certs/*
echo "wrote $(pwd)/certs/ca.pem (trust this) and mailpit.pem (the server certificate)"
