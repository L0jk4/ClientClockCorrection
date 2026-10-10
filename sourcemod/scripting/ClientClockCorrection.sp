#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <clientprefs>
#include <shavit>
#include <sdktools>
#include <dhooks>

#undef REQUIRE_PLUGIN
#include <shavit/partner>
#define REQUIRE_PLUGIN

ConVar        g_hCvarClockCorrection;
DynamicDetour g_hDetourAdjustPlayerTimeBase;

Handle g_hClockCorrection = null;
float g_flClockCorrection[MAXPLAYERS + 1]; 

Address gpGlobals_simTicksThisFrame = Address_Null;

public Plugin myinfo =
{
	name        = "Per-client clock correction",
	author      = "Lojka",
	description = "Remakes CBasePlayer::AdjustPlayerTimeBase with per-client clock correction value",
	version     = "1.0.0",
	url         = "https://github.com/L0jk4/ClientClockCorrection/tree/bits"
};

public void OnPluginStart()
{
	g_hCvarClockCorrection = FindConVar("sv_clockcorrection_msecs");
	if (g_hCvarClockCorrection == null)
		SetFailState("Could not find convar sv_clockcorrection_msecs");

	g_hClockCorrection = RegClientCookie("clock_correction", "Per-player clock correction value", CookieAccess_Private);

	GameData hGameData = new GameData("ClientClockCorrection.games");
	if (hGameData == null)
		SetFailState("Could not load gamedata \"%s\"", "ClientClockCorrection.games");

	Address gpGlobals = hGameData.GetMemSig("gpGlobals");
	if (gpGlobals == Address_Null)
	{
		delete hGameData;
		SetFailState("Failed to get gpGlobals address");
	}
	int jump_nBytes = hGameData.GetOffset("gpGlobals signature jump numbytes");
	if (jump_nBytes == -1)
	{
		delete hGameData;
		SetFailState("Failed to get gpGlobals::tickcount offset");
	}

	gpGlobals = LoadFromAddress(LoadFromAddress(gpGlobals + view_as<Address>(jump_nBytes), NumberType_Int32), NumberType_Int32);

	int simTicksThisFrame_offset = hGameData.GetOffset("gpGlobals::simTicksThisFrame");
	if (simTicksThisFrame_offset == -1)
	{
		delete hGameData;
		SetFailState("Failed to get gpGlobals::simTicksThisFrame offset");
	}
	gpGlobals_simTicksThisFrame = gpGlobals + view_as<Address>(simTicksThisFrame_offset);

	int tickcount = LoadFromAddress(gpGlobals + view_as<Address>(24), NumberType_Int32);
	
	// void CBasePlayer::AdjustPlayerTimeBase( int simulation_ticks )
	g_hDetourAdjustPlayerTimeBase = new DynamicDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_CBaseEntity);
	if (g_hDetourAdjustPlayerTimeBase == null ||
	    !g_hDetourAdjustPlayerTimeBase.SetFromConf(hGameData, SDKConf_Signature, "CBasePlayer::AdjustPlayerTimeBase"))
	{
		delete hGameData;
		SetFailState("Failed to find signature for CBasePlayer::AdjustPlayerTimeBase");
	}

	g_hDetourAdjustPlayerTimeBase.AddParam(HookParamType_Int); // int simulation_ticks

	if (!g_hDetourAdjustPlayerTimeBase.Enable(Hook_Pre, Detour_AdjustPlayerTimeBase))
	{
		delete hGameData;
		SetFailState("Failed to enable detour for CBasePlayer::AdjustPlayerTimeBase");
	}

	delete hGameData;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			g_flClockCorrection[i] = g_hCvarClockCorrection.FloatValue;
	}

	RegConsoleCmd("sm_clockcorrection", Cmd_SetClockCorrection, "sm_clockcorrection <value> - Sets a client's individual clock correction msecs value");
	RegConsoleCmd("sm_ccr", 			Cmd_SetClockCorrection, "sm_clockcorrection <value> - Sets a client's individual clock correction msecs value");

	RegConsoleCmd("sm_partnerclockcorrection", 	Cmd_PartnerSetClockCorrection, "sm_clockcorrection <value> - Sets a partner's individual clock correction msecs value");
	RegConsoleCmd("sm_pccr", 					Cmd_PartnerSetClockCorrection, "sm_clockcorrection <value> - Sets a partner's individual clock correction msecs value");
}

public void OnClientCookiesCached(int client)
{
    if (client <= 0 || client > MaxClients)
        return;

    char value[32];

    GetClientCookie(client, g_hClockCorrection, value, sizeof(value));

    if (value[0] != '\0')
    {
        g_flClockCorrection[client] = StringToFloat(value);
    }
    else
    {
        // Default value for new players.
        g_flClockCorrection[client] = g_hCvarClockCorrection.FloatValue;
    }
}

