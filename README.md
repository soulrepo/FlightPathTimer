# FlightPathTimer

Flight path times for the octowow 1.12 client (Interface 11200).

- **Flight map tooltip:** hovering a destination shows its flight time and number of stops.
  Times you have flown in that exact direction show in blue. Times worked out from the game's
  own flight path data show in white. Anything else is a grey `~estimate`: the return flight's
  time, a FlightTracker time, or the route length on the map.
- **In-flight timer:** a small bar with the destination and a countdown. On a route with no
  recorded time it counts up instead. Survives `/reload` mid-flight.
- **Learns as you fly:** every landed flight is saved, and so is the real time of each leg.
  The server doesn't always fly the path the game data describes (Stormwind to Ironforge is
  about 40 seconds shorter), so learned leg times replace the data for every route that uses
  them. A multi-stop flight teaches its legs when all but one are already known, or in one go
  with SuperWoW, which lets the addon see when you pass each stop. Times recorded by the
  FlightTracker addon are used as estimates.

## Install

Copy (or symlink) the `FlightPathTimer` folder into `Interface/AddOns/`.

If FlightTracker is also enabled, both will add a line to the tooltip and show a timer;
disable one of them.

## Commands

`/fpt` shows the number of recorded routes. Also:
`lock`, `unlock` (drag the timer to move it), `test`, `hide`, `toggle` (timer on/off),
`verbose` (message on landing), `reset` (forget recorded times).

## Flight path data

`FlightPathData.lua` holds the length of every flight leg, taken from the client's
`TaxiNodes`, `TaxiPath` and `TaxiPathNode` tables (the full 3D waypoints of each route) and
divided by the taxi speed of 32 yards per second. Checked against recorded flights, single
legs land within about 1%.

To regenerate it after a client patch:

```
python3 tools/mpq_extract.py <wow>/Data dbc 'DBFilesClient\TaxiNodes.dbc' 'DBFilesClient\TaxiPath.dbc' 'DBFilesClient\TaxiPathNode.dbc'
python3 tools/gen_data.py dbc FlightPathData.lua
```
