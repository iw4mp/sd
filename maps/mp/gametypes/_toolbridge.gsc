#include common_scripts\utility;

// Bridge between the vertu tool (native C++ menu) and this GSC mod.
//
// Every object the tool spawns this match is tracked in level.toolSpawned,
// a STRING-keyed map (key = "" + id) rather than a plain sequential
// integer-indexed array - live-tested and confirmed that assigning
// `undefined` into a sequential-index array slot on removal causes the
// remaining entries to shift/compact, silently invalidating every id the
// tool already knew about (removing one entry wiped the whole list).
// String keys sidestep that entirely: they're hashmap-style entries, not
// slots in a contiguous list. level.toolSpawnedIds is a SEPARATE,
// append-only array (ids only ever pushed, never removed) that exists
// purely to give updateSpawnedListDvar() a stable iteration order.
//
// The tool reads the current list via the "tool_spawn_list" dvar
// ("id:modelName;id:modelName;..."), which this file rebuilds after every
// spawn/remove.
//
// Commands the tool fires as console commands (set <dvar> "..."):
//   tool_spawn_cmd  "<localClientIndex>|<xmodelName>" - spawn at that
//                                                        player's crosshair
//   tool_move_cmd   "<id>|<dx> <dy> <dz>"             - nudge object <id>
//   tool_remove_cmd "<id>"                             - delete object <id>

init()
{
	level.toolSpawned = [];
	level.toolSpawnedIds = [];
	level.toolClientTeams = [];
	level.toolRoundSwitchInitialized = false;
	level thread pollSpawnRequests();
	level thread pollMoveRequests();
	level thread pollRemoveRequests();
	level thread onPlayerConnect();
	level thread autoKickNonPartyTeammates();
}

// GSC-side, automatic equivalent of the tool's manual "Kick Non-Party
// Teammates" button (Game::Hooks::KickNonPartyTeammates) - so this doesn't
// need a click every time a random lands on the party's own team. Polls
// instead of reacting to connect/joined_team events, since team membership
// can shift any time via this file's own balancing (getTeamAssignment in
// _menus.gsc), not just on connect.
//
// The party's team is whatever team any current party member (per
// isToolPartyMember - "tool_party_clients", published by the tool's
// PublishPartyClientsDvar) is actually on. Kicks at most ONE non-party
// player per second, one endpoint at a time - kicking multiple clients
// back-to-back was confirmed to crash the game natively (see the tool's own
// 500ms KickCooldownMs), so this stays conservative even though GSC's
// kick() is a different code path.
autoKickNonPartyTeammates()
{
	level endon( "game_ended" );

	for ( ;; )
	{
		wait 1;

		partyTeam = undefined;
		foreach ( player in level.players )
		{
			if ( !maps\mp\gametypes\_menus::isToolPartyMember( player ) )
				continue;
			if ( !isDefined( player.pers["team"] ) || player.pers["team"] == "spectator" )
				continue;

			partyTeam = player.pers["team"];
			break;
		}

		if ( !isDefined( partyTeam ) )
			continue;

		foreach ( player in level.players )
		{
			if ( maps\mp\gametypes\_menus::isToolPartyMember( player ) )
				continue;
			if ( !isDefined( player.pers["team"] ) || player.pers["team"] != partyTeam )
				continue;

			logKickToTool( "autoKickNonPartyTeammates: kicking " + player.name + " (client " + player getEntityNumber() + ") - not a party member on team " + partyTeam );
			kick( player getEntityNumber(), "EXE_SERVERISFULL" );
			break;
		}
	}
}

// Visible on-screen confirmation that the mod actually loaded - same
// connect/spawn hook pattern every other gametype file uses (e.g.
// _friendicons.gsc), firing maps\mp\gametypes\_hud_message::hintMessage()
// each time a player spawns.
onPlayerConnect()
{
	for ( ;; )
	{
		level waittill( "connected", player );
		player thread onPlayerSpawned();
		player thread enforceMaxPlayers();
		player thread watchAndPublishTeam();
	}
}

