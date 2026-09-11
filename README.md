# pafo

An Ashita v4 addon that watches what drops while you play and sends it to
[PSXI](https://www.psxi.gg), so everyone gets real drop rates instead of
guesses. It records:

- mob kills and what landed in the treasure pool
- battlefield armoury crates
- Steal and Despoil results (yours, plus other players' successful steals)

It also works out your Treasure Hunter level, since that changes the odds.

## Install

Copy this folder into your Ashita `addons` folder as `pafo`, or link it with:

```
powershell -File tools\install.ps1 -Ashita <path to your Ashita install>
```

Then in game:

```
/addon load pafo
/pafo login
```

Login opens psxi.gg in your browser. Sign in, type the code the addon
printed, and you're set. pafo figures out which server you're on by itself,
and if it can't tell, it doesn't record anything.

## Commands

```
/pafo login            link this install to your PSXI account
/pafo logout           forget the token
/pafo status           what's queued, which server, whether you're linked
/pafo off | on         pause or resume recording
/pafo config           settings window (saved TH answers, link state)
/pafo th reset [name]  forget saved TH answers (one player, or everyone)
```

Nothing is sent until you're linked, the server is known and enabled on
PSXI, and recording is on. Reports go out in batches about once a minute. If
PSXI can't be reached they wait on disk and go out later.

## What gets recorded

- **Kills.** When a mob your party or alliance claimed dies, pafo records
  what dropped into the pool (including nothing) and the TH level. Kills it
  only saw part of, like after zoning or reloading the addon mid-fight, are
  thrown out so they can't skew the numbers.
- **Treasure Hunter.** On 75 THF it reads your gear. If another THF in the
  party is doing the work, it asks you once what tier they have and
  remembers the answer.
- **Battlefields.** Opening the armoury crate records the loot and gil. Zone
  out before the window closes and it's sent as a partial run.
- **Steal and Despoil.** Your own attempts, successful or not, plus other
  players' successful steals, since the item is what tells us a monster's
  steal table.

Settings, your token, and any unsent reports live in
`<Ashita>\config\addons\pafo\`.

## Development

Tests run on LuaJIT, same as Ashita:

```
luajit tests/run.lua            # everything
luajit tests/run.lua th_test    # one file
```

There's a fake PSXI server for testing without touching the real one. Point
the addon at it by changing `DEFAULT_BASE_URL` in `ashita/store.lua` to
`http://127.0.0.1:8787` (just don't commit that), then:

```
python tools/mock_server.py 8787
/addon reload pafo
/pafo login
curl http://127.0.0.1:8787/mock/approve
```

The top of `tools/mock_server.py` lists the switches for failure testing
(deny the login, force errors, time out, and so on).

Everything with real logic lives in `core/` as plain Lua with no Ashita
dependencies, which keeps it testable. `ashita/` has the thin parts that
talk to the game, and `pafo.lua` wires it together.

One thing to know before touching networking: Ashita tasks run on the game
thread, so anything that blocks freezes the client. `ashita/transport.lua`
uses non-blocking sockets and yields a frame whenever it's waiting. Wait with
`coroutine.sleep`, never `socket.sleep`, and don't use LuaSocket's
`http.request`, which can't yield.

To rebuild the battlefield name table from a LandSandBoat checkout:

```
python tools/gen_battlefields.py <path to a LandSandBoat checkout>
```

`SPEC.md` has the full protocol between the addon and PSXI.
