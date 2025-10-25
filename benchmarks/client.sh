#!/usr/bin/env bash

threads=(1 2 4 6 8 10 12 14 16)
target=http://0.0.0.0:8080

# ewe
echo "Slight delay to let ewe server start..."
sleep 4

echo "Running ewe benchmarks..."
for thread in "${threads[@]}"; do
  echo "$thread threads, $(($thread * 2)) total connections..."
  h2load --h1 --no-tls-proto=http/1.1 -D 30 "$target/hello" -t $thread -c $(($thread * 2)) > "_output/ewe_$thread.txt"
done
