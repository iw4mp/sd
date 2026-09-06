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
	level thread pollSpawnRequests();
	level thread pollMoveRequests();
	level thread pollRemoveRequests();
	level thread onPlayerConnect();
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
	}
}

// Forces the "Max Players" rules slider to actually cap match size. That
// slider only ever writes ui_maxplayers/party_maxplayers/sv_maxplayers -
// ui_maxplayers just feeds the local scoreboard's cosmetic slot count
// (maps\mp\_scoreboard.gsc), none of the three actually stop this build's
// Steam connect flow from accepting more players. GSC can't refuse a
// connection outright (that's decided natively before this even runs), so
// this is a post-connect kick: whoever just pushed the server over
// party_maxplayers gets removed immediately.
enforceMaxPlayers()
{
	maxPlayers = getDvarInt( "party_maxplayers" );
	if ( !maxPlayers )
		return;

	if ( level.players.size > maxPlayers )
		kick( self getEntityNumber(), "Server is full" );
}

onPlayerSpawned()
{
	self endon( "disconnect" );

	for ( ;; )
	{
		self waittill( "spawned_player" );

		self thread maps\mp\gametypes\_hud_message::hintMessage( "^2Vertu SND Loaded" );
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
