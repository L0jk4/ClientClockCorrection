#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>
#include <clientprefs>

Handle g_hClockCorrection = null;
DynamicDetour g_hDetourAdjustPlayerTimeBase;
Address gpGlobals_simTicksThisFrame;

float g_flClockCorrection[MAXPLAYERS + 1]; 
int   g_ticksClockCorrection[MAXPLAYERS + 1];
bool g_debugClockCorrection[MAXPLAYERS + 1]; 

public Plugin myinfo =
{
	name        = "Per-client clock correction",
	author      = "Lojka",
	description = "Remakes CBasePlayer::AdjustPlayerTimeBase with per-client clock correction value",
	version     = "1.0.0",
	url         = ""
};

#define DEFAULT_CLOCKCORRECTION 20.0

public void OnPluginStart()
{
	initializeArrays();
	g_hClockCorrection = RegClientCookie("clock_correction", "Per-player clock correction value", CookieAccess_Private);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && AreClientCookiesCached(i))
			OnClientCookiesCached(i);
	}

	GameData hGameData = new GameData("ClientClockCorrection.games");
	if (hGameData == null)
		SetFailState("Could not load gamedata \"%s\"", "ClientClockCorrection.games");

	Initialize_gpGlobals_simTicksThisFrame(hGameData);
	CreateDetour_AdjustPlayerTimeBase(hGameData);

	delete hGameData;

	RegConsoleCmd("sm_clockcorrection", Cmd_SetClockCorrection, 	"sm_clockcorrection <value> - Sets a client's individual clock correction msecs value");
	RegConsoleCmd("sm_ccr", 			Cmd_SetClockCorrection,		"sm_clockcorrection <value> - Sets a client's individual clock correction msecs value");
	RegConsoleCmd("sm_debugccr", 		Cmd_DebugClockCorrection, 	"Prints [client clock - server clock] and max deviation to console");
}

// void CBasePlayer::AdjustPlayerTimeBase( int simulation_ticks )
public MRESReturn Detour_AdjustPlayerTimeBase(int pThis, DHookParam hParams)
{
	if (IsFakeClient(pThis)) return MRES_Ignored;

	int simulation_ticks = hParams.Get(1);
	if (simulation_ticks < 0) return MRES_Supercede;

	int simTicksThisFrame = LoadFromAddress(gpGlobals_simTicksThisFrame, NumberType_Int32);

	if (MaxClients == 1)
	{
		SetEntProp(pThis, Prop_Send, "m_nTickBase", GetGameTickCount() - simulation_ticks + simTicksThisFrame);
	}
	else
	{
		int m_nTickBase = GetEntProp(pThis, Prop_Send, "m_nTickBase");	

		int nCorrectionTicks = g_ticksClockCorrection[pThis];
		int	nIdealFinalTick = GetGameTickCount() + nCorrectionTicks;
		int nEstimatedFinalTick = m_nTickBase + simulation_ticks;
		
		int	too_fast_limit = nIdealFinalTick + nCorrectionTicks;
		int	too_slow_limit = nIdealFinalTick - nCorrectionTicks;

		if ( nEstimatedFinalTick > too_fast_limit || // If client gets ahead of this, we'll need to correct
			 nEstimatedFinalTick < too_slow_limit )  // If client falls behind  this, we'll also need to correct
		{
			int nCorrectedTick = nIdealFinalTick - simulation_ticks + simTicksThisFrame;
			SetEntProp(pThis, Prop_Send, "m_nTickBase", nCorrectedTick);
			if (g_debugClockCorrection[pThis])
				PrintToConsole(pThis, "[CCR] diff = %4d | max abs diff = %4d\n", nEstimatedFinalTick - nIdealFinalTick, nCorrectionTicks);
		}
	}

	return MRES_Supercede;
}

