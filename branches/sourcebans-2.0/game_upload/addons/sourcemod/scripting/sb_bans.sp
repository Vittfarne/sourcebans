/**
 * =============================================================================
 * SourceBans Bans Plugin
 *
 * @author InterWave Studios
 * @version 2.0.0
 * @copyright SourceBans (C)2007-2009 InterWaveStudios.com.  All rights reserved.
 * @package SourceBans
 * @link http://www.sourcebans.net
 * 
 * @version $Id: sourcebans.sp 178 2008-12-01 15:10:00Z tsunami $
 * =============================================================================
 */

#pragma semicolon 1

#include <sourcemod>
#include <sourcebans>

#undef REQUIRE_PLUGIN
#include <adminmenu>
#include <dbi>

#define STEAM_BAN_TYPE		0
#define IP_BAN_TYPE				1
#define DEFAULT_BAN_TYPE	STEAM_BAN_TYPE

//#define _DEBUG

public Plugin:myinfo =
{
	name        = "SourceBans: Bans",
	author      = "InterWave Studios",
	description = "Advanced ban management for the Source engine",
	version     = SB_VERSION,
	url         = "http://www.sourcebans.net"
};


/**
 * Globals
 */
new g_iBanTarget[MAXPLAYERS + 1];
new g_iBanTime[MAXPLAYERS + 1];
new g_iProcessQueueTime;
new g_iServerId;
new bool:g_bEnableAddBan;
new bool:g_bEnableUnban;
new bool:g_bOwnReason[MAXPLAYERS + 1];
new bool:g_bPlayerStatus[MAXPLAYERS + 1];
new Float:g_fRetryTime;
new Handle:g_hDatabase;
new Handle:g_hBanTimes;
new Handle:g_hBanTimesFlags;
new Handle:g_hBanTimesLength;
new Handle:g_hHackingMenu;
new Handle:g_hPlayerRecheck[MAXPLAYERS + 1];
new Handle:g_hProcessQueue;
new Handle:g_hReasonMenu;
new Handle:g_hSQLiteDB;
new Handle:g_hTopMenu;
new String:g_sDatabasePrefix[16];
new String:g_sServerIp[16];
new String:g_sWebsite[256];


/**
 * Plugin Forwards
 */
public OnPluginStart()
{
	RegAdminCmd("sm_ban",    Command_Ban,    ADMFLAG_BAN,   "sm_ban <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_banip",  Command_BanIp,  ADMFLAG_BAN,   "sm_banip <ip|#userid|name> <time> [reason]");
	RegAdminCmd("sm_addban", Command_AddBan, ADMFLAG_RCON,  "sm_addban <time> <steamid> [reason]");
	RegAdminCmd("sm_unban",  Command_Unban,  ADMFLAG_UNBAN, "sm_unban <steamid|ip>");
	
	RegConsoleCmd("say",      Command_Say);
	RegConsoleCmd("say_team", Command_Say);
	
	LoadTranslations("common.phrases");
	LoadTranslations("sourcebans.phrases");
	LoadTranslations("basebans.phrases");
	
	// Hook player_connect event to prevent connection spamming from people that are banned
	HookEvent("player_connect", Event_PlayerConnect, EventHookMode_Pre);
	
	g_hHackingMenu = CreateMenu(MenuHandler_Reason);
	g_hReasonMenu  = CreateMenu(MenuHandler_Reason);
	
	// Account for late loading
	new Handle:hTopMenu;
	if(LibraryExists("adminmenu") && (hTopMenu = GetAdminTopMenu()))
		OnAdminMenuReady(hTopMenu);
	
	// Connect to local database
	decl String:sError[256];
	g_hSQLiteDB    = SQLite_UseDatabase("sourcemod-local", sError, sizeof(sError));
	if(sError[0])
	{
		LogError("%T (%s)", "Could not connect to database", LANG_SERVER, sError);
		return;
	}
	
	// Create local bans table
	SQL_FastQuery(g_hSQLiteDB, "CREATE TABLE IF NOT EXISTS sb_bans (type INTEGER, steam TEXT PRIMARY KEY ON CONFLICT REPLACE, ip TEXT, name TEXT, created INTEGER, ends INTEGER, reason TEXT, admin_id TEXT, admin_ip TEXT, queued BOOLEAN, time INTEGER)");
	
	// Process temporary bans every minute
	CreateTimer(60.0, Timer_ProcessTemp);
}

public OnAdminMenuReady(Handle:topmenu)
{
	// Block us from being called twice
	if(topmenu == g_hTopMenu)
		return;
	
	// Save the handle
	g_hTopMenu = topmenu;
	
	// Find the "Player Commands" category
	new TopMenuObject:iPlayerCommands = FindTopMenuCategory(g_hTopMenu, ADMINMENU_PLAYERCOMMANDS);
	if(iPlayerCommands)
		AddToTopMenu(g_hTopMenu,
			"sm_ban",
			TopMenuObject_Item,
			MenuHandler_Ban,
			iPlayerCommands,
			"sm_ban",
			ADMFLAG_BAN);
}

public OnConfigsExecuted()
{
	decl String:sNewFile[PLATFORM_MAX_PATH + 1], String:sOldFile[PLATFORM_MAX_PATH + 1];
	BuildPath(Path_SM, sNewFile, sizeof(sNewFile), "plugins/disabled/basebans.smx");
	BuildPath(Path_SM, sOldFile, sizeof(sOldFile), "plugins/basebans.smx");
	
	// Check if plugins/basebans.smx exists, and if not, ignore
	if(!FileExists(sOldFile))
		return;
	
	// Check if plugins/disabled/basebans.smx already exists, and if so, delete it
	if(FileExists(sNewFile))
		DeleteFile(sNewFile);
	
	// Unload plugins/basebans.smx and move it to plugins/disabled/basebans.smx
	ServerCommand("sm plugins unload basebans");
	RenameFile(sNewFile, sOldFile);
	LogMessage("plugins/basebans.smx was unloaded and moved to plugins/disabled/basebans.smx");
}


/**
 * Client Forwards
 */
