# FlightPathTimer

Flight path times for the octowow 1.12 client (Interface 11200).

- **Flight map tooltip:** hovering a destination shows its flight time and number of stops.
  Times you have flown in that exact direction show in blue. Everything else is a grey
  `~estimate`: the return flight's time, a FlightTracker time, or the route length on the map.
- **In-flight timer:** a small bar with the destination and a countdown. On a route with no
  recorded time it counts up instead. Survives `/reload` mid-flight.
- **Learns as you fly:** every landed flight is saved, and its speed tunes the estimates for
  the rest of that continent. Times recorded by the FlightTracker addon are used as estimates.

## Install

Copy (or symlink) the `FlightPathTimer` folder into `Interface/AddOns/`.

If FlightTracker is also enabled, both will add a line to the tooltip and show a timer;
disable one of them.

## Commands

`/fpt` shows the number of recorded routes. Also:
`lock`, `unlock` (drag the timer to move it), `test`, `hide`, `toggle` (timer on/off),
`verbose` (message on landing), `reset` (forget recorded times).