// Reports this player's resolved team back to the native tool via the
// "tool_client_teams" dvar ("<clientIndex>:<team>;<clientIndex>:<team>;...",
// rebuilt on every joined_team). The tool's AutoAssignNewTeams still fires
// the menuresponse/autoassign notify for party members (same as its old
// pre-mod logic, since party members never trigger that on their own - see
// getTeamAssignment() above), but can no longer just hardcode team=1 for
// all of them now that this file balances/groups by count and party
// membership itself - it reads this dvar instead, to mirror the NATIVE
// session-team field (client->sess.cs.team, the one that actually governs
// hostility/scoreboard/killfeed) to whatever team THIS function actually
// assigned, rather than fighting it with a fixed value.
watchAndPublishTeam()
{
	self endon( "disconnect" );

	for ( ;; )
	{
		self waittill( "joined_team" );
		publishClientTeam( self );
	}
}

publishClientTeam( player )
{
	level.toolClientTeams[ "" + player getEntityNumber() ] = player.pers["team"];

	list = "";
	foreach ( clientIndex, team in level.toolClientTeams )
	{
		list += clientIndex + ":" + team + ";";
	}
	setDvar( "tool_client_teams", list );
}

// Actually caps match size, unlike the game's own "Max Players" rules
// slider (ui_maxplayers/party_maxplayers/sv_maxplayers) - ui_maxplayers
// just feeds the local scoreboard's cosmetic slot count
// (maps\mp\_scoreboard.gsc), none of the three actually stop this build's
// Steam connect flow from accepting more players. GSC can't refuse a
// connection outright (that's decided natively before this even runs), so
// this is a post-connect kick: whoever just pushed the server over the
// tool's own dedicated "tool_max_players" dvar (a separate slider in the
// tool's UI - see Game::Hooks::ApplyGscMaxPlayersChange - that talks
// directly to this mod instead of the game's broken one) gets removed
// immediately.
enforceMaxPlayers()
{
	// _playerlogic.gsc's own Callback_PlayerConnect (reacting to this same
	// "connected" notify) does a waittillframeend BEFORE adding the newly
	// connected player to level.players ("give any threads waiting on the
	// connected notify a chance to process before we are added to
	// level.players"). Without matching that here, this check ran against
	// the COUNT BEFORE this connect - always one short, so the kick never
	// fired at the actual moment the cap was exceeded (confirmed live:
	// nobody ever got kicked).
	waittillframeend;

	maxPlayers = getDvarInt( "tool_max_players" );
	if ( !maxPlayers )
		return;

	if ( level.players.size > maxPlayers )
	{
		logKickToTool( "enforceMaxPlayers: kicking " + self.name + " (client " + self getEntityNumber() + ") - " + level.players.size + " players > max " + maxPlayers );
		kick( self getEntityNumber(), "EXE_SERVERISFULL" );
	}
}

// println()/print() only reach the GAME ENGINE's own server console, not
// the tool's separate AllocConsole() window (the same reason HkEnginePrint
// had to be hooked just to surface the GSC compile-error message there) -
// this instead publishes the message via "tool_kick_log", which the tool
// polls and printf()s every frame (see Game::Hooks::PollGscKickLog),
// clearing it back to "" once read so the same message doesn't repeat.
logKickToTool( message )
{
	setDvar( "tool_kick_log", message );
}

// Same bridge as logKickToTool above, separate dvar so debug spam doesn't
// clobber/get clobbered by actual kick log lines - see
// Game::Hooks::PollGscDebugLog.
logDebugToTool( message )
{
	setDvar( "tool_debug_log", message );
}

onPlayerSpawned()
{
	self endon( "disconnect" );

	for ( ;; )
	{
		self waittill( "spawned_player" );

		enforceEnemyPerkRestrictions( self );

		// Fires once, at whichever party member spawns first - by then
		// team assignment (getTeamAssignment in _menus.gsc) has already
		// settled, same timing the old tool used natively (host's own
		// first post-spawn hook).
		if ( !level.toolRoundSwitchInitialized && maps\mp\gametypes\_menus::isToolPartyMember( self ) )
		{
			level.toolRoundSwitchInitialized = true;
			initRoundSwitchExploit();
		}
	}
}