public OnClientAuthorized(client, const String:auth[])
{
	if(!g_hDatabase || StrContains("BOT STEAM_ID_LAN", auth) != -1)
	{
		g_bPlayerStatus[client] = true;
		return;
	}
	
	decl String:sIp[16], String:sQuery[256];
	GetClientIP(client, sIp, sizeof(sIp));
	
	Format(sQuery, sizeof(sQuery), "SELECT type, steam, ip, name, reason, length, admin_id, admin_ip, time \
																	FROM   %s_bans \
																	WHERE  ((type = %i AND steam REGEXP '^STEAM_[0-9]:%s$') OR (type = %i AND '%s' REGEXP REPLACE(REPLACE(ip, '.', '\\.') , '.0', '..{1,3}'))) \
																		AND  (length = 0 OR time + length * 60 > UNIX_TIMESTAMP()) \
																		AND  unban_admin_id IS NULL",
																	g_sDatabasePrefix, STEAM_BAN_TYPE, auth[8], IP_BAN_TYPE, sIp);
	SQL_TQuery(g_hDatabase, Query_BanVerify, sQuery, client, DBPrio_High);
}

public bool:OnClientConnect(client, String:rejectmsg[], maxlen)
{
	g_bPlayerStatus[client] = false;
	
	decl String:sIp[16];
	GetClientIP(client, sIp, sizeof(sIp));
	if(!HasLocalBan(sIp))
		return true;
	
	Format(rejectmsg, maxlen, "%t", "Banned Check Site", g_sWebsite);
	return false;
}

public OnClientDisconnect(client)
{
	if(g_hPlayerRecheck[client])
	{
		KillTimer(g_hPlayerRecheck[client]);
		g_hPlayerRecheck[client] = INVALID_HANDLE;
	}
}


/**
 * Ban Forwards
 */
public Action:OnBanClient(client, time, flags, const String:reason[], const String:kick_message[], const String:command[], any:admin)
{
	decl iType, String:sAdminIp[16], String:sAuth[20], String:sIp[16], String:sName[MAX_NAME_LENGTH + 1];
	new iAdminId    = GetAdminId(admin),
			bool:bSteam = GetClientAuthString(client, sAuth, sizeof(sAuth));
	GetClientIP(client,   sIp,   sizeof(sIp));
	GetClientName(client, sName, sizeof(sName));
	
	// Set type depending on passed flags
	if(flags      & BANFLAG_AUTHID || ((flags & BANFLAG_AUTO) && bSteam))
		iType = STEAM_BAN_TYPE;
	else if(flags & BANFLAG_IP)
		iType = IP_BAN_TYPE;
	// If no valid flag was passed, block banning
	else
		return Plugin_Handled;
	
	if(admin)
		GetClientIP(admin, sAdminIp, sizeof(sAdminIp));
	else
		sAdminIp = g_sServerIp;
	if(!g_hDatabase)
	{
		InsertLocalBan(iType, sAuth, sIp, sName, GetTime(), time, reason, iAdminId, sAdminIp, true);
		return Plugin_Handled;
	}
	if(time)
	{
		if(reason[0])
			ShowActivity2(admin, SB_PREFIX, "%t", "Banned player reason",      sName, time, reason);
		else
			ShowActivity2(admin, SB_PREFIX, "%t", "Banned player",             sName, time);
	}
	else
	{
		if(reason[0])
			ShowActivity2(admin, SB_PREFIX, "%t", "Permabanned player reason", sName, reason);
		else
			ShowActivity2(admin, SB_PREFIX, "%t", "Permabanned player",        sName);
	}
	
	new Handle:hPack = CreateDataPack();
	WritePackCell(hPack,   admin);
	WritePackCell(hPack,   time);
	WritePackString(hPack, sAuth);
	WritePackString(hPack, sIp);
	WritePackString(hPack, sName);
	WritePackString(hPack, reason);
	WritePackCell(hPack,   iAdminId);
	WritePackString(hPack, sAdminIp);
	
	decl String:sEscapedName[MAX_NAME_LENGTH * 2 + 1], String:sEscapedReason[256], String:sQuery[512];
	SQL_EscapeString(g_hDatabase, sName,  sEscapedName,   sizeof(sEscapedName));
	SQL_EscapeString(g_hDatabase, reason, sEscapedReason, sizeof(sEscapedReason));
	Format(sQuery, sizeof(sQuery), "INSERT INTO %s_bans (type, steam, ip, name, reason, length, server_id, admin_id, admin_ip, time) \
																	VALUES      (%i, '%s', '%s', '%s', '%s', %i, %i, NULLIF(%i, 0), '%s', UNIX_TIMESTAMP())",
																	g_sDatabasePrefix, iType, sAuth, sIp, sEscapedName, sEscapedReason, time, g_iServerId, iAdminId, sAdminIp);
	SQL_TQuery(g_hDatabase, Query_BanInsert, sQuery, hPack, DBPrio_High);
	
	LogAction(admin, client, "\"%L\" banned \"%L\" (minutes \"%i\") (reason \"%s\")", admin, client, time, reason);
	return Plugin_Handled;
}

public Action:OnBanIdentity(const String:identity[], time, flags, const String:reason[], const String:command[], any:admin)
{
	decl String:sAdminIp[16], String:sQuery[140];
	new iAdminId    = GetAdminId(admin),
			bool:bSteam = strncmp(identity, "STEAM_", 6) == 0;
	
	if(admin)
		GetClientIP(admin, sAdminIp, sizeof(sAdminIp));
	else
		sAdminIp = g_sServerIp;
	if(!g_hDatabase)
	{
		if(bSteam)
			InsertLocalBan(STEAM_BAN_TYPE, identity, "", "", GetTime(), time, reason, iAdminId, sAdminIp, true);
		else
			InsertLocalBan(IP_BAN_TYPE,    "", identity, "", GetTime(), time, reason, iAdminId, sAdminIp, true);
		return Plugin_Handled;
	}
	
	new Handle:hPack = CreateDataPack();
	WritePackCell(hPack,   admin);
	WritePackCell(hPack,   time);
	WritePackString(hPack, identity);
	WritePackString(hPack, reason);
	WritePackCell(hPack,   iAdminId);
	WritePackString(hPack, sAdminIp);
	
	if(flags      & BANFLAG_AUTHID || ((flags & BANFLAG_AUTO) && bSteam))
	{
		Format(sQuery, sizeof(sQuery), "SELECT 1 \
																		FROM   %s_bans \
																		WHERE  type  = %i \
																		  AND  steam REGEXP '^STEAM_[0-9]:%s$' \
																			AND  (length = 0 OR time + length * 60 > UNIX_TIMESTAMP()) \
																			AND  unban_admin_id IS NULL",
																		g_sDatabasePrefix, STEAM_BAN_TYPE, identity[8]);
		SQL_TQuery(g_hDatabase, Query_AddBanSelect, sQuery, hPack, DBPrio_High);
		
		LogAction(admin, -1, "\"%L\" added ban (minutes \"%i\") (id \"%s\") (reason \"%s\")", admin, time, identity, reason);
	}
	else if(flags & BANFLAG_IP     || ((flags & BANFLAG_AUTO) && !bSteam))
	{
		Format(sQuery, sizeof(sQuery), "SELECT 1 \
																		FROM   %s_bans \
																		WHERE  type = %i \
																		  AND  ip   = '%s' \
																			AND  (length = 0 OR time + length * 60 > UNIX_TIMESTAMP()) \
																			AND  unban_admin_id IS NULL",
																		g_sDatabasePrefix, IP_BAN_TYPE, identity);
		SQL_TQuery(g_hDatabase, Query_BanIpSelect,  sQuery, hPack, DBPrio_High);
		
		LogAction(admin, -1, "\"%L\" added ban (minutes \"%i\") (ip \"%s\") (reason \"%s\")", admin, time, identity, reason);
	}
	return Plugin_Handled;
}