public Action Cmd_SetClockCorrection(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] clock correction is %.2f msecs (%d ticks)", g_flClockCorrection[client], g_ticksClockCorrection[client]);
		return Plugin_Handled;
	}

	char sValue[32];
	GetCmdArg(1, sValue, sizeof(sValue));

	float flValue = StringToFloat(sValue);
	g_flClockCorrection[client] = flValue;
	g_ticksClockCorrection[client] = MStoTicks(g_flClockCorrection[client]);

	char buffer[32];
    FloatToString(flValue, buffer, sizeof(buffer));
    SetClientCookie(client, g_hClockCorrection, buffer);

	ReplyToCommand(client, "[SM] Set clock correction value to %.2f msecs (%d ticks)", g_flClockCorrection[client], g_ticksClockCorrection[client]);
	return Plugin_Handled;
}

public Action Cmd_DebugClockCorrection(int client, int args)
{
	g_debugClockCorrection[client] = !g_debugClockCorrection[client];
	ReplyToCommand(client, "[SM] Clock correction debug - %s", g_debugClockCorrection[client] ? "ON" : "OFF");
	return Plugin_Handled;
}


void Initialize_gpGlobals_simTicksThisFrame(GameData gd)
{
	// To check gpGlobals for correctness
	Address addr_gpGlobals_tickcount = gd.GetAddress("gpGlobals::tickcount");
	if (addr_gpGlobals_tickcount == Address_Null)
	{
		delete gd;
		SetFailState("Failed to get gpGlobals::tickcount address");
	}
	int gpGlobals_tickcount = LoadFromAddress(addr_gpGlobals_tickcount, NumberType_Int32);
	if (gpGlobals_tickcount != GetGameTickCount())
	{
		delete gd;
		SetFailState("gpGlobals_tickcount != GetGameTickCount() | wrong gpGlobals or its offsets");
	}
	PrintToServer("%x = addr_gpGlobals_tickcount\n", addr_gpGlobals_tickcount);

	gpGlobals_simTicksThisFrame = gd.GetAddress("gpGlobals::simTicksThisFrame");
	if (gpGlobals_simTicksThisFrame == Address_Null)
	{
		delete gd;
		SetFailState("Failed to get gpGlobals::simTicksThisFrame address");
	}
}

void CreateDetour_AdjustPlayerTimeBase(GameData gd)
{
	// void CBasePlayer::AdjustPlayerTimeBase( int simulation_ticks )
	g_hDetourAdjustPlayerTimeBase = new DynamicDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_CBaseEntity);
	if (g_hDetourAdjustPlayerTimeBase == null ||
	    !g_hDetourAdjustPlayerTimeBase.SetFromConf(gd, SDKConf_Signature, "CBasePlayer::AdjustPlayerTimeBase"))
	{
		delete gd;
		SetFailState("Failed to find signature for CBasePlayer::AdjustPlayerTimeBase");
	}

	g_hDetourAdjustPlayerTimeBase.AddParam(HookParamType_Int); // int simulation_ticks

	if (!g_hDetourAdjustPlayerTimeBase.Enable(Hook_Pre, Detour_AdjustPlayerTimeBase))
	{
		delete gd;
		SetFailState("Failed to enable detour for CBasePlayer::AdjustPlayerTimeBase");
	}
}

public void OnClientCookiesCached(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    char value[32];

    GetClientCookie(client, g_hClockCorrection, value, sizeof(value));

    if (value[0] != '\0')
        g_flClockCorrection[client] = StringToFloat(value);
    else
        g_flClockCorrection[client] = DEFAULT_CLOCKCORRECTION; // Default value for new players.

	g_ticksClockCorrection[client] = MStoTicks(g_flClockCorrection[client]);
	g_debugClockCorrection[client] = false;
}


int MStoTicks(float msecs)
{
    return RoundFloat(0.5 + (msecs / 1000.0) / GetTickInterval());
}

void initializeArrays()
{
	for (int i = 0; i < MAXPLAYERS + 1; i++)
	{
		g_flClockCorrection[i] = DEFAULT_CLOCKCORRECTION;
		g_ticksClockCorrection[i] = MStoTicks(g_flClockCorrection[i]);
		g_debugClockCorrection[i] = false;
	}
}
