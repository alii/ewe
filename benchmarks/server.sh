#!/usr/bin/env bash

echo "Running ewe server..."
cd ewe && gleam run -m app & sleep 1

echo "Running benchmarks..."
sleep 275

echo "Killing ewe server..."
kill $(lsof -t -i:8080)