public Action:OnRemoveBan(const String:identity[], flags, const String:command[], any:admin)
{
	decl String:sQuery[256];
	new Handle:hPack = CreateDataPack();
	WritePackCell(hPack,   admin);
	WritePackString(hPack, identity);
	
	if(flags      & BANFLAG_AUTHID)
		Format(sQuery, sizeof(sQuery), "SELECT 1 \
																		FROM   %s_bans \
																		WHERE  type  = %i \
																			AND  steam REGEXP '^STEAM_[0-9]:%s$' \
																			AND  (length = 0 OR time + length * 60 > UNIX_TIMESTAMP()) \
																			AND  unban_admin_id IS NULL",
																		g_sDatabasePrefix, STEAM_BAN_TYPE, identity[8]);
	else if(flags & BANFLAG_IP)
		Format(sQuery, sizeof(sQuery), "SELECT 1 \
																		FROM   %s_bans \
																		WHERE  type = %i \
																			AND  ip   = '%s' \
																			AND  (length = 0 OR time + length * 60 > UNIX_TIMESTAMP()) \
																			AND  unban_admin_id IS NULL",
																		g_sDatabasePrefix, IP_BAN_TYPE, identity);
	SQL_TQuery(g_hDatabase, Query_UnbanSelect, sQuery, hPack);
	
	LogAction(admin, -1, "\"%L\" removed ban (filter \"%s\")", admin, identity);
	return Plugin_Handled;
}


/**
 * SourceBans Forwards
 */
public SB_OnConnect(Handle:database)
{
	g_iServerId = SB_GetSettingCell("ServerID");
	g_hDatabase = database;
}

public SB_OnReload()
{
	// Get settings from SourceBans config and store them locally
	SB_GetSettingString("DatabasePrefix", g_sDatabasePrefix, sizeof(g_sDatabasePrefix));
	SB_GetSettingString("ServerIP",       g_sServerIp,       sizeof(g_sServerIp));
	SB_GetSettingString("Website",        g_sWebsite,        sizeof(g_sWebsite));
	g_bEnableAddBan     = SB_GetSettingCell("Addban") == 1;
	g_bEnableUnban      = SB_GetSettingCell("Unban")  == 1;
	g_iProcessQueueTime = SB_GetSettingCell("ProcessQueueTime");
	g_fRetryTime        = float(SB_GetSettingCell("RetryTime"));
	g_hBanTimes         = Handle:SB_GetSettingCell("BanTimes");
	g_hBanTimesFlags    = Handle:SB_GetSettingCell("BanTimesFlags");
	g_hBanTimesLength   = Handle:SB_GetSettingCell("BanTimesLength");
	
	// Get reasons from SourceBans config and store them locally
	decl String:sReason[128];
	new Handle:hBanReasons     = Handle:SB_GetSettingCell("BanReasons");
	new Handle:hHackingReasons = Handle:SB_GetSettingCell("HackingReasons");
	
	// Empty reason menus
	RemoveAllMenuItems(g_hReasonMenu);
	RemoveAllMenuItems(g_hHackingMenu);
	
	// Add reasons from SourceBans config to reason menus
	for(new i = 0, iSize = GetArraySize(hBanReasons);     i < iSize; i++)
	{
		GetArrayString(hBanReasons,     i, sReason, sizeof(sReason));
		AddMenuItem(g_hReasonMenu,  sReason, sReason);
	}
	for(new i = 0, iSize = GetArraySize(hHackingReasons); i < iSize; i++)
	{
		GetArrayString(hHackingReasons, i, sReason, sizeof(sReason));
		AddMenuItem(g_hHackingMenu, sReason, sReason);
	}
	
	// Restart process queue timer
	if(g_hProcessQueue)
		KillTimer(g_hProcessQueue);
	
	g_hProcessQueue = CreateTimer(g_iProcessQueueTime * 60.0, Timer_ProcessQueue, _, TIMER_REPEAT);
}


/**
 * Commands
 */
public Action:Command_Ban(client, args)
{
	if(args < 2)
	{
		ReplyToCommand(client, "%sUsage: sm_ban <#userid|name> <time|0> [reason]", SB_PREFIX);
		return Plugin_Handled;
	}
	
	decl iLen, String:sArg[256], String:sKickMessage[128], String:sTarget[64], String:sTime[12];
	GetCmdArgString(sArg, sizeof(sArg));
	iLen  = BreakString(sArg,       sTarget, sizeof(sTarget));
	iLen += BreakString(sArg[iLen], sTime,   sizeof(sTime));
	
	new iTarget = FindTarget(client, sTarget, true), iTime = StringToInt(sTime);
	if(iTarget == -1)
		return Plugin_Handled;
	if(!g_bPlayerStatus[iTarget])
	{
		ReplyToCommand(client, "%s%t", SB_PREFIX, "Ban Not Verified");
		return Plugin_Handled;
	}
	if(!iTime && !(GetUserFlagBits(client) & (ADMFLAG_UNBAN|ADMFLAG_ROOT)))
	{
		ReplyToCommand(client, "%sYou do not have Perm Ban Permission", SB_PREFIX);
		return Plugin_Handled;
	}
	
	Format(sKickMessage, sizeof(sKickMessage), "%t", "Banned Check Site", g_sWebsite);
	BanClient(iTarget, iTime, BANFLAG_AUTO, sArg[iLen], sKickMessage, "sm_ban", client);
	return Plugin_Handled;
}

