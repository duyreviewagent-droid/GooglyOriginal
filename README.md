# GooglyOriginal

A wobbly 3D jelly platformer for macOS: you are a jelly bean with googly eyes. Collect junk, spit it at grumpy cubes,
pigeons and toasters, and flush yourself down the golden toilet. Eyes are your health.

- **Solo** or **couch co-op** for up to 4 players on one Mac (two keyboard layouts + game controllers)
- **Online** for up to 4 players: press **O** on the title, **H** to host a lobby (you get a 4-letter code), **J** to join with a code,
  or pick an open lobby. Friends can join mid-game.
- The player furthest ahead wears the crown; anyone far behind can **teleport to the leader**.

## Build the Mac app

Needs only the Xcode Command Line Tools:

```sh
./build.sh
open GooglyOriginal.app
```

Self-tests: `GooglyOriginal.app/Contents/MacOS/GooglyOriginal --autotest --mute --bot --players=4`

## Online server

`server/` is a tiny Node lobby + relay server (the host's Mac runs the game world; the server only matches lobbies and
relays messages). It deploys to Render from `render.yaml` as the `googlyoriginal` web service.

```sh
cd server && npm install && npm start      # http://localhost:8000 · ws://localhost:8000/ws
GooglyOriginal.app/Contents/MacOS/GooglyOriginal --server ws://localhost:8000/ws
```

The app connects to `wss://googlyoriginal.onrender.com/ws` by default.
