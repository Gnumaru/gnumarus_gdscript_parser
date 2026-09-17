#!/bin/bash

# curent directory of the current .sh file
#__DIR__=$(dirname "$0")
__DIR__="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
FILE=$__DIR__/test.gd
CMD="/sync/opt/godot/godot4.x86_64 --headless -s $FILE"
echo "executing \"$CMD\""
eval "$CMD"