public Action:Command_BanIp(client, args)
{
	if(args < 2)
	{
		ReplyToCommand(client, "%sUsage: sm_banip <ip|#userid|name> <time> [reason]", SB_PREFIX);
		return Plugin_Handled;
	}
	
	decl iLen, iTargets[1], bool:tn_is_ml, String:sArg[256], String:sIp[16], String:sTargets[MAX_TARGET_LENGTH], String:sTime[12];
	GetCmdArgString(sArg, sizeof(sArg));
	iLen  = BreakString(sArg,       sIp,   sizeof(sIp));
	iLen += BreakString(sArg[iLen], sTime, sizeof(sTime));
	
	new iTarget = -1, iTime = StringToInt(sTime);
	if(!iTime && !(GetUserFlagBits(client) & (ADMFLAG_UNBAN|ADMFLAG_ROOT)))
	{
		ReplyToCommand(client, "%sYou do not have Perm Ban Permission", SB_PREFIX);
		return Plugin_Handled;
	}
	if(ProcessTargetString(sIp,
		client,
		iTargets,
		1,
		COMMAND_FILTER_CONNECTED|COMMAND_FILTER_NO_MULTI,
		sTargets,
		sizeof(sTargets),
		tn_is_ml) > 0)
	{
		iTarget = iTargets[0];
		if(!IsFakeClient(iTarget) && CanUserTarget(client, iTarget))
			GetClientIP(iTarget, sIp, sizeof(sIp));
	}
	
	BanIdentity(sIp, iTime, BANFLAG_IP, sArg[iLen], "sm_banip",  client);
	return Plugin_Handled;
}

public Action:Command_AddBan(client, args)
{
	if(args < 2)
	{
		ReplyToCommand(client, "%sUsage: sm_addban <time> <steamid> [reason]", SB_PREFIX);
		return Plugin_Handled;
	}
	if(!g_bEnableAddBan)
	{
		ReplyToCommand(client, "%s%t", SB_PREFIX, "Can Not Add Ban", g_sWebsite);
		return Plugin_Handled;
	}
	
	decl iLen, iTargets[1], bool:tn_is_ml, String:sArg[256], String:sAuth[20], String:sTargets[MAX_TARGET_LENGTH], String:sTime[20];
	GetCmdArgString(sArg, sizeof(sArg));
	iLen  = BreakString(sArg,       sTime, sizeof(sTime));
	iLen += BreakString(sArg[iLen], sAuth, sizeof(sAuth));
	
	new iTarget = -1, iTime = StringToInt(sTime);
	if(!iTime && !(GetUserFlagBits(client) & (ADMFLAG_UNBAN|ADMFLAG_ROOT)))
	{
		ReplyToCommand(client, "%sYou do not have Perm Ban Permission", SB_PREFIX);
		return Plugin_Handled;
	}
	if(ProcessTargetString(sAuth,
		client,
		iTargets,
		1,
		COMMAND_FILTER_CONNECTED|COMMAND_FILTER_NO_MULTI,
		sTargets,
		sizeof(sTargets),
		tn_is_ml) > 0)
	{
		iTarget = iTargets[0];
		
		if(!IsFakeClient(iTarget) && CanUserTarget(client, iTarget))
			GetClientAuthString(iTarget, sAuth, sizeof(sAuth));
	}
	
	BanIdentity(sAuth, iTime, BANFLAG_AUTHID, sArg[iLen], "sm_addban", client);
	return Plugin_Handled;
}

public Action:Command_Unban(client, args)
{
	if(args < 1)
	{
		ReplyToCommand(client, "%sUsage: sm_unban <steamid|ip>", SB_PREFIX);
		return Plugin_Handled;
	}
	if(!(GetUserFlagBits(client) & (ADMFLAG_UNBAN|ADMFLAG_ROOT)) || !g_bEnableUnban)
	{
		ReplyToCommand(client, "%s%t", SB_PREFIX, "Can Not Unban", g_sWebsite);
		return Plugin_Handled;
	}
	
	decl String:sArg[24];
	GetCmdArgString(sArg, sizeof(sArg));
	ReplaceString(sArg,   sizeof(sArg), "\"", "");
	
	RemoveBan(sArg, strncmp(sArg, "STEAM_", 6) == 0 ? BANFLAG_AUTHID : BANFLAG_IP, "sm_unban", client);
	return Plugin_Handled;
}

public Action:Command_Say(client, args)
{
	// If this client is not typing their own reason to ban someone, ignore
	if(!g_bOwnReason[client])
		return Plugin_Continue;
	
	g_bOwnReason[client] = false;
	
	decl String:sText[192];
	new iStart = 0;
	if(GetCmdArgString(sText, sizeof(sText)) < 1)
		return Plugin_Continue;
	
	if(sText[strlen(sText) - 1] == '"')
	{
		sText[strlen(sText) - 1] = '\0';
		iStart = 1;
	}
	if(StrEqual(sText[iStart], "!noreason"))
	{
		ReplyToCommand(client, "%s%t", SB_PREFIX, "Chat Reason Aborted");
		return Plugin_Handled;
	}
	if(g_iBanTarget[client] != -1)
	{
		decl String:sKickMessage[128];
		Format(sKickMessage, sizeof(sKickMessage), "%t", "Banned Check Site", g_sWebsite);
		BanClient(g_iBanTarget[client], g_iBanTime[client], BANFLAG_AUTO, sText[iStart], sKickMessage, "sm_ban", client);
		return Plugin_Handled;
	}
	return Plugin_Continue;
}


/**
 * Events
 */
