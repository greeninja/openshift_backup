#!/bin/bash

[ ! -z "$1" ] && exec $1

echo "starting to sleep"
while [ 1 ]; do
  sleep 30s
done

echo "im awake"
