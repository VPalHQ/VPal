Pal Planner
===========
Part of the VPal Server Command Center. Everything is run from the Pal Planner tab of the
control panel. You never need to open anything in this folder.

What is in here
  web\           The page everyone opens. Only locked data is in here, plus site.json
                 (the page's name, who to ask for a code and the egg hatching time).
  engine\        Reads the world save and builds each person's planner.
                 webserver.py shows the web folder to this PC only; Tailscale passes the family link to it.
  players.json   Who gets a planner, their code, phone and email. Private: stays on this PC.
  site-settings.json  The page's name and your name, set on the Pal Planner tab.
  cache\         Last build for each player. Private: stays on this PC.
  status.json    Result of the last update (shown on the Pal Planner tab).
  refresh-log.txt  What happened on each update, if something goes wrong.

Credits and licenses for the game data and the save reader are in engine\licenses. Some game data
(recipes, technology, schematic drops, map data) is based on Arkive by Yihao Liu (tc-imba), CC BY-NC 4.0:
non-commercial use only.
Unofficial fan tool. Not affiliated with Pocketpair.