public Action:Event_PlayerConnect(Handle:event, const String:name[], bool:dontBroadcast)
{
	if(dontBroadcast)
		return Plugin_Continue;
	
	decl String:sAuth[20], String:sIp[16], String:sName[MAX_NAME_LENGTH + 1];
	new iIndex  = GetEventInt(event, "index"),
			iUserId = GetEventInt(event, "userid");
	GetEventString(event, "address",   sIp,   sizeof(sIp));
	GetEventString(event, "name",      sName, sizeof(sName));
	GetEventString(event, "networkid", sAuth, sizeof(sAuth));
	// If the player is not banned, allow the event to continue
	if(!HasLocalBan(sIp))
		return Plugin_Continue;
	
	new Handle:hEvent = CreateEvent("player_connect");
	SetEventInt(hEvent, "index", iIndex);
	SetEventInt(hEvent, "userid", iUserId);
	SetEventString(hEvent, "address",   sIp);
	SetEventString(hEvent, "name",      sName);
	SetEventString(hEvent, "networkid", sAuth);
	FireEvent(hEvent, true);
	return Plugin_Handled;
}


/**
 * Timers
 */
public Action:Timer_ClientRecheck(Handle:timer, any:client)
{
	if(!g_bPlayerStatus[client] && IsClientConnected(client))
	{
		decl String:sAuth[20];
		GetClientAuthString(client, sAuth, sizeof(sAuth));
		OnClientAuthorized(client,  sAuth);
	}
	
	g_hPlayerRecheck[client] = INVALID_HANDLE;
	return Plugin_Stop;
}

public Action:Timer_ProcessQueue(Handle:timer, any:data)
{
	if(!g_hSQLiteDB)
		return;
	
	new Handle:hQuery = SQL_Query(g_hSQLiteDB, "SELECT type, steam, ip, name, created, ends, reason, admin_id, admin_ip \
																							FROM   sb_bans \
																							WHERE  queued = 1");
	if(!hQuery)
		return;
	
	decl iAdminId, iCreated, iEnds, iType, String:sAdminIp[16], String:sAuth[20], String:sEscapedName[MAX_NAME_LENGTH * 2 + 1],
			 String:sEscapedReason[256], String:sIp[16], String:sName[MAX_NAME_LENGTH + 1], String:sQuery[768], String:sReason[128];
	while(SQL_FetchRow(hQuery))
	{
		iType    = SQL_FetchInt(hQuery, 0);
		SQL_FetchString(hQuery, 1, sAuth,    sizeof(sAuth));
		SQL_FetchString(hQuery, 2, sIp,      sizeof(sIp));
		SQL_FetchString(hQuery, 3, sName,    sizeof(sName));
		iCreated = SQL_FetchInt(hQuery, 4);
		iEnds    = SQL_FetchInt(hQuery, 5);
		SQL_FetchString(hQuery, 6, sReason,  sizeof(sReason));
		iAdminId = SQL_FetchInt(hQuery, 7);
		SQL_FetchString(hQuery, 8, sAdminIp, sizeof(sAdminIp));
		SQL_EscapeString(g_hSQLiteDB, sName,   sEscapedName,   sizeof(sEscapedName));
		SQL_EscapeString(g_hSQLiteDB, sReason, sEscapedReason, sizeof(sEscapedReason));
		
		if(iEnds <= GetTime())
		{
			DeleteLocalBan(iType == STEAM_BAN_TYPE ? sAuth : sIp);
			continue;
		}
		
		new Handle:hPack = CreateDataPack();
		WritePackString(hPack, iType == STEAM_BAN_TYPE ? sAuth : sIp);
		
		Format(sQuery, sizeof(sQuery), "INSERT INTO %s_bans (type, steam, ip, name, reason, length, server_id, admin_id, admin_ip, time) \
																		VALUES      (%i, NULLIF('%s', ''), NULLIF('%s', ''), NULLIF('%s', ''), '%s', %i, %i, NULLIF(%i, 0), '%s', %i)",
																		g_sDatabasePrefix, iType, sAuth, sIp, sEscapedName, sEscapedReason, iLength, g_iServerId, iAdminId, sAdminIp, iCreated);
		SQL_TQuery(g_hDatabase, Query_AddedFromQueue, sQuery, hPack);
	}
}

public Action:Timer_ProcessTemp(Handle:timer)
{
	if(!g_hSQLiteDB)
		return;
	
	// Delete temporary bans that expired or were added over 5 minutes ago
	decl String:sQuery[128];
	Format(sQuery, sizeof(sQuery), "DELETE FROM sb_bans \
																	WHERE       (ends <= %i OR time + 300 > %i) \
																		AND       queued = 0",
																	GetTime(), GetTime());
	SQL_FastQuery(g_hSQLiteDB, sQuery);
}


/**
 * Menu Handlers
 */
public MenuHandler_Ban(Handle:topmenu, TopMenuAction:action, TopMenuObject:object_id, param, String:buffer[], maxlength)
{
	if(action      == TopMenuAction_DisplayOption)
		Format(buffer, maxlength, "%T", "Ban player", param);
	else if(action == TopMenuAction_SelectOption)
		DisplayBanTargetMenu(param);
}

public MenuHandler_Target(Handle:menu, MenuAction:action, param1, param2)
{
	if(action      == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack && g_hTopMenu)
			DisplayTopMenu(g_hTopMenu, param1, TopMenuPosition_LastCategory);
	}
	else if(action == MenuAction_End)
		CloseHandle(menu);
	else if(action == MenuAction_Select)
	{
		decl iTarget, String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		if(!(iTarget = GetClientOfUserId(StringToInt(sInfo))))
			PrintToChat(param1, "%s%t", "Player no longer available", SB_PREFIX);
		else if(!CanUserTarget(param1, iTarget))
			PrintToChat(param1, "%s%t", "Unable to target",           SB_PREFIX);
		else
		{
			g_iBanTarget[param1] = iTarget;
			DisplayBanTimeMenu(param1);
		}
	}
}

public MenuHandler_Time(Handle:menu, MenuAction:action, param1, param2)
{
	if(action      == MenuAction_Cancel)
	{
		if(param2 == MenuCancel_ExitBack && g_hTopMenu)
			DisplayTopMenu(g_hTopMenu, param1, TopMenuPosition_LastCategory);
	}
	else if(action == MenuAction_End)
		CloseHandle(menu);
	else if(action == MenuAction_Select)
	{
		decl String:sInfo[32];
		GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
		g_iBanTime[param1] = StringToInt(sInfo);
		DisplayMenu(g_hReasonMenu, param1, MENU_TIME_FOREVER);
	}
}

