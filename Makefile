autobahn_test:
	gleam run -m autobahn & sleep 2

	docker run -it --rm \
  -v "${PWD}/autobahn/config.json:/autobahn.json" \
  -v "${PWD}/autobahn:/reports" \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /autobahn.json

	kill $$(lsof -t -i:8080)

autobahn_docker:
	docker run -it --rm \
  -v "${PWD}/autobahn/config.json:/autobahn.json" \
  -v "${PWD}/autobahn:/reports" \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /autobahn.json