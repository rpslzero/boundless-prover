#!/bin/bash

apt update
apt install -y curl sudo nano nvtop git supervisor build-essential pkg-config libssl-dev python3-dev
echo

echo "-----Installing rust-----"
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source $HOME/.cargo/env
echo

echo "-----Installing rzup and RISC Zero toolchain-----"
curl -L https://risczero.com/install | bash
source $HOME/.bashrc
/root/.risc0/bin/rzup install
echo

echo "-----Installing bento components-----"
# Add PostgreSQL 16 repo
apt install -y lsb-release
sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgres.gpg
apt update

# Install all dependencies properly
apt install -y redis postgresql-16 adduser libfontconfig1 musl wget apt-transport-https ca-certificates gnupg lsb-release

wget https://dl.min.io/server/minio/release/linux-amd64/archive/minio_20250613113347.0.0_amd64.deb -O minio.deb
dpkg -i minio.deb

curl -L "https://zzno.de/boundless/grafana-enterprise_11.0.0_amd64.deb" -o grafana-enterprise_11.0.0_amd64.deb
dpkg -i grafana-enterprise_11.0.0_amd64.deb
apt --fix-broken install -y
echo

echo "-----Downloading prover binaries-----"
mkdir /app
curl -L "https://nishimiya.eu.org/boundless/agent" -o /app/agent
curl -L "https://nishimiya.eu.org/boundless/broker" -o /app/broker
curl -L "https://nishimiya.eu.org/boundless/prover" -o /app/prover
curl -L "https://nishimiya.eu.org/boundless/rest_api" -o /app/rest_api
curl -L "https://nishimiya.eu.org/boundless/stark_verify" -o /app/stark_verify
curl -L "https://nishimiya.eu.org/boundless/stark_verify.cs" -o /app/stark_verify.cs
curl -L "https://nishimiya.eu.org/boundless/stark_verify.dat" -o /app/stark_verify.dat
curl -L "https://nishimiya.eu.org/boundless/stark_verify_final.pk.dmp" -o /app/stark_verify_final.pk.dmp

chmod +x /app/agent
chmod +x /app/broker
chmod +x /app/prover
chmod +x /app/rest_api
chmod +x /app/stark_verify

echo "-----Installing CLI tools-----"
git clone https://github.com/rpslzero/boundless.git /root/boundless
cd /root/boundless
git submodule update --init --recursive
cargo install --git https://github.com/risc0/risc0 bento-client --branch release-2.3 --bin bento_cli --force
cargo install --path crates/boundless-cli --locked boundless-cli
echo