public MenuHandler_Reason(Handle:menu, MenuAction:action, param1, param2)
{
	if(action == MenuAction_Cancel)
		DisplayBanTimeMenu(param1);
	if(action != MenuAction_Select)
		return;
	
	decl String:sInfo[64];
	GetMenuItem(menu, param2, sInfo, sizeof(sInfo));
	if(StrEqual(sInfo, "Hacking") && menu == g_hReasonMenu)
	{
		DisplayMenu(g_hHackingMenu, param1, MENU_TIME_FOREVER);
		return;
	}
	if(StrEqual(sInfo, "Own Reason"))
	{
		g_bOwnReason[param1] = true;
		PrintToChat(param1, "%s%t", SB_PREFIX, "Chat Reason");
		return;
	}
	if(g_iBanTarget[param1] != -1)
	{
		decl String:sKickMessage[128];
		Format(sKickMessage, sizeof(sKickMessage), "%t", "Banned Check Site", g_sWebsite);
		BanClient(g_iBanTarget[param1], g_iBanTime[param1], BANFLAG_AUTO, sInfo, sKickMessage, "sm_ban", param1);
	}
	
	g_iBanTarget[param1] = -1;
	g_iBanTime[param1]   = -1;
}


/**
 * Query Callbacks
 */
public Query_BanInsert(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	ResetPack(pack);
	
	decl String:sAdminIp[16], String:sAuth[20], String:sIp[16], String:sName[MAX_NAME_LENGTH + 1], String:sReason[128];
	new iAdmin   = ReadPackCell(pack);
	new iLength  = ReadPackCell(pack);
	ReadPackString(pack, sAuth,      sizeof(sAuth));
	ReadPackString(pack, sIp,        sizeof(sIp));
	ReadPackString(pack, sName,      sizeof(sName));
	ReadPackString(pack, sReason,    sizeof(sReason));
	new iAdminId = ReadPackCell(pack);
	ReadPackString(pack, sAdminIp,   sizeof(sAdminIp));
	
	InsertLocalBan(STEAM_BAN_TYPE, sAuth, sIp, sName, GetTime(), iLength, sReason, iAdminId, sAdminIp, !!error[0]);
	if(error[0])
	{
		LogError("Failed to insert the ban into the database: %s", error);
		
		ReplyToCommand(iAdmin, "%sFailed to ban %s.", SB_PREFIX, sAuth);
		return;
	}
}

public Query_BanIpSelect(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	ResetPack(pack);
	
	decl String:sAdminIp[16], String:sEscapedReason[256], String:sIp[16], String:sQuery[512], String:sReason[128];
	new iAdmin   = ReadPackCell(pack);
	new iLength  = ReadPackCell(pack);
	ReadPackString(pack, sIp,      sizeof(sIp));
	ReadPackString(pack, sReason,  sizeof(sReason));
	new iAdminId = ReadPackCell(pack);
	ReadPackString(pack, sAdminIp, sizeof(sAdminIp));
	
	if(error[0])
	{
		LogError("Failed to retrieve the IP ban from the database: %s", error);
		
		ReplyToCommand(iAdmin, "%sFailed to ban %s.",     SB_PREFIX, sIp);
		return;
	}
	if(SQL_GetRowCount(hndl))
	{
		ReplyToCommand(iAdmin, "%s%s is already banned.", SB_PREFIX, sIp);
		return;
	}
	
	SQL_EscapeString(g_hDatabase, sReason, sEscapedReason, sizeof(sEscapedReason));
	Format(sQuery, sizeof(sQuery), "INSERT INTO %s_bans (type, ip, reason, length, server_id, admin_id, admin_ip, time) \
																	VALUES      (%i, '%s', '%s', %i, %i, NULLIF(%i, 0), '%s', UNIX_TIMESTAMP())",
																	g_sDatabasePrefix, IP_BAN_TYPE, sIp, sEscapedReason, iLength, g_iServerId, iAdminId, sAdminIp);
	SQL_TQuery(g_hDatabase, Query_BanIpInsert, sQuery, pack, DBPrio_High);
}

public Query_BanIpInsert(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	ResetPack(pack);
	
	decl String:sAdminIp[30], String:sIp[16], String:sReason[128];
	new iAdmin   = ReadPackCell(pack);
	new iLength  = ReadPackCell(pack);
	ReadPackString(pack, sIp,      sizeof(sIp));
	ReadPackString(pack, sReason,  sizeof(sReason));
	new iAdminId = ReadPackCell(pack);
	ReadPackString(pack, sAdminIp, sizeof(sAdminIp));
	
	InsertLocalBan(IP_BAN_TYPE, "", sIp, "", GetTime(), iLength, sReason, iAdminId, sAdminIp, !!error[0]);
	if(error[0])
	{
		LogError("Failed to insert the IP ban into the database: %s", error);
		
		ReplyToCommand(iAdmin, "%sFailed to ban %s.",       SB_PREFIX, sIp);
		return;
	}
}

public Query_AddBanSelect(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	ResetPack(pack);
	
	decl String:sAdminIp[20], String:sAuth[20], String:sEscapedReason[256], String:sQuery[512], String:sReason[128];
	new iAdmin   = ReadPackCell(pack);
	new iLength  = ReadPackCell(pack);
	ReadPackString(pack, sAuth,      sizeof(sAuth));
	ReadPackString(pack, sReason,    sizeof(sReason));
	new iAdminId = ReadPackCell(pack);
	ReadPackString(pack, sAdminIp,   sizeof(sAdminIp));
	
	if(error[0])
	{
		LogError("Failed to retrieve the ID ban from the database: %s", error);
		
		ReplyToCommand(iAdmin, "%sFailed to ban %s.",     SB_PREFIX, sAuth);
		return;
	}
	if(SQL_GetRowCount(hndl))
	{
		ReplyToCommand(iAdmin, "%s%s is already banned.", SB_PREFIX, sAuth);
		return;
	}
	
	SQL_EscapeString(g_hDatabase, sReason, sEscapedReason, sizeof(sEscapedReason));
	Format(sQuery, sizeof(sQuery), "INSERT INTO %s_bans (type, steam, reason, length, server_id, admin_id, admin_ip, time) \
																	VALUES      (%i, '%s', '%s', %i, %i, NULLIF(%i, 0), '%s', UNIX_TIMESTAMP())",
																	g_sDatabasePrefix, STEAM_BAN_TYPE, sAuth, sEscapedReason, iLength, g_iServerId, iAdminId, sAdminIp);
	SQL_TQuery(g_hDatabase, Query_AddBanInsert, sQuery, pack, DBPrio_High);
}

