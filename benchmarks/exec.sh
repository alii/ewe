#!/usr/bin/env bash

target=http://0.0.0.0:8080

h2load --h1 --no-tls-proto=http/1.1 -D 30 "$target/hello" -t 12 -c 12 > "_output/ewe.txt"