// Ensures the party's team becomes the planting/attacking side within at
// most 2 rounds and then stays that way for the rest of the map - same
// logic and same stock dvars (scr_sd_roundswitch/scr_sd_planttime) the old
// 32-bit tool used natively (ExploitManager.cpp's post-spawn hook +
// WrapperManager.cpp's round_win state machine), reimplemented here in GSC.
//
// Every SND map has a fixed default attacking side baked into its own
// layout (bomb sites/spawns aren't symmetric) - getBombTeamForMap below is
// the same per-map table the old tool used natively. If the party's team
// already matches that default, nothing needs to change (roundswitch=0,
// stock planttime=5). Otherwise: force a round switch after every single
// round (roundswitch=1) and a very long planttime (60s vs. the normal 5s)
// for round 1, so it's effectively impossible for the actual attacking
// team to plant in time - by the time round 1 ends, sides swap and the
// party is now attacking. Since roundswitch=1 would keep swapping every
// round after that too, watchRoundSwitchExploit locks scr_sd_roundswitch
// back to 0 (never switch again) once round 2 also ends.
initRoundSwitchExploit()
{
	partyTeam = undefined;
	foreach ( player in level.players )
	{
		if ( !maps\mp\gametypes\_menus::isToolPartyMember( player ) )
			continue;
		if ( !isDefined( player.pers["team"] ) || player.pers["team"] == "spectator" )
			continue;

		partyTeam = player.pers["team"];
		break;
	}

	mapName = getdvar( "mapname" );

	if ( !isDefined( partyTeam ) )
	{
		logDebugToTool( "initRoundSwitchExploit: no partyTeam found (mapname=" + mapName + ") - aborting" );
		return;
	}

	bombTeam = getBombTeamForMap( mapName );
	if ( !isDefined( bombTeam ) )
	{
		logDebugToTool( "initRoundSwitchExploit: no bombTeam entry for mapname=" + mapName + " - aborting" );
		return;
	}

	logDebugToTool( "initRoundSwitchExploit: mapname=" + mapName + " partyTeam=" + partyTeam + " bombTeam=" + bombTeam );

	if ( partyTeam == bombTeam )
	{
		logDebugToTool( "initRoundSwitchExploit: party already on bomb team - roundswitch=0, planttime=5" );
		setDvar( "scr_sd_roundswitch", 0 );
		setDvar( "scr_sd_planttime", 5 );
		level.toolRoundSwitchState = 2;
	}
	else
	{
		logDebugToTool( "initRoundSwitchExploit: party is defending - roundswitch=1, planttime=60, arming watchRoundSwitchExploit" );
		setDvar( "scr_sd_roundswitch", 1 );
		setDvar( "scr_sd_planttime", 60 );
		level.toolRoundSwitchState = 0;
		level thread watchRoundSwitchExploit();
	}
}

// Only armed when the party started out defending (see initRoundSwitchExploit
// above) - fires on every "round_win" (_gamelogic.gsc's displayRoundEnd
// notifies this the instant a round is decided). Same event the old 32-bit
// tool hooked natively (WrapperManager.cpp's VM_Notify handler,
// !strcmp(Notify, "round_win")) - critically, this fires BEFORE
// checkRoundSwitch()/onRoundSwitch() run for that round's transition, so
// locking scr_sd_roundswitch back to 0 here takes effect before the engine
// evaluates whether to swap sides again.
watchRoundSwitchExploit()
{
	level endon( "game_ended" );

	for ( ;; )
	{
		level waittill( "round_win", winner );

		logDebugToTool( "watchRoundSwitchExploit: \"round_win\" fired (winner=" + winner + "), state=" + level.toolRoundSwitchState + " roundsPlayed=" + game["roundsPlayed"] + " scr_sd_roundswitch=" + getdvar( "scr_sd_roundswitch" ) );

		if ( level.toolRoundSwitchState == 0 )
		{
			setDvar( "scr_sd_planttime", 60 );
			level.toolRoundSwitchState = 1;
		}
		else if ( level.toolRoundSwitchState == 1 )
		{
			logDebugToTool( "watchRoundSwitchExploit: locking scr_sd_roundswitch=0, planttime=5" );
			setDvar( "scr_sd_roundswitch", 0 );
			setDvar( "scr_sd_planttime", 5 );
			level.toolRoundSwitchState = 2;
			return;
		}
	}
}