public Query_AddBanInsert(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	ResetPack(pack);
	
	decl String:sAdminIp[20], String:sAuth[20], String:sReason[128];
	new iAdmin   = ReadPackCell(pack);
	new iLength  = ReadPackCell(pack);
	ReadPackString(pack, sAuth,    sizeof(sAuth));
	ReadPackString(pack, sReason,  sizeof(sReason));
	new iAdminId = ReadPackCell(pack);
	ReadPackString(pack, sAdminIp, sizeof(sAdminIp));
	
	InsertLocalBan(STEAM_BAN_TYPE, sAuth, "", "", GetTime(), iLength, sReason, iAdminId, sAdminIp, !!error[0]);
	if(error[0])
	{
		LogError("Failed to insert the ID ban into the database: %s", error);
		
		ReplyToCommand(iAdmin, "%sFailed to ban %s.", SB_PREFIX, sAuth);
		return;
	}
}

public Query_UnbanSelect(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	ResetPack(pack);
	
	decl String:sIdentity[20], String:sQuery[512];
	new iAdmin = ReadPackCell(pack);
	ReadPackString(pack, sIdentity, sizeof(sIdentity));
	
	if(error[0])
	{
		LogError("Failed to retrieve the ban from the database: %s", error);
		
		ReplyToCommand(iAdmin, "%sFailed to unban %s.",          SB_PREFIX, sIdentity);
		return;
	}
	if(!SQL_GetRowCount(hndl))
	{
		ReplyToCommand(iAdmin, "%sNo active bans found for %s.", SB_PREFIX, sIdentity);
		return;
	}
	
	if(strncmp(sIdentity, "STEAM_", 6) == 0)
		Format(sQuery, sizeof(sQuery), "UPDATE   %s_bans \
																		SET      unban_admin_id = %i, \
																						 unban_time     = UNIX_TIMESTAMP() \
																		WHERE    type           = %i \
																			AND    steam          REGEXP '^STEAM_[0-9]:%s$' \
																		ORDER BY time DESC \
																		LIMIT    1",
																		g_sDatabasePrefix, GetAdminId(iAdmin), STEAM_BAN_TYPE, sIdentity[8]);
	else
		Format(sQuery, sizeof(sQuery), "UPDATE   %s_bans \
																		SET      unban_admin_id = %i, \
																						 unban_time     = UNIX_TIMESTAMP() \
																		WHERE    type           = %i \
																			AND    ip             = '%s' \
																		ORDER BY time DESC \
																		LIMIT    1",
																		g_sDatabasePrefix, GetAdminId(iAdmin), IP_BAN_TYPE, sIdentity);
	
	SQL_TQuery(g_hDatabase, Query_UnbanUpdate, sQuery, pack, DBPrio_High);
	
	DeleteLocalBan(sIdentity);
}

public Query_UnbanUpdate(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	ResetPack(pack);
	
	decl String:sIdentity[20];
	new iAdmin = ReadPackCell(pack);
	ReadPackString(pack, sIdentity, sizeof(sIdentity));
	
	if(error[0])
	{
		LogError("Failed to unban the ban from the database: %s", error);
		
		ReplyToCommand(iAdmin, "%sFailed to unban %s.", SB_PREFIX, sIdentity);
	}
}

public Query_BanVerify(Handle:owner, Handle:hndl, const String:error[], any:client)
{
	if(!client || !IsClientInGame(client))
		return;
	if(error[0])
	{
		LogError("Failed to verify the ban: %s", error);
		g_hPlayerRecheck[client] = CreateTimer(g_fRetryTime, Timer_ClientRecheck, client);
		return;
	}
	if(!SQL_GetRowCount(hndl))
	{
		g_bPlayerStatus[client] = true;
		return;
	}
	
	decl String:sAdminIp[16], String:sAuth[20], String:sEscapedName[MAX_NAME_LENGTH * 2 + 1], String:sIp[16], String:sLength[64], String:sName[MAX_NAME_LENGTH + 1], String:sQuery[512], String:sReason[128];
	GetClientAuthString(client, sAuth, sizeof(sAuth));
	GetClientIP(client,         sIp,   sizeof(sIp));
	GetClientName(client,       sName, sizeof(sName));
	
	SQL_EscapeString(g_hDatabase, sName, sEscapedName, sizeof(sEscapedName));
	Format(sQuery, sizeof(sQuery), "INSERT INTO %s_blocks (ban_id, name, server_id, time) \
																	VALUES      ((SELECT id FROM %s_bans WHERE ((type = %i AND steam REGEXP '^STEAM_[0-9]:%s$') OR (type = %i AND '%s' REGEXP REPLACE(REPLACE(ip, '.', '\\.') , '.0', '..{1,3}'))) AND unban_admin_id IS NULL ORDER BY time LIMIT 1), '%s', %i, UNIX_TIMESTAMP())",
																	g_sDatabasePrefix, g_sDatabasePrefix, STEAM_BAN_TYPE, sAuth[8], IP_BAN_TYPE, sIp, sEscapedName, g_iServerId);
	SQL_TQuery(g_hDatabase, Query_ErrorCheck, sQuery, client, DBPrio_High);
	
	// SELECT type, steam, ip, name, reason, length, admin_id, admin_ip, time
	new iType    = SQL_FetchInt(hndl, 0);
	SQL_FetchString(hndl, 1, sAuth,    sizeof(sAuth));
	SQL_FetchString(hndl, 2, sIp,      sizeof(sIp));
	SQL_FetchString(hndl, 3, sName,    sizeof(sName));
	SQL_FetchString(hndl, 4, sReason,  sizeof(sReason));
	new iLength  = SQL_FetchInt(hndl, 5);
	new iAdminId = SQL_FetchInt(hndl, 6);
	SQL_FetchString(hndl, 7, sAdminIp, sizeof(sAdminIp));
	new iTime    = SQL_FetchInt(hndl, 8);
	
	SecondsToString(sLength, sizeof(sLength), iLength * 60);
	PrintToConsole(client, "===============================================");
	PrintToConsole(client, "%sYou are banned from this server.", SB_PREFIX);
	PrintToConsole(client, "%sYou have %s left on your ban.",    SB_PREFIX, sLength);
	PrintToConsole(client, "%sName:       %s",                   SB_PREFIX, sName);
	PrintToConsole(client, "%sSteam ID:   %s",                   SB_PREFIX, sAuth);
	PrintToConsole(client, "%sIP address: %s",                   SB_PREFIX, sIp);
	PrintToConsole(client, "%sReason:     %s",                   SB_PREFIX, sReason);
	PrintToConsole(client, "%sYou can protest your ban at %s.",  SB_PREFIX, g_sWebsite);
	PrintToConsole(client, "===============================================");
	
	InsertLocalBan(iType, sAuth, sIp, sName, iCreated, iLength, sReason, iAdminId, sAdminIp);
	KickClient(client, "%t", "Banned Check Site", g_sWebsite);
}

