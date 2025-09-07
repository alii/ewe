autobahn_test:
	docker run -it --rm \
  -v "${PWD}/autobahn.json:/autobahn.json" \
  -v "${PWD}/autobahn:/reports" \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /autobahn.json