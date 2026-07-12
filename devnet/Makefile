# Local Ethereum PoS network + archive node  -  operator entry points.

.PHONY: setup genesis up down clean status verify traffic test-rpc logs

## one-time: node identities, jwt secrets, .env
setup:
	node scripts/gen-identities.mjs

## one-time genesis ceremony (refuses to rerun; make clean first to redo)
genesis:
	./scripts/genesis.sh

## start both client pairs
up:
	docker compose up -d
	@echo "besu RPC http://localhost:8545 | archive(geth) RPC http://localhost:8547 | teku REST http://localhost:5051"

down:
	docker compose down

## full reset: containers + volumes + generated genesis
clean:
	docker compose down -v
	rm -f config/genesis.ssz

## heads of both ELs + consensus slot
status:
	@echo -n "besu head:    "; curl -s -X POST -H 'content-type: application/json' -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8545 | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["result"],16))'
	@echo -n "archive head: "; curl -s -X POST -H 'content-type: application/json' -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8547 | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["result"],16))'
	@echo -n "CL slot:      "; curl -s http://localhost:5051/eth/v1/beacon/headers/head | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"]["header"]["message"]["slot"])'

## prove the archive property
verify:
	./scripts/verify-archive.sh

## send transfers so historical state differs across heights
traffic:
	./scripts/send-traffic.sh

## acceptance test of the archive JSON-RPC surface, through the gateway
test-rpc:
	./scripts/test-rpc.sh

## monitoring URLs + a live tip-lag snapshot
monitor:
	@echo "Grafana:    http://localhost:3001 (anon viewer; admin/admin)"
	@echo "Prometheus: http://localhost:9091"
	@echo -n "archive tip lag (blocks): "; curl -s -X POST -H 'content-type: application/json' -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8545 | python3 -c 'import sys,json;v=int(json.load(sys.stdin)["result"],16);print(v)' >/tmp/_b 2>/dev/null; b=$$(cat /tmp/_b); a=$$(curl -s -X POST -H 'content-type: application/json' -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' http://localhost:8547 | python3 -c 'import sys,json;print(int(json.load(sys.stdin)["result"],16))'); echo $$((b-a))

logs:
	docker compose logs -f --tail=20 besu teku prysm-validator geth lighthouse