public Query_AddedFromQueue(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if(error[0])
		return;
	
	decl String:sIdentity[20];
	ResetPack(pack);
	ReadPackString(pack, sIdentity, sizeof(sIdentity));
	
	DeleteLocalBan(sIdentity);
}

public Query_ErrorCheck(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if(error[0])
		LogError("%T (%s)", "Failed to query database", error);
}


/**
 * Stocks
 */
DeleteLocalBan(const String:sIdentity[])
{
	if(!g_hSQLiteDB)
		return;
	
	decl String:sQuery[64];
	Format(sQuery, sizeof(sQuery), "DELETE FROM sb_bans \
																	WHERE       (type = %i AND steam = '%s') \
																		 OR       (type = %i AND ip    = '%s')",
																	STEAM_BAN_TYPE, sIdentity, IP_BAN_TYPE, sIdentity);
	SQL_FastQuery(g_hSQLiteDB, sQuery);
}

DisplayBanTargetMenu(client)
{
	decl String:sTitle[128];
	new Handle:hMenu = CreateMenu(MenuHandler_Target);
	Format(sTitle, sizeof(sTitle), "%T:", "Ban player", client);
	SetMenuTitle(hMenu, sTitle);
	SetMenuExitBackButton(hMenu, true);
	AddTargetsToMenu2(hMenu, client, COMMAND_FILTER_NO_BOTS|COMMAND_FILTER_CONNECTED);
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

DisplayBanTimeMenu(client)
{
	decl String:sTitle[128];
	new Handle:hMenu = CreateMenu(MenuHandler_Time);
	Format(sTitle, sizeof(sTitle), "%T:", "Ban player", client);
	SetMenuTitle(hMenu, sTitle);
	SetMenuExitBackButton(hMenu, true);
	
	decl iFlags, String:sFlags[32], String:sLength[16], String:sName[32];
	for(new i = 0, iSize = GetArraySize(g_hBanTimes); i < iSize; i++)
	{
		GetArrayString(g_hBanTimes,       i, sName,   sizeof(sName));
		GetArrayString(g_hBanTimesFlags,  i, sFlags,  sizeof(sFlags));
		GetArrayString(g_hBanTimesLength, i, sLength, sizeof(sLength));
		iFlags = ReadFlagString(sFlags);
		
		if((GetUserFlagBits(client) & iFlags) == iFlags)
			AddMenuItem(hMenu, sLength, sName);
	}
	
	DisplayMenu(hMenu, client, MENU_TIME_FOREVER);
}

GetAdminId(client)
{
	// If admins are enabled, return their admin id, otherwise return 0
	return SB_GetSettingCell("EnableAdmins") ? SB_GetAdminId(client) : 0;
}

bool:HasLocalBan(const String:sIdentity[])
{
	if(!g_hSQLiteDB)
		return false;
	
	decl String:sQuery[256];
	Format(sQuery, sizeof(sQuery), "SELECT 1 \
																	FROM   sb_bans \
																	WHERE  (steam = '%s' OR ip = '%s') \
																		AND  ends        > %i \
																		AND  time + 300 <= %i",
																	sIdentity, sIdentity, GetTime(), GetTime());
	
	new Handle:hQuery = SQL_Query(g_hSQLiteDB, sQuery);
	return hQuery && SQL_FetchRow(hQuery);
}

InsertLocalBan(iType, const String:sAuth[], const String:sIp[], const String:sName[], iCreated, iLength, const String:sReason[], iAdminId, const String:sAdminIp[], bool:bQueued = false)
{
	decl String:sEscapedName[MAX_NAME_LENGTH * 2 + 1], String:sEscapedReason[256], String:sQuery[512];
	SQL_EscapeString(g_hSQLiteDB, sName,   sEscapedName,   sizeof(sEscapedName));
	SQL_EscapeString(g_hSQLiteDB, sReason, sEscapedReason, sizeof(sEscapedReason));
	
	Format(sQuery, sizeof(sQuery), "INSERT INTO sb_bans (type, steam, ip, name, created, ends, reason, admin_id, admin_ip, queued, time) \
																	VALUES      (%i, '%s', '%s', '%s', %i, %i, '%s', '%s', '%s', %i, %i)", 
																	iType, sAuth, sIp, sEscapedName, iCreated, iCreated + iLength * 60, sEscapedReason, iAdminId, sAdminIp, bQueued ? 1 : 0, GetTime());
	SQL_FastQuery(g_hSQLiteDB, sQuery);
}

SecondsToString(String:sBuffer[], iLength, iSecs, bool:bTextual = true)
{
	if(bTextual)
	{
		decl String:sDesc[6][8] = {"mo",              "wk",             "d",          "hr",    "min", "sec"};
		new  iCount, iDiv[6]    = {60 * 60 * 24 * 30, 60 * 60 * 24 * 7, 60 * 60 * 24, 60 * 60, 60,    1};
		
		for(new i = 0; i < sizeof(iDiv); i++)
		{
			if((iCount = iSecs / iDiv[i]) > 0)
			{
				Format(sBuffer, iLength, "%s%i %s, ", sBuffer, iCount, sDesc[i]);
				iSecs %= iDiv[i];
			}
		}
		strcopy(sBuffer, strlen(sBuffer) - 2, sBuffer);
	}
	else
	{
		new iHours = iSecs  / 60 / 60;
		iSecs     -= iHours * 60 * 60;
		new iMins  = iSecs  / 60;
		iSecs     %= 60;
		Format(sBuffer, iLength, "%i:%i:%i", iHours, iMins, iSecs);
	}
}