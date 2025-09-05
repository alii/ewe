tests:
	docker run -it --rm \
  -v "${PWD}/config:/config" \
  -v "${PWD}/reports:/reports" \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /config/config.json
  kill $$(lsof -t -i:8080)

gl:
	gleam run -m autobahn