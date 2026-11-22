VPal Server Command Center - the watchdog
=========================================

Unofficial fan tool. Not affiliated with, endorsed by or sponsored by Pocketpair, Inc.
Palworld is a trademark of Pocketpair, Inc.

What this folder is
-------------------
The background part of the VPal Server Command Center (the control panel). It has no window
and no web page: everything is shown and changed in the control panel, on its Watchdog,
Players, Backups and Discord tabs. It keeps working with the control panel closed.

Every 15 seconds it checks the server and steps in when needed:

  * Crash recovery     starts the server again when Windows or the game logged a crash
                       (if you close the server yourself, it stays off)
  * Freeze recovery    restarts the server when it is running but has stopped answering
  * Memory watchdog    restarts with an in-game warning when the server's memory gets too
                       high, and shows how fast it is growing
  * Safe starts        waits for the old server to let go of its ports before starting a
                       new one
  * Update check       spots a new Palworld server build on Steam and restarts to install it
  * Backups            zips the world every few hours and before restarts; restore any
                       backup (or one of the game's own) with a preview, and a safety copy
                       of the world is always made first
  * Players            who is online, everyone who has played (with playtime), kick, ban,
                       unban and a whitelist (players turned away by the whitelist are listed
                       so you can add them with one click)
  * Activity           joins, leaves, level-ups, restarts, crashes and backups
  * Welcome messages   for players who join
  * Pal Planner        keeps the planner's website running and on its newest version, and
                       feeds live player positions to the planner's map
  * Discord bot        alerts in a channel you pick (crashes, restarts, updates, and
                       optionally backups, joins and level-ups) and slash commands:
                       /status /players /playtime /planner for everyone, and
                       /restart /stop /start /backup /announce /kick /ban /unban for
                       people with Manage Server. Free: you create the bot yourself on
                       Discord's developer site; the Discord tab walks you through it.
  * VPal updates       checks VPal's GitHub page once a day. When a newer VPal is out, the control
                       panel shows an Update button: one click downloads it, checks it and puts it
                       in place while the game server keeps running. If anything can't be written,
                       every file is put back as it was. Your settings, worlds, backups, player
                       list and codes are never part of an update.
  * Self-updating      after an update, it restarts itself on the new version

It never fights you. It stands aside while:
  * you stopped the server from the control panel
  * the scheduled restart script (RestartServer.ps1) or SteamCMD is running
  * it is already doing something itself

How it is reached
-----------------
Only the control panel talks to it, on 127.0.0.1:18770 (this PC only). Requests that came
through a proxy or name another host are refused, and every change needs a header that web
pages cannot add. There is no phone admin page.

Discord slash commands come from Discord through your family link at /discord and are passed
to this PC on 127.0.0.1:18771. Every command must carry Discord's signature (Ed25519, checked
with your app's Public Key) or it is refused. The bot token stays in data\discord.json on this
PC and is never shown. The bot shows as offline in Discord's member list because it doesn't
keep a live connection open; it still answers. If the family link is turned off and on again,
the watchdog puts /discord back on it by itself within 5 minutes.

Files
-----
  service\ccservice.py   the background program (run with pythonw, no window)
  service\cc\            its parts
  service\lib\           psutil (BSD-3-Clause), for process and memory information
  service\vpal_updater.py  puts a VPal update in place while the watchdog is closed for a moment
  service\ui\            the control panel's look: VPalUi.cs (its custom-drawn controls), the
                         night backdrop and the icons, all original VPal art
  data\                  settings, activity log, player list, backups (made when it runs)
  data\updates\          the last VPal update's log, and a copy of each file it replaced

Starting it
-----------
The control panel sets it up and starts it by itself when you open the panel: a scheduled
task named "VPal Server Watchdog" starts it when you sign in and checks every 5 minutes that
it is still running. The Watchdog tab shows whether it is running and can start it.

Requirements: Windows 10/11, Python 3.9 or newer (64-bit; the control panel can install it),
and the server's REST API turned on (RESTAPIEnabled=True). The REST API only listens on
this PC. Never port-forward it.

Credits
-------
psutil - Copyright (c) 2009, Jay Loden, Dave Daeschler, Giampaolo Rodola. BSD-3-Clause.
Backup previews use the Pal Planner's save reader when it is installed.
