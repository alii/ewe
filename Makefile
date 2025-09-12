autobahn_test_dev:
	gleam run -m autobahn & sleep 1

	docker run -it --rm \
  -v "${PWD}/autobahn/config_dev.json:/autobahn.json" \
  -v "${PWD}/autobahn:/reports" \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /autobahn.json

	kill $$(lsof -t -i:8080)

autobahn_test_prod:
	gleam run -m autobahn & sleep 1

	docker run -it --rm \
  -v "${PWD}/autobahn/config_prod.json:/autobahn.json" \
  -v "${PWD}/autobahn:/reports" \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /autobahn.json

	kill $$(lsof -t -i:8080)