echo "-----Copying config files-----"
cp -rf dockerfiles/grafana/* /etc/grafana/provisioning/
cp .env.base /app/.env.base
cp .env.base-sepolia /app/.env.base-sepolia
cp .env.eth-sepolia /app/.env.eth-sepolia
echo

echo "-----Generating supervisord configuration file-----"
nvidia-smi -L
read -p "Please input the GPU ID you need to run according to the printed GPU information (e.g. 0,1 default 0): " GPU_IDS
GPU_IDS=${GPU_IDS:-0}

gpu_info=$(nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader)

MIN_SEGMENT_SIZE=22

while IFS=',' read -r index name memory; do
    if ! echo "$GPU_IDS" | grep -q "$index"; then
        continue
    fi

    memory_gb=$(echo "$memory" | tr -d ' MiB' | awk '{printf "%.2f", $1/1024}')
    
    if (( $(awk -v mem="$memory_gb" 'BEGIN{print (mem<16)?1:0}') )); then
        segment_size=19
    elif (( $(awk -v mem="$memory_gb" 'BEGIN{print (mem<20)?1:0}') )); then
        segment_size=20
    elif (( $(awk -v mem="$memory_gb" 'BEGIN{print (mem<40)?1:0}') )); then
        segment_size=21
    else
        segment_size=22
    fi
    
    if [ "$segment_size" -lt "$MIN_SEGMENT_SIZE" ]; then
        MIN_SEGMENT_SIZE=$segment_size
    fi
done <<< "$gpu_info"

echo "Based on GPU VRAM, the minimum SEGMENT_SIZE is: $MIN_SEGMENT_SIZE"

declare -A NETWORK_NAMES
NETWORK_NAMES["1"]="Eth Sepolia"
NETWORK_NAMES["2"]="Base Sepolia"
NETWORK_NAMES["3"]="Base Mainnet"
declare -A NETWORK_ENVS_FILE
NETWORK_ENVS_FILE["1"]="/app/.env.eth-sepolia"
NETWORK_ENVS_FILE["2"]="/app/.env.base-sepolia"
NETWORK_ENVS_FILE["3"]="/app/.env.base"

for id in $(for key in "${!NETWORK_NAMES[@]}"; do echo "$key"; done | sort -n); do
    echo "$id) ${NETWORK_NAMES[$id]}"
done

read -p "Please input the network you need to run (e.g. 1,2 default 1,2): " NETWORK_IDS
NETWORK_IDS=${NETWORK_IDS:-1,2}

IFS=',' read -ra NET_IDS <<< "$NETWORK_IDS"
declare -A NETWORK_RPC
declare -A NETWORK_PRIVKEY

for NET_ID in "${NET_IDS[@]}"; do
    NET_ID_TRIM=$(echo "$NET_ID" | xargs)
    NETWORK_NAME="${NETWORK_NAMES[$NET_ID_TRIM]}"
    read -p "Please input the RPC address of ${NETWORK_NAME}: " rpc
    read -p "Please input the private key of ${NETWORK_NAME}: " privkey
    NETWORK_RPC["$NET_ID_TRIM"]="$rpc"
    NETWORK_PRIVKEY["$NET_ID_TRIM"]="$privkey"
done

GPU_IDS_ARRAY=()
IFS=',' read -ra GPU_IDS_ARRAY <<< "$GPU_IDS"
GPU_AGENT_CONFIGS=""
for idx in "${!GPU_IDS_ARRAY[@]}"; do
    GPU_ID_TRIM=$(echo "${GPU_IDS_ARRAY[$idx]}" | xargs)
    GPU_AGENT_CONFIGS+="
[program:gpu_prove_agent${idx}]
command=/app/agent -t prove
directory=/app
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=50
stdout_logfile=/var/log/gpu_prove_agent${idx}.log
redirect_stderr=true
environment=DATABASE_URL=\"postgresql://worker:password@localhost:5432/taskdb\",REDIS_URL=\"redis://localhost:6379\",S3_URL=\"http://localhost:9000\",S3_BUCKET=\"workflow\",S3_ACCESS_KEY=\"admin\",S3_SECRET_KEY=\"password\",RUST_LOG=\"info\",RUST_BACKTRACE=\"1\",CUDA_VISIBLE_DEVICES=\"${GPU_ID_TRIM}\"
"
done

BROKER_CONFIGS=""
for NET_ID in "${NET_IDS[@]}"; do
    NET_ID_TRIM=$(echo "$NET_ID" | xargs)
    RPC_URL="${NETWORK_RPC[$NET_ID_TRIM]}"
    PRIVKEY="${NETWORK_PRIVKEY[$NET_ID_TRIM]}"
    ENV_FILE="${NETWORK_ENVS_FILE[$NET_ID_TRIM]}"
    BROKER_CONFIGS+="
[program:broker${NET_ID_TRIM}]
command=/bin/bash -c \"source ${ENV_FILE} && /app/broker --db-url sqlite:///db/broker${NET_ID_TRIM}.db --config-file /app/broker${NET_ID_TRIM}.toml --bento-api-url http://localhost:8081\"
directory=/app
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10800
priority=60
stdout_logfile=/var/log/broker${NET_ID_TRIM}.log
redirect_stderr=true
environment=RUST_LOG=\"info,broker=debug,boundless_market=debug\",PRIVATE_KEY=\"${PRIVKEY}\",RPC_URL=\"${RPC_URL}\",POSTGRES_HOST=\"localhost\",POSTGRES_DB=\"taskdb\",POSTGRES_PORT=\"5432\",POSTGRES_USER=\"worker\",POSTGRES_PASS=\"password\"
"
    cp broker.toml /app/broker${NET_ID_TRIM}.toml
done

cat <<EOF >/etc/supervisor/conf.d/boundless.conf
[supervisord]
nodaemon=false
logfile=/var/log/supervisord.log
pidfile=/var/run/supervisord.pid
loglevel=info
strip_ansi=true

[group:dependencies]
programs=redis,postgres,minio,grafana

[group:bento]
programs=exec_agent0,exec_agent1,exec_agent2,aux_agent,snark_agent,rest_api

[group:broker]
programs=

[program:redis]
command=/usr/bin/redis-server --port 6379
directory=/data/redis
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=10
stdout_logfile=/var/log/redis.log
redirect_stderr=true
environment=HOME="/data/redis"

[program:postgres]
command=/usr/lib/postgresql/16/bin/postgres -D /data/postgresql -c config_file=/etc/postgresql/16/main/postgresql.conf -p 5432
directory=/data/postgresql
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=20
stdout_logfile=/var/log/postgres.log
redirect_stderr=true
environment=POSTGRES_DB="taskdb",POSTGRES_USER="worker",POSTGRES_PASSWORD="password"
user=postgres

[program:minio]
command=/usr/local/bin/minio server /data --console-address ":9001"
directory=/data/minio
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=30
stdout_logfile=/var/log/minio.log
redirect_stderr=true
environment=MINIO_ROOT_USER="admin",MINIO_ROOT_PASSWORD="password",MINIO_DEFAULT_BUCKETS="workflow"

[program:grafana]
command=/usr/share/grafana/bin/grafana-server --homepath=/usr/share/grafana --config=/etc/grafana/grafana.ini
directory=/var/lib/grafana
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=40
stdout_logfile=/var/log/grafana.log
redirect_stderr=true
environment=GF_SECURITY_ADMIN_USER="admin",GF_SECURITY_ADMIN_PASSWORD="admin",GF_LOG_LEVEL="WARN",POSTGRES_HOST="localhost",POSTGRES_DB="taskdb",POSTGRES_PORT="5432",POSTGRES_USER="worker",POSTGRES_PASSWORD="password",GF_INSTALL_PLUGINS="frser-sqlite-datasource"

[program:exec_agent0]
command=/app/agent -t exec --segment-po2 $MIN_SEGMENT_SIZE
directory=/app
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=50
stdout_logfile=/var/log/exec_agent0.log
redirect_stderr=true
environment=DATABASE_URL="postgresql://worker:password@localhost:5432/taskdb",REDIS_URL="redis://localhost:6379",S3_URL="http://localhost:9000",S3_BUCKET="workflow",S3_ACCESS_KEY="admin",S3_SECRET_KEY="password",RUST_LOG="info",RUST_BACKTRACE="1",RISC0_KECCAK_PO2="17"

[program:exec_agent1]
command=/app/agent -t exec --segment-po2 $MIN_SEGMENT_SIZE
directory=/app
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=50
stdout_logfile=/var/log/exec_agent1.log
redirect_stderr=true
environment=DATABASE_URL="postgresql://worker:password@localhost:5432/taskdb",REDIS_URL="redis://localhost:6379",S3_URL="http://localhost:9000",S3_BUCKET="workflow",S3_ACCESS_KEY="admin",S3_SECRET_KEY="password",RUST_LOG="info",RUST_BACKTRACE="1",RISC0_KECCAK_PO2="17"

[program:exec_agent2]
command=/app/agent -t exec --segment-po2 $MIN_SEGMENT_SIZE
directory=/app
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=50
stdout_logfile=/var/log/exec_agent2.log
redirect_stderr=true
environment=DATABASE_URL="postgresql://worker:password@localhost:5432/taskdb",REDIS_URL="redis://localhost:6379",S3_URL="http://localhost:9000",S3_BUCKET="workflow",S3_ACCESS_KEY="admin",S3_SECRET_KEY="password",RUST_LOG="info",RUST_BACKTRACE="1",RISC0_KECCAK_PO2="17"

[program:aux_agent]
command=/app/agent -t aux --monitor-requeue
directory=/app
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=50
stdout_logfile=/var/log/aux_agent.log
redirect_stderr=true
environment=DATABASE_URL="postgresql://worker:password@localhost:5432/taskdb",REDIS_URL="redis://localhost:6379",S3_URL="http://localhost:9000",S3_BUCKET="workflow",S3_ACCESS_KEY="admin",S3_SECRET_KEY="password",RUST_LOG="info",RUST_BACKTRACE="1"

[program:snark_agent]
command=/bin/bash -c "ulimit -s 90000000 && /app/agent -t snark"
directory=/app
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=50
stdout_logfile=/var/log/snark_agent.log
redirect_stderr=true
environment=DATABASE_URL="postgresql://worker:password@localhost:5432/taskdb",REDIS_URL="redis://localhost:6379",S3_URL="http://localhost:9000",S3_BUCKET="workflow",S3_ACCESS_KEY="admin",S3_SECRET_KEY="password",RUST_LOG="info",RUST_BACKTRACE="1"
startretries=3

[program:rest_api]
command=/app/rest_api --bind-addr 0.0.0.0:8081 --snark-timeout 180
directory=/app
autostart=true
autorestart=true
startsecs=5
stopwaitsecs=10
priority=50
stdout_logfile=/var/log/rest_api.log
redirect_stderr=true
environment=DATABASE_URL="postgresql://worker:password@localhost:5432/taskdb",REDIS_URL="redis://localhost:6379",S3_URL="http://localhost:9000",S3_BUCKET="workflow",S3_ACCESS_KEY="admin",S3_SECRET_KEY="password",RUST_LOG="info",RUST_BACKTRACE="1"
EOF

cat <<EOF >>/etc/supervisor/conf.d/boundless.conf
$GPU_AGENT_CONFIGS
$BROKER_CONFIGS
EOF

GPU_AGENT_NAMES=$(echo "$GPU_AGENT_CONFIGS" | grep -oP '(?<=\[program:)[^]]+' | tr '\n' ' ')
BROKER_NAMES=$(echo "$BROKER_CONFIGS" | grep -oP '(?<=\[program:)[^]]+' | tr '\n' ' ')

sed -i "/^\[group:bento\]/{
    n
    s/^programs *=.*/&,$(echo $GPU_AGENT_NAMES | tr ' ' ',')/
}" /etc/supervisor/conf.d/boundless.conf