// Same per-map "which team plants by default" table the old 32-bit tool
// used natively (ExploitManager.cpp's switchRoundMap) - each SND map has a
// fixed default attacking side baked into its own layout.
getBombTeamForMap( mapName )
{
	map = [];
	map[ "mp_afghan" ] = "axis";
	map[ "mp_derail" ] = "allies";
	map[ "mp_estate" ] = "axis";
	map[ "mp_favela" ] = "allies";
	map[ "mp_highrise" ] = "allies";
	map[ "mp_invasion" ] = "allies";
	map[ "mp_checkpoint" ] = "allies";
	map[ "mp_quarry" ] = "allies";
	map[ "mp_rundown" ] = "allies";
	map[ "mp_rust" ] = "axis";
	map[ "mp_boneyard" ] = "allies";
	map[ "mp_nightshift" ] = "allies";
	map[ "mp_subbase" ] = "axis";
	map[ "mp_terminal" ] = "axis";
	map[ "mp_underpass" ] = "allies";
	map[ "mp_brecourt" ] = "axis";
	map[ "mp_complex" ] = "axis";
	map[ "mp_crash" ] = "allies";
	map[ "mp_overgrown" ] = "allies";
	map[ "mp_compact" ] = "axis";
	map[ "mp_storm" ] = "allies";
	map[ "mp_abandon" ] = "axis";
	map[ "mp_fuel2" ] = "axis";
	map[ "mp_strike" ] = "axis";
	map[ "mp_trailerpark" ] = "axis";
	map[ "mp_vacant" ] = "allies";

	if ( isDefined( map[ mapName ] ) )
		return map[ mapName ];

	return undefined;
}

// Enemies (non-party) can't be given Last Stand/"Eliminator" (the deathstreak
// version - dying but staying up with a pistol), Ninja, or Cold-Blooded -
// same restriction and same substitute perks the old 32-bit tool enforced
// natively (RemovalManager.cpp's PlayerCmd_SetPerk hook, the "enemy" branch
// gated on !IsOnSameTeamByNumber), reimplemented here since GSC has no
// equivalent low-level SetPerk intercept. Checked on every spawn instead of
// pre-emptively at loadout-apply time (GSC's only real hook point here), so
// there's a brief same-frame window where the real perk is technically set
// before this corrects it - imperceptible in practice.
enforceEnemyPerkRestrictions( player )
{
	if ( maps\mp\gametypes\_menus::isToolPartyMember( player ) )
	{
		logDebugToTool( "enforceEnemyPerkRestrictions: " + player.name + " IS a party member, skipping" );
		return;
	}

	swaps = [];
	swaps[ "specialty_coldblooded" ] = "specialty_explosivedamage";
	swaps[ "specialty_pistoldeath" ] = "specialty_extendedmelee";
	swaps[ "specialty_heartbreaker" ] = "specialty_extendedmelee";
	swaps[ "specialty_quieter" ] = "specialty_falldamage";
	swaps[ "specialty_laststandoffhand" ] = "specialty_falldamage";
	swaps[ "specialty_finalstand" ] = "specialty_copycat";
	swaps[ "specialty_grenadepulldeath" ] = "specialty_copycat";

	heldPerks = "";
	foreach ( perkName, perkValue in player.perks )
		heldPerks += perkName + ",";
	logDebugToTool( "enforceEnemyPerkRestrictions: checking " + player.name + " (enemy) - self.perks = [" + heldPerks + "]" );

	toSwap = [];
	foreach ( perkName, replacement in swaps )
	{
		if ( player maps\mp\_utility::_hasPerk( perkName ) )
			toSwap[ toSwap.size ] = perkName;
	}

	foreach ( perkName in toSwap )
	{
		logDebugToTool( "enforceEnemyPerkRestrictions: swapping " + perkName + " -> " + swaps[ perkName ] + " on " + player.name );
		player maps\mp\_utility::_unsetPerk( perkName );
		player maps\mp\_utility::_setPerk( swaps[ perkName ] );
	}
}