void SetClockCorrection(int client, float value)
{
	if (value < 0.0)
		value = 0.0;
	else if (value > 60.0)
		value = 60.0;

    g_flClockCorrection[client] = value;

    char buffer[32];
    FloatToString(value, buffer, sizeof(buffer));

    SetClientCookie(client, g_hClockCorrection, buffer);
}

// void CBasePlayer::AdjustPlayerTimeBase( int simulation_ticks )
public MRESReturn Detour_AdjustPlayerTimeBase(int pThis, DHookParam hParams)
{
	if (IsFakeClient(pThis))
		return MRES_Ignored;

	int simulation_ticks = hParams.Get(1);	// int simulation_ticks
	if (simulation_ticks < 0) return MRES_Supercede;

	int simTicksThisFrame = LoadFromAddress(gpGlobals_simTicksThisFrame, NumberType_Int32);

	if (MaxClients == 1)
	{
		SetEntProp(pThis, Prop_Send, "m_nTickBase", GetGameTickCount() - simulation_ticks + simTicksThisFrame);
	}
	else
	{
		int m_nTickBase = GetEntProp(pThis, Prop_Send, "m_nTickBase");	

		int nCorrectionTicks = MStoTicks(g_flClockCorrection[pThis]);
		int	nIdealFinalTick = GetGameTickCount() + nCorrectionTicks;
		int nEstimatedFinalTick = m_nTickBase + simulation_ticks;

		// If client gets ahead of this, we'll need to correct
		int	 too_fast_limit = nIdealFinalTick + nCorrectionTicks;
		// If client falls behind this, we'll also need to correct
		int	 too_slow_limit = nIdealFinalTick - nCorrectionTicks;

		if ( nEstimatedFinalTick > too_fast_limit ||
			nEstimatedFinalTick < too_slow_limit )
		{
			int nCorrectedTick = nIdealFinalTick - simulation_ticks + simTicksThisFrame;
			SetEntProp(pThis, Prop_Send, "m_nTickBase", nCorrectedTick);
		}
	}

	return MRES_Supercede;
}

public Action Cmd_SetClockCorrection(int client, int args)
{
	if (args < 1)
	{
		Shavit_PrintToChat(client, "Clock correction is %.2f msecs (%d ticks)", g_flClockCorrection[client], MStoTicks(g_flClockCorrection[client]));
		int partner = GetPartner(client);
		if (partner)
		{
			Shavit_PrintToChat(client, "Clock correction is %.2f msecs (%d ticks) - partner", g_flClockCorrection[partner], MStoTicks(g_flClockCorrection[partner]));
		}
		return Plugin_Handled;
	}

	char sValue[32];
	GetCmdArg(1, sValue, sizeof(sValue));

	float flValue = StringToFloat(sValue);
	SetClockCorrection(client, flValue);

	Shavit_PrintToChat(client, "Set clock correction value to %.2f msecs (%d ticks)", g_flClockCorrection[client], MStoTicks(g_flClockCorrection[client]));
	return Plugin_Handled;
}

public Action Cmd_PartnerSetClockCorrection(int client, int args)
{
	int partner = GetPartner(client);
	if (!partner)
	{
		Shavit_PrintToChat(client, "You need a partner to use this command!");	
		return Plugin_Handled;
	}

	if (args < 1)
	{
		Shavit_PrintToChat(client, "Clock correction is %.2f msecs (%d ticks) - partner", g_flClockCorrection[partner], MStoTicks(g_flClockCorrection[partner]));
		return Plugin_Handled;
	}

	char sValue[32];
	GetCmdArg(1, sValue, sizeof(sValue));

	float flValue = StringToFloat(sValue);
	SetClockCorrection(partner, flValue);

	Shavit_PrintToChat(partner, "Partner set your clock correction value to %.2f msecs (%d ticks)", g_flClockCorrection[partner],  MStoTicks(g_flClockCorrection[partner]));
	Shavit_PrintToChat(client, 	"Set partner's clock correction value to %.2f msecs (%d ticks)", 	g_flClockCorrection[partner],  MStoTicks(g_flClockCorrection[partner]));
	return Plugin_Handled;
}

int MStoTicks(float msecs)
{
    return RoundFloat(0.5 + (msecs / 1000.0) / GetTickInterval());
}

int GetPartner(int client)
{
	if (GetFeatureStatus(FeatureType_Native, "Timer_GetPartner") == FeatureStatus_Available)
	{
		return Timer_GetPartner(client);
	}
	return 0;
}