sed -i "/^\[group:broker\]/{
    n
    s/^programs *=.*/&$(echo $BROKER_NAMES | tr ' ' ',')/
}" /etc/supervisor/conf.d/boundless.conf

mkdir -p /data/redis
mkdir -p /data/postgresql
mkdir -p /data/minio
echo

echo "-----Starting dependencies services-----"
if ! pgrep -x "supervisord" > /dev/null; then
    supervisord -c /etc/supervisor/supervisord.conf
else
    echo "supervisord is already running, skipping start..."
fi
supervisorctl update
supervisorctl start dependencies:*
supervisorctl status
echo

echo "-----Initializing database-----"
curl -L "https://raw.githubusercontent.com/rpslzero/boundless-prover/refs/heads/main/initdb.sh" -o initdb.sh
chmod +x initdb.sh
./initdb.sh
mkdir /db
supervisorctl restart dependencies:postgres
echo

echo "-----Starting bento services-----"
supervisorctl start bento:*
supervisorctl status
echo

echo "Prover node setup complete"
echo "Please restart the console or run the following command"
echo "1. source $HOME/.cargo/env"
echo "2. source $HOME/.bashrc"

echo "Prover main directory: /app"
echo "Log directory: /var/log"
echo "Broker configuration file path: /app/broker*.toml"
echo "Supervisord configuration file path: /etc/supervisor/conf.d/boundless.conf"
echo
echo "Basic commands: "
echo "-----Running a Test Proof-----"
echo "RUST_LOG=info bento_cli -c 32"
echo 
echo "-----Prover benchmark-----"
echo "export RPC_URL=<TARGET_CHAIN_RPC_URL>"
echo "boundless proving benchmark --request-ids <IDS>"
echo 
echo "-----Deposit and Stake-----"
echo "export RPC_URL=<TARGET_CHAIN_RPC_URL>"
echo "export PRIVATE_KEY=<PRIVATE_KEY>"
echo "source /app/.env.<TARGET_CHAIN_NAME>"
echo "boundless account deposit-stake <USDC_TO_DEPOSIT>"
echo "boundless account stake-balance"
echo "boundless account withdraw-stake <AMOUNT_TO_WITHDRAW>"
echo
echo "-----Service management-----"
echo "Dependencies:"
echo "supervisorctl start dependencies:*"
echo "supervisorctl stop dependencies:*"
echo "supervisorctl restart dependencies:*"
echo "Bento:"
echo "supervisorctl start bento:*"
echo "supervisorctl stop bento:*"
echo "supervisorctl restart bento:*"
echo "Broker:"
echo "supervisorctl start broker:*"
echo "supervisorctl stop broker:*"
echo "supervisorctl restart broker:*"