pollSpawnRequests()
{
	level endon( "game_ended" );

	while ( 1 )
	{
		wait 0.1;

		cmd = getDvar( "tool_spawn_cmd" );
		if ( cmd == "" )
			continue;

		setDvar( "tool_spawn_cmd", "" );

		tokens = strtok( cmd, "|" );
		if ( tokens.size < 2 )
			continue;

		clientIndex = int( tokens[ 0 ] );
		modelName = tokens[ 1 ];

		requester = undefined;
		foreach ( player in level.players )
		{
			if ( player getEntityNumber() == clientIndex )
			{
				requester = player;
				break;
			}
		}
		if ( !isDefined( requester ) )
			continue;

		requester thread spawnAtCrosshair( modelName );
	}
}

spawnAtCrosshair( modelName )
{
	eye = self getEye();
	forward = anglestoforward( self getPlayerAngles() );
	end = eye + vector_multiply( forward, 10000 );
	trace = bulletTrace( eye, end, false, self );

	// Push off the hit surface along its normal - many xmodels have their
	// origin/pivot at their center rather than their base, so spawning
	// exactly on the trace hit point can bury half the model in whatever
	// it was placed against. The tool's move buttons cover the rest.
	spawnPos = trace[ "position" ] + vector_multiply( trace[ "normal" ], 16 );

	ent = spawn( "script_model", spawnPos );
	ent setModel( modelName );
	ent solid();

	// Plain .solid() alone does nothing for most xmodels - the stock
	// airdrop crate (maps/mp/killstreaks/_airdrop.gsc) never calls it at
	// all and gets its real collision purely from cloning a level-placed
	// collision brushmodel ("care_package" targetname, present on every
	// MP map) onto itself. It's a fixed box shape, not a per-model fit,
	// but it's the same mechanism other mod menus use to make spawned
	// crates/platforms solid, and it's the only generic collision source
	// available without per-model authored collmap data.
	if ( isDefined( level.airDropCrateCollision ) )
	{
		ent CloneBrushmodelToScriptmodel( level.airDropCrateCollision );
	}

	ent.toolModelName = modelName;

	id = level.toolSpawnedIds.size;
	level.toolSpawned[ "" + id ] = ent;
	level.toolSpawnedIds[ level.toolSpawnedIds.size ] = id;

	updateSpawnedListDvar();

	self iPrintLnBold( "Spawned #" + id + ": " + modelName );
}

pollMoveRequests()
{
	level endon( "game_ended" );

	while ( 1 )
	{
		wait 0.1;

		cmd = getDvar( "tool_move_cmd" );
		if ( cmd == "" )
			continue;

		setDvar( "tool_move_cmd", "" );

		tokens = strtok( cmd, "|" );
		if ( tokens.size < 2 )
			continue;

		key = "" + int( tokens[ 0 ] );
		if ( !isDefined( level.toolSpawned[ key ] ) )
			continue;

		vecTokens = strtok( tokens[ 1 ], " " );
		if ( vecTokens.size < 3 )
			continue;

		offset = ( int( vecTokens[ 0 ] ), int( vecTokens[ 1 ] ), int( vecTokens[ 2 ] ) );
		level.toolSpawned[ key ].origin += offset;
	}
}

pollRemoveRequests()
{
	level endon( "game_ended" );

	while ( 1 )
	{
		wait 0.1;

		cmd = getDvar( "tool_remove_cmd" );
		if ( cmd == "" )
			continue;

		setDvar( "tool_remove_cmd", "" );

		key = "" + int( cmd );
		if ( !isDefined( level.toolSpawned[ key ] ) )
			continue;

		level.toolSpawned[ key ] delete();
		level.toolSpawned[ key ] = undefined;

		updateSpawnedListDvar();
	}
}

updateSpawnedListDvar()
{
	list = "";
	for ( i = 0; i < level.toolSpawnedIds.size; i++ )
	{
		id = level.toolSpawnedIds[ i ];
		key = "" + id;
		if ( !isDefined( level.toolSpawned[ key ] ) )
			continue;

		list += id + ":" + level.toolSpawned[ key ].toolModelName + ";";
	}
	setDvar( "tool_spawn_list", list );
}
