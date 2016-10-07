#include <sdktools>
#include <sdkhooks>
#include <tf2_stocks>
#include <dhooks>

#pragma newdecls required;

int g_iPathTrack[MAXPLAYERS+1][2];
int g_iRobo[MAXPLAYERS+1];

float g_flNextHealTime[MAXPLAYERS+1];

bool g_bRobroEnabled[MAXPLAYERS+1];
bool g_bRobroMetal[MAXPLAYERS+1];
bool g_bRobroHelp[MAXPLAYERS+1];
bool g_bRobroUpgrade[MAXPLAYERS+1];
bool g_bRobroCollectMoney[MAXPLAYERS + 1];
int g_iRobroBehaviour[MAXPLAYERS+1];
float g_flRobroHomePosition[MAXPLAYERS+1][3];

Handle g_hSDKInputWrenchHit;
Handle g_hSDKSetNewActivity;
Handle g_hSDKGetLocomotionInterface;
Handle g_hSDKGetNBPtr;

Handle g_hGetRunSpeed;
Handle g_hGetGroundSpeed;
Handle g_hGetMaxAcceleration;

#define FOLLOW 0
#define HOME   1

//TODO:
//Better task planning
//Planning ahead
//Better pickin up of items
//Better "hitting buildings with wrench"

public Plugin myinfo = 
{
	name = "[TF2] RoboBuddy", 
	author = "Pelipoika", 
	description = "Replace your dispenser with a RobRo.", 
	version = "1.0", 
	url = ""
};

public void OnPluginStart()
{
	RegConsoleCmd("sm_robo", Command_Robo);
	RegConsoleCmd("sm_robro", Command_Robo);
	
	AddCommandListener(Listener_Destroy, "destroy");
	
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			OnClientPutInServer(i);
	
	HookEvent("player_builtobject", OnObjectBuilt);
	HookEvent("player_changeclass", OnPlayerChangeClass);
	HookEvent("rd_robot_impact", OnRoboDead, EventHookMode_Pre);
	
	Handle hConfig = LoadGameConfigFile("tf2.robobuddy");
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hConfig, SDKConf_Virtual, "CBaseObject::InputWrenchHit");
	PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer); //Player
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer); //CTFWrench
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);		//Hitloc
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);	//Did wrench hit do any work?
	if ((g_hSDKInputWrenchHit = EndPrepSDKCall()) == INVALID_HANDLE) SetFailState("Failed To create SDKCall for CBaseObject::InputWrenchHit offset");
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hConfig, SDKConf_Signature, "CTFRobotDestruction_Robot::SetNewActivity");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain); //Activity
	if ((g_hSDKSetNewActivity = EndPrepSDKCall()) == INVALID_HANDLE) SetFailState("Failed To create SDKCall for CTFRobotDestruction_Robot::SetNewActivity signature");

	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hConfig, SDKConf_Virtual, "CBaseCombatCharacter::MyNextBotPointer");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	if ((g_hSDKGetNBPtr = EndPrepSDKCall()) == INVALID_HANDLE) SetFailState("Failed to create SDKCall for CBaseCombatCharacter::MyNextBotPointer offset!");

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hConfig, SDKConf_Virtual, "CTFRobotDestruction_Robot::GetLocomotionInterface");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);	//Returns address of CRobotLocomotion
	if ((g_hSDKGetLocomotionInterface = EndPrepSDKCall()) == INVALID_HANDLE) SetFailState("Failed to create SDKCall for CTFRobotDestruction_Robot::GetLocomotionInterface offset!");

	int iOffset = GameConfGetOffset(hConfig, "CRobotLocomotion::GetRunSpeed");
	if(iOffset == -1) SetFailState("Failed to get offset of CRobotLocomotion::GetRunSpeed");
	g_hGetRunSpeed = DHookCreate(iOffset, HookType_Raw, ReturnType_Float, ThisPointer_Address, CRobotLocomotion_GetRunSpeed);
	
	iOffset = GameConfGetOffset(hConfig, "CRobotLocomotion::GetGroundSpeed");
	if(iOffset == -1) SetFailState("Failed to get offset of CRobotLocomotion::GetGroundSpeed");
	g_hGetGroundSpeed = DHookCreate(iOffset, HookType_Raw, ReturnType_Float, ThisPointer_Address, CRobotLocomotion_GetGroundSpeed);

	iOffset = GameConfGetOffset(hConfig, "NextBotGroundLocomotion::GetMaxAcceleration");
	if(iOffset == -1) SetFailState("Failed to get offset of NextBotGroundLocomotion::GetMaxAcceleration");
	g_hGetMaxAcceleration = DHookCreate(iOffset, HookType_Raw, ReturnType_Float, ThisPointer_Address, NextBotGroundLocomotion_GetMaxAcceleration);
	
	delete hConfig;
	
	AddNormalSoundHook(RandonmSH);
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	if (IsClientInGame(i))
		RemoveRobot(i);
}

public void OnMapStart()
{
	PrecacheSound("misc/rd_robot_explosion01.wav");
	PrecacheSound("weapons/rescue_ranger_teleport_receive_01.wav");
	PrecacheSound("weapons/rescue_ranger_teleport_receive_02.wav");
}

public void OnClientPutInServer(int client)
{
	g_bRobroEnabled[client] = false;
	g_flRobroHomePosition[client][0] = 0.0;
	g_flRobroHomePosition[client][1] = 0.0;
	g_flRobroHomePosition[client][2] = 0.0;
	g_iRobroBehaviour[client] = FOLLOW;
	g_bRobroMetal[client] = false;
	g_bRobroHelp[client] = false;
	g_bRobroUpgrade[client] = false;
	g_bRobroCollectMoney[client] = false;
	
	g_flNextHealTime[client] = GetGameTime();
	g_iRobo[client] = INVALID_ENT_REFERENCE;
	g_iPathTrack[client][0] = INVALID_ENT_REFERENCE;
	g_iPathTrack[client][1] = INVALID_ENT_REFERENCE;
}

public void OnClientDisconnect(int client)
{
	if (client > 0 && client <= MaxClients && IsClientInGame(client))
		RemoveRobot(client);
}

public MRESReturn CRobotLocomotion_GetRunSpeed(int pThis, Handle hReturn, Handle hParams)
{	
	DHookSetReturn(hReturn, 400.0);
	
	return MRES_Supercede;
}

public MRESReturn CRobotLocomotion_GetGroundSpeed(int pThis, Handle hReturn, Handle hParams)
{
	DHookSetReturn(hReturn, 400.0);
	
	return MRES_Supercede;
}

public MRESReturn NextBotGroundLocomotion_GetMaxAcceleration(int pThis, Handle hReturn, Handle hParams)
{	
	DHookSetReturn(hReturn, 1000.0);
	
	return MRES_Supercede;
}

public Action RandonmSH(clients[64], int &numClients, char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume, int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	if(entity > MaxClients)
	{
		char strName[64];
		GetEntPropString(entity, Prop_Data, "m_iName", strName, sizeof(strName));
		if(StrEqual(strName, "RobotHelper")) 
		{
			if(StrContains(sample, "tinybot_crosspaths_") != -1)
			{
				return Plugin_Stop;
			}
		}
	}
	
	return Plugin_Continue;
}

public Action Command_Robo(int client, int args)
{
	int robot = EntRefToEntIndex(g_iRobo[client]);
	int iCurrentMetal = GetEntProp(client, Prop_Data, "m_iAmmo", _, 3);
	
	Menu menu = CreateMenu(MenuRoboHandler);
	menu.SetTitle("RoBro - Control Panel");
	
	if (g_bRobroEnabled[client])
		menu.AddItem("0", "Replace Dispenser with a RoBro: On");
	else
		menu.AddItem("0", "Replace Dispenser with a RoBro: Off");
	
	if (g_flRobroHomePosition[client][0] != 0.0 && g_flRobroHomePosition[client][1] != 0.0 && g_flRobroHomePosition[client][2] != 0.0)
	{
		char display[64];
		Format(display, sizeof(display), "Home: %.0f %.0f %.0f", g_flRobroHomePosition[client][0], g_flRobroHomePosition[client][1], g_flRobroHomePosition[client][2]);
		menu.AddItem("1", display);
		
		if (g_iRobroBehaviour[client] == FOLLOW)
			menu.AddItem("2", "Behaviour: Follow");
		else if (g_iRobroBehaviour[client] == HOME)
			menu.AddItem("2", "Behaviour: Stay at Home");
	}
	else
	{
		menu.AddItem("1", "Home: NOT SET");
		
		if (g_iRobroBehaviour[client] == FOLLOW)
			menu.AddItem("2", "Behaviour: Follow (HOME NOT SET)", ITEMDRAW_DISABLED);
		else if (g_iRobroBehaviour[client] == HOME)
			menu.AddItem("2", "Behaviour: Stay at Home (HOME NOT SET)", ITEMDRAW_DISABLED);
	}
	
	if (g_bRobroMetal[client])
		menu.AddItem("3", "Gather metal: On");
	else
		menu.AddItem("3", "Gather metal: Off");
	
	if (g_bRobroUpgrade[client])
		menu.AddItem("4", "Upgrade Buildings: On");
	else
		menu.AddItem("4", "Upgrade Buildings: Off");
	
	if (g_bRobroHelp[client])
		menu.AddItem("5", "Help friendly Engineers: On");
	else
		menu.AddItem("5", "Help friendly Engineers: Off");
	
	if (robot != INVALID_ENT_REFERENCE)
		menu.AddItem("6", "Where are you?");
	else
		menu.AddItem("6", "Where are you? (ROBOT NOT ACTIVE)", ITEMDRAW_DISABLED);
	
	if (robot != INVALID_ENT_REFERENCE)
		menu.AddItem("7", "Where are you going?");
	else
		menu.AddItem("7", "Where are you going? (ROBOT NOT ACTIVE)", ITEMDRAW_DISABLED);
	
	if (CheckCommandAccess(client, "sm_rcon", ADMFLAG_ROOT, true))
		menu.AddItem("8", "Carry this");
	else
		menu.AddItem("8", "Carry this (NO ACCES)", ITEMDRAW_DISABLED);
	
	if (iCurrentMetal >= 100 && robot != INVALID_ENT_REFERENCE)
		menu.AddItem("9", "Teleport to me");
	else if (robot == INVALID_ENT_REFERENCE)
		menu.AddItem("9", "Teleport to me (ROBOT NOT ACTIVE)", ITEMDRAW_DISABLED);
	else if (iCurrentMetal < 100)
		menu.AddItem("9", "Teleport to me (NOT ENOUGH METAL)", ITEMDRAW_DISABLED);
	
	if(g_bRobroCollectMoney[client])
		menu.AddItem("10", "Collect Money: On");
	else
		menu.AddItem("10", "Collect Money: Off");
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
	
	return Plugin_Handled;
}

public int MenuRoboHandler(Handle menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		switch (param2)
		{
			case 0:
			{
				if (g_bRobroEnabled[param1])
				{
					int robo = EntRefToEntIndex(g_iRobo[param1]);
					if (robo != INVALID_ENT_REFERENCE)
					{
						RemoveRobot(param1);
					}
					
					g_bRobroEnabled[param1] = false;
				}
				else
				{
					g_bRobroEnabled[param1] = true;
				}
			}
			case 1:
			{
				if (GetEntPropEnt(param1, Prop_Data, "m_hGroundEntity") != -1)
				{
					float flPos[3];
					GetClientAbsOrigin(param1, flPos);
					
					g_flRobroHomePosition[param1][0] = flPos[0];
					g_flRobroHomePosition[param1][1] = flPos[1];
					g_flRobroHomePosition[param1][2] = flPos[2];
				}
			}
			case 2:
			{
				if (g_iRobroBehaviour[param1] == FOLLOW) //Follow
					g_iRobroBehaviour[param1] = HOME;
				else if (g_iRobroBehaviour[param1] == HOME) //Stay at home
					g_iRobroBehaviour[param1] = FOLLOW;
			}
			case 3:
			{
				if (g_bRobroMetal[param1])
					g_bRobroMetal[param1] = false;
				else
					g_bRobroMetal[param1] = true;
			}
			case 4:
			{
				if (g_bRobroUpgrade[param1])
					g_bRobroUpgrade[param1] = false;
				else
					g_bRobroUpgrade[param1] = true;
			}
			case 5:
			{
				if (g_bRobroHelp[param1])
					g_bRobroHelp[param1] = false;
				else
					g_bRobroHelp[param1] = true;
			}
			case 6:
			{
				int robot = EntRefToEntIndex(g_iRobo[param1]);
				if (robot != INVALID_ENT_REFERENCE)
				{
					Annotate(robot, param1, "I'm Here!");
				}
			}
			case 7:
			{
		/*		int track = EntRefToEntIndex(g_iPathTrack[param1][0]);
				if (track != INVALID_ENT_REFERENCE)
				{
					GetEntPropVector(target, Prop_Send, "m_vecOrigin", pPos);
					Annotate(track, param1, "Here");
				}*/
			}
			case 8:
			{
				int robot = EntRefToEntIndex(g_iRobo[param1]);
				if (robot != INVALID_ENT_REFERENCE)
				{
					int target = GetClientAimTarget(param1, false);
					if (IsValidEntity(target) && target > MaxClients)
					{
						float pPos[3], pAng[3];
						
						SetVariantString("!activator");
						AcceptEntityInput(target, "SetParent", robot);
						
						SetVariantString("bip_base");
						AcceptEntityInput(target, "SetParentAttachment", robot);
						
						GetEntPropVector(target, Prop_Send, "m_vecOrigin", pPos);
						GetEntPropVector(target, Prop_Send, "m_angRotation", pAng);
						
						pAng[0] = 90.0; //Fix the retarded rotations of this attachment point
						pAng[1] = 0.0;
						pAng[2] = -90.0;
						
						pPos[0] += 17.5;
						pPos[1] += 40.0;
						
						SetEntPropVector(target, Prop_Send, "m_vecOrigin", pPos);
						SetEntPropVector(target, Prop_Send, "m_angRotation", pAng);
					}
				}
			}
			case 9:
			{
				int iCurrentMetal = GetEntProp(param1, Prop_Data, "m_iAmmo", _, 3);
				if (iCurrentMetal >= 100)
				{
					int robot = EntRefToEntIndex(g_iRobo[param1]);
					if (robot != INVALID_ENT_REFERENCE)
					{
						float flRPos[3], flAngle[3], flPos[3];
						GetEntPropVector(robot, Prop_Data, "m_vecOrigin", flRPos);
						GetClientAbsOrigin(param1, flPos);
						GetClientAbsAngles(param1, flAngle);
						
						EmitSoundToAll(GetRandomInt(1, 2) == 1 ? "weapons/rescue_ranger_teleport_receive_01.wav" : "weapons/rescue_ranger_teleport_receive_02.wav", robot);
						
						AttachParticle(robot, TF2_GetClientTeam(param1) == TFTeam_Blue ? "teleported_blue" : "teleported_red", "", 0.0, 3);
						
						SetEntProp(param1, Prop_Data, "m_iAmmo", iCurrentMetal - 100, _, 3)
						
						TeleportEntity(robot, flPos, flAngle, NULL_VECTOR);
						
						g_iRobroBehaviour[param1] = FOLLOW;
					}
				}
			}
			case 10:
			{
				if(g_bRobroCollectMoney[param1])
					g_bRobroCollectMoney[param1] = false;
				else
					g_bRobroCollectMoney[param1] = true;
			}
		}
		
		Command_Robo(param1, 0);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
}

public Action OnObjectBuilt(Handle event, const char[] name, bool dontBroadcast) //Object built
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	int objectEnt = GetEventInt(event, "index");
	int objectType = GetEventInt(event, "object");
	
	if(TF2_IsMvM() && TF2_GetClientTeam(client) == TFTeam_Blue)
		return Plugin_Continue;
	
	if (objectType == view_as<int>(TFObject_Dispenser) && g_bRobroEnabled[client])
	{
		DispatchKeyValue(objectEnt, "defaultupgrade", "3");
		SetEntPropFloat(objectEnt, Prop_Send, "m_flPercentageConstructed", 1.0);
		SetEntProp(objectEnt, Prop_Send, "m_bBuilding", 0);
		SetEntProp(objectEnt, Prop_Send, "m_iHealth", 5000);
		SetEntProp(objectEnt, Prop_Send, "m_bDisabled", 1);
		SetEntProp(objectEnt, Prop_Send, "m_iUpgradeLevel", 3);
		
		int robo = EntRefToEntIndex(g_iRobo[client]);
		if (robo == INVALID_ENT_REFERENCE)
		{
			RemoveRobot(client);
			float flPos[3], flAng[3];
			GetEntPropVector(objectEnt, Prop_Data, "m_vecOrigin", flPos);
			GetEntPropVector(objectEnt, Prop_Data, "m_angAbsRotation", flAng);
			
			SpawnRobot(client, flPos, flAng);
		}
		
		DispatchKeyValueVector(objectEnt, "origin", view_as<float>({0.0, 0.0, 5000.0}));
	}
	
	return Plugin_Continue;
}

public Action OnPlayerChangeClass(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	int robo = EntRefToEntIndex(g_iRobo[client]);
	if (robo != INVALID_ENT_REFERENCE)
	{
		RemoveRobot(client);
	}
}

public Action OnRoboDead(Handle event, const char[] name, bool dontBroadcast)
{
	int robo = GetEventInt(event, "entindex");
	if (IsValidEntity(robo))
	{
		int client = GetEntPropEnt(robo, Prop_Send, "m_hOwnerEntity");
		if (client > 0 && client <= MaxClients && IsClientInGame(client))
		{
			g_iRobo[client] = INVALID_ENT_REFERENCE;
			int index = -1;
			while ((index = FindEntityByClassname(index, "obj_dispenser")) != -1)
				if (IsValidBuilding(index) && !IsMiniBuilding(index))
					if (GetEntPropEnt(index, Prop_Send, "m_hBuilder") == client && g_bRobroEnabled[client])
						AcceptEntityInput(index, "Kill");
			
			int path = EntRefToEntIndex(g_iPathTrack[client][0]);
			if (path != INVALID_ENT_REFERENCE)
			{
				AcceptEntityInput(path, "KillHierarchy");
				path = INVALID_ENT_REFERENCE;
			}
			
			path = EntRefToEntIndex(g_iPathTrack[client][1]);
			if (EntRefToEntIndex(path) != INVALID_ENT_REFERENCE)
			{
				AcceptEntityInput(path, "KillHierarchy");
				path = INVALID_ENT_REFERENCE;
			}
			
			g_flNextHealTime[client] = GetGameTime();
			g_iRobo[client] = INVALID_ENT_REFERENCE;
			g_iPathTrack[client][0] = INVALID_ENT_REFERENCE;
			g_iPathTrack[client][1] = INVALID_ENT_REFERENCE;
		}
	}
}

public Action Listener_Destroy(int client, char[] cmd, int args)
{
	if (args < 1)return Plugin_Continue;
	if (TF2_GetPlayerClass(client) != TFClass_Engineer)return Plugin_Continue;
	
	char arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	
	TFObjectType building = view_as<TFObjectType>(StringToInt(arg1));
	if (building == TFObject_Dispenser)
	{
		int robo = EntRefToEntIndex(g_iRobo[client]);
		if (robo == INVALID_ENT_REFERENCE && g_bRobroEnabled[client])
		{
			PrintToChat(client, "Please wait for your robot to finish constructing");
			return Plugin_Handled;
		}
		else if (robo != INVALID_ENT_REFERENCE)
		{
			RemoveRobot(client);
		}
	}
	
	return Plugin_Continue;
}

public void OnPass(const char[] output, int caller, int activator, float delay)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			int path = EntRefToEntIndex(g_iPathTrack[i][0]);
			if (path == caller)
			{
				DispatchKeyValue(activator, "targetname", "RobotHelper");
				SetEntPropEnt(activator, Prop_Send, "m_hOwnerEntity", i);
				SetEntProp(activator, Prop_Send, "m_bClientSideAnimation", 1);
				
				g_iRobo[i] = EntIndexToEntRef(activator);
				
				SDKHook(activator, SDKHook_Think, OnRoboThink);
				SDKHook(activator, SDKHook_OnTakeDamage, OnRoboDamaged);
				
				Address pNB = SDKCall(g_hSDKGetNBPtr, activator);
				Address pLocomotion = SDKCall(g_hSDKGetLocomotionInterface, pNB);
				if(pLocomotion != Address_Null)
				{
					DHookRaw(g_hGetRunSpeed, true, pLocomotion); 
					DHookRaw(g_hGetGroundSpeed, true, pLocomotion);
					DHookRaw(g_hGetMaxAcceleration, true, pLocomotion);
				}
			}
		}
	}
	
	UnhookSingleEntityOutput(caller, "OnPass", OnPass);
}

public Action OnClientCommand(int client, int args)
{
	char strCmd[16];
	GetCmdArg(0, strCmd, sizeof(strCmd));
	
	if (StrEqual(strCmd, "jointeam"))
	{
		RemoveRobot(client);
	}
}

public Action OnRoboDamaged(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	int iHealth = GetEntProp(victim, Prop_Send, "m_iHealth");
	
	if (damage < iHealth)
	{
		SetEntProp(victim, Prop_Send, "m_iHealth", (iHealth - RoundToNearest(damage)));
		
		damage = 0.0;
		return Plugin_Handled;
	}
	else //RIP
	{
		int client = GetEntPropEnt(victim, Prop_Send, "m_hOwnerEntity");
		if (IsClientInGame(client))
		{
			int path = EntRefToEntIndex(g_iPathTrack[client][0]);
			if (path != INVALID_ENT_REFERENCE)
			{
				AcceptEntityInput(path, "KillHierarchy");
				path = INVALID_ENT_REFERENCE;
			}
			
			path = EntRefToEntIndex(g_iPathTrack[client][1]);
			if (EntRefToEntIndex(path) != INVALID_ENT_REFERENCE)
			{
				AcceptEntityInput(path, "KillHierarchy");
				path = INVALID_ENT_REFERENCE;
			}
			
			g_flNextHealTime[client] = GetGameTime();
			g_iRobo[client] = INVALID_ENT_REFERENCE;
			g_iPathTrack[client][0] = INVALID_ENT_REFERENCE;
			g_iPathTrack[client][1] = INVALID_ENT_REFERENCE;
		}
		
		return Plugin_Continue;
	}
}

public Action OnRoboThink(int entity)
{
	int client = GetEntPropEnt(entity, Prop_Send, "m_hOwnerEntity");
	if (IsClientInGame(client))
	{	
		int iBuilding = -1;
		
		int iUpgradeAbleBuilding = FindUpgradeAbleBuilding(client);
		int iSappedBuilding      = FindSappedBuilding(client);
		int iMostDamagedBuilding = FindMostDamagedBuilding(client);
		
		if (iSappedBuilding != -1)                                      iBuilding = iSappedBuilding;
		else if (iMostDamagedBuilding != -1)                            iBuilding = iMostDamagedBuilding;
		else if (iUpgradeAbleBuilding != -1 && g_bRobroUpgrade[client]) iBuilding = iUpgradeAbleBuilding;
		
		int iCurrentMetal = GetEntProp(client, Prop_Data, "m_iAmmo", _, 3);
		
		if (IsValidBuilding(iBuilding) && iCurrentMetal > 0)
		{
			float flRPos[3], flBuildingPos[3];
			GetEntPropVector(entity, Prop_Data, "m_vecOrigin", flRPos);
			GetEntPropVector(iBuilding, Prop_Data, "m_vecOrigin", flBuildingPos);
			
			TelePortTracks(client, flBuildingPos);
			
			if (GetVectorDistance(flRPos, flBuildingPos) <= 85.0)
			{
				float vecTargetEyeAng[3];
				MakeVectorFromPoints(flBuildingPos, flRPos, vecTargetEyeAng);
				GetVectorAngles(vecTargetEyeAng, vecTargetEyeAng);
				
				vecTargetEyeAng[0] = 0.0;
				vecTargetEyeAng[1] += 180.0;
				vecTargetEyeAng[2] = 0.0;
				
				TeleportEntity(entity, NULL_VECTOR, vecTargetEyeAng, NULL_VECTOR);
				
				if (g_flNextHealTime[client] <= GetGameTime())
				{
					int wrench = GetPlayerWeaponSlot(client, TFWeaponSlot_Melee);
					if (IsValidEntity(wrench))
					{
						if(iSappedBuilding != -1)
						{
							SDKHooks_TakeDamage(iBuilding, wrench, client, 50.0);	
						}
					
						SDKCall(g_hSDKInputWrenchHit, iBuilding, client, wrench, flBuildingPos);
						
						char sound[PLATFORM_MAX_PATH];
						Format(sound, PLATFORM_MAX_PATH, "weapons/wrench_hit_build_success%i.wav", GetRandomInt(1, 2));
						EmitSoundToAll(sound, iBuilding);
						
						g_flNextHealTime[client] = GetGameTime() + 0.5;
					}
				}
				SDKCall(g_hSDKSetNewActivity, entity, 1773);
			}
			else
				SDKCall(g_hSDKSetNewActivity, entity, 1774);
		}
		else
		{
			float vecGoalPos[3];
		
			if (g_iRobroBehaviour[client] == HOME)
			{
				vecGoalPos = g_flRobroHomePosition[client];
			}
			else
			{
				float flPos[3];
				GetClientAbsOrigin(client, flPos);
				vecGoalPos = flPos;
			}
		
			int ammo = FindNearestAmmoPack(entity);
			if (ammo != -1 && g_bRobroMetal[client] && iCurrentMetal < 200 && IsPlayerAlive(client))
			{
				float flAmmoPos[3], flPos[3];
				GetEntPropVector(ammo,   Prop_Data, "m_vecOrigin", flAmmoPos);
				GetEntPropVector(entity, Prop_Data, "m_vecOrigin", flPos);
				
				flAmmoPos[2] += 10.0;
				
				if (GetVectorDistance(flAmmoPos, flPos) <= 85.0 && IsPointVisible(entity, flPos, flAmmoPos))
				{
					float flPlayer[3];
					GetClientAbsOrigin(client, flPlayer);
					flPlayer[2] += 20.0;
					
					TeleportEntity(ammo, flPlayer, NULL_VECTOR, NULL_VECTOR);
				}
				
				vecGoalPos = flAmmoPos;
			}
			else if(g_bRobroCollectMoney[client])
			{
				float flMPos[3];
				bool bFound = false;
			
				float flPPos[3];
				GetEntPropVector(entity, Prop_Data, "m_vecOrigin", flPPos);
				flPPos[2] += 64.0;
			
				int x = -1;	
				while ((x = FindEntityByClassname(x, "item_currency*")) != -1)
				{
					GetEntPropVector(x, Prop_Data, "m_vecOrigin", flMPos);
					
					float flDistance = GetVectorDistance(flPPos, flMPos);
					
					flMPos[2] += 10.0;
					
					if(flDistance <= 500.0 && IsPointVisible(entity, flPPos, flMPos))
					{
						if(flDistance <= 64.0)
						{
							float flPlayer[3];
							GetClientAbsOrigin(client, flPlayer);
							flPlayer[2] += 20.0;
							TeleportEntity(x, flPlayer, NULL_VECTOR, NULL_VECTOR);
						}
						else
						{
							float flVecTo[3];
							MakeVectorFromPoints(flMPos, flPPos, flVecTo);
							NormalizeVector(flVecTo, flVecTo);
							ScaleVector(flVecTo, 500.0);
							
							int iFlags = GetEntityFlags(x);
							iFlags &= ~FL_ONGROUND;
							SetEntityFlags(x, iFlags);
							TeleportEntity(x, NULL_VECTOR, NULL_VECTOR, flVecTo);
						}
					}
					
					if(GetEntityFlags(x) & FL_ONGROUND)
						bFound = true;
				}
				
				if(bFound)
				{
					vecGoalPos = flMPos;
				}
			}
			
			TelePortTracks(client, vecGoalPos);

			SDKCall(g_hSDKSetNewActivity, entity, 1774);
		}
	}
}

stock int FindMostDamagedBuilding(int client)
{
	int iBestTarget = -1;
	int iDmg = 0;
	
	int index = -1;
	while ((index = FindEntityByClassname(index, "obj_*")) != -1)
	{
		if (IsValidBuilding(index) && !IsMiniBuilding(index) && IsEntityOnSameTeam(index, client))
		{
			if (g_bRobroHelp[client] || GetEntPropEnt(index, Prop_Send, "m_hBuilder") == client)
			{
				int iHealth = GetEntProp(index, Prop_Send, "m_iHealth");
				int iMaxHealth = GetEntProp(index, Prop_Send, "m_iMaxHealth");
				
				if (iHealth != iMaxHealth)
				{
					int iDamageToRepair = iMaxHealth - iHealth;
					if (iDamageToRepair > iDmg)
					{
						iDmg = iDamageToRepair;
						iBestTarget = index;
					}
				}
			}
		}
	}
	
	return iBestTarget;
}

stock int FindUpgradeAbleBuilding(int client)
{
	int iBestTarget = -1;
	
	int index = -1;
	while ((index = FindEntityByClassname(index, "obj_teleporter")) != -1)
	{
		if (IsValidBuilding(index) && IsEntityOnSameTeam(index, client) && !IsMiniBuilding(index) && GetEntProp(index, Prop_Send, "m_iUpgradeLevel") < 3)
		{
			if (g_bRobroHelp[client] || GetEntPropEnt(index, Prop_Send, "m_hBuilder") == client)
			{
				iBestTarget = index;
			}
		}
	}
	
	index = -1;
	while ((index = FindEntityByClassname(index, "obj_dispenser")) != -1)
	{
		if (IsValidBuilding(index) && IsEntityOnSameTeam(index, client) && !IsMiniBuilding(index) && GetEntProp(index, Prop_Send, "m_iUpgradeLevel") < 3)
		{
			if (g_bRobroHelp[client] || GetEntPropEnt(index, Prop_Send, "m_hBuilder") == client && g_bRobroEnabled[client])
			{
				iBestTarget = index;
			}
		}
	}
	
	index = -1;
	while ((index = FindEntityByClassname(index, "obj_sentrygun")) != -1)
	{
		if (IsValidBuilding(index) && IsEntityOnSameTeam(index, client) && !IsMiniBuilding(index) && (GetEntProp(index, Prop_Send, "m_iUpgradeLevel") < 3 || GetEntProp(index, Prop_Send, "m_iAmmoShells") <= 100))
		{
			if (g_bRobroHelp[client] || GetEntPropEnt(index, Prop_Send, "m_hBuilder") == client)
			{
				iBestTarget = index;
			}
		}
	}
	
	return iBestTarget;
}

stock int FindNearestAmmoPack(int robot)
{
	float flPos[3];
	GetEntPropVector(robot, Prop_Data, "m_vecOrigin", flPos);
	
	int iBestTarget = -1;
	float flSmallestDistance = 5000.0;
	
	int index = -1;
	while ((index = FindEntityByClassname(index, "item_ammopack_*")) != -1)
	{
		if (GetEntProp(index, Prop_Send, "m_fEffects") != 32)
		{
			float flAmmoPos[3];
			GetEntPropVector(index, Prop_Data, "m_vecOrigin", flAmmoPos);
			
			float flDistance = GetVectorDistance(flPos, flAmmoPos);
			
			if (flDistance <= flSmallestDistance)
			{
				iBestTarget = index;
				flSmallestDistance = flDistance;
			}
		}
	}
	
	index = -1;
	while ((index = FindEntityByClassname(index, "tf_ammo_pack")) != -1)
	{
		if (GetEntProp(index, Prop_Send, "m_fEffects") != 32)
		{
			float flAmmoPos[3];
			GetEntPropVector(index, Prop_Data, "m_vecOrigin", flAmmoPos);
			
			char strModel[PLATFORM_MAX_PATH];
			GetEntPropString(index, Prop_Data, "m_ModelName", strModel, PLATFORM_MAX_PATH);
			
			float flDistance = GetVectorDistance(flPos, flAmmoPos);
			
			if (flDistance <= flSmallestDistance && StrContains(strModel, "gib") == -1)
			{
				iBestTarget = index;
				flSmallestDistance = flDistance;
			}
		}
	}
	
	return iBestTarget;
}

stock int FindSappedBuilding(int client)
{
	int index = -1;
	while ((index = FindEntityByClassname(index, "obj_*")) != -1)
	{
		if (IsValidEntity(index) && IsEntityOnSameTeam(index, client) && GetEntProp(index, Prop_Send, "m_bHasSapper") == 1)
		{
			if (g_bRobroHelp[client] || GetEntPropEnt(index, Prop_Send, "m_hBuilder") == client)
			{
				return index;
			}
		}
	}
	
	return -1;
}

stock void SpawnRobot(int client, float flPos[3], float flAng[3])
{
	RemoveRobot(client);
	
	char targetname0[PLATFORM_MAX_PATH], targetname1[PLATFORM_MAX_PATH];
	
	int iPath[2];
	iPath[0] = CreateEntityByName("path_track");
	iPath[1] = CreateEntityByName("path_track");
	
	if (IsValidEntity(iPath[0]) && IsValidEntity(iPath[1]))
	{
		Format(targetname0, sizeof(targetname0), "path_%i_%i", client, iPath[0]);
		Format(targetname1, sizeof(targetname1), "path_%i_%i", client, iPath[1]);
		DispatchKeyValueVector(iPath[0], "origin", flPos);
		DispatchKeyValueVector(iPath[1], "origin", flPos);
		DispatchKeyValueVector(iPath[0], "angles", flAng);
		DispatchKeyValueVector(iPath[1], "angles", flAng);
		DispatchKeyValue(iPath[0], "targetname", targetname0);
		DispatchKeyValue(iPath[1], "targetname", targetname1);
		DispatchKeyValue(iPath[0], "orientationtype", "1");
		DispatchKeyValue(iPath[1], "orientationtype", "1");
		DispatchKeyValue(iPath[0], "target", targetname1);
		DispatchKeyValue(iPath[1], "target", targetname0);
		DispatchSpawn(iPath[0]);
		DispatchSpawn(iPath[1]);
		ActivateEntity(iPath[0]);
		ActivateEntity(iPath[1]);
		HookSingleEntityOutput(iPath[0], "OnPass", OnPass);
		
		g_iPathTrack[client][0] = EntIndexToEntRef(iPath[0]);
		g_iPathTrack[client][1] = EntIndexToEntRef(iPath[1]);
	}
	
	int SpawnGroup = CreateEntityByName("tf_robot_destruction_spawn_group");
	if (SpawnGroup != -1)
	{
		char team[2];
		Format(team, 2, "%i", GetClientTeam(client));
		DispatchKeyValueVector(SpawnGroup, "origin", flPos);
		DispatchKeyValueVector(SpawnGroup, "angles", flAng);
		DispatchKeyValue(SpawnGroup, "group_number", "1");
		DispatchKeyValue(SpawnGroup, "hud_icon", "../HUD/hud_bot_worker3_outline_blue");
		DispatchKeyValue(SpawnGroup, "respawn_time", "60");
		DispatchKeyValue(SpawnGroup, "targetname", "botgroup");
		DispatchKeyValue(SpawnGroup, "team_number", team);
		DispatchSpawn(SpawnGroup);
		ActivateEntity(SpawnGroup);
	}
	
	int Spawner = CreateEntityByName("tf_robot_destruction_robot_spawn");
	if (Spawner != -1)
	{
		DispatchKeyValueVector(Spawner, "origin", flPos);
		DispatchKeyValueVector(Spawner, "angles", flAng);
		DispatchKeyValue(Spawner, "gibs", "0");
		DispatchKeyValue(Spawner, "startpath", targetname0);
		DispatchKeyValue(Spawner, "health", "10000");
		DispatchKeyValue(Spawner, "spawngroup", "botgroup");
		DispatchKeyValue(Spawner, "type", "0"); //Smallest one
		DispatchSpawn(Spawner);
		ActivateEntity(Spawner);
		AcceptEntityInput(Spawner, "SpawnRobot");
		AcceptEntityInput(SpawnGroup, "Kill");
		AcceptEntityInput(Spawner, "Kill");
	}
}

stock void RemoveRobot(int client)
{
	int robot = EntRefToEntIndex(g_iRobo[client]);
	if (robot != INVALID_ENT_REFERENCE)
	{
		SDKHooks_TakeDamage(robot, 0, 0, 99999.0, DMG_CRUSH);
		AcceptEntityInput(robot, "KillHierarchy"); //Simply using Kill causes the server to crash
		robot = INVALID_ENT_REFERENCE;
		
		int index = -1;
		while ((index = FindEntityByClassname(index, "obj_dispenser")) != -1)
			if (IsValidBuilding(index) && !IsMiniBuilding(index))
			if (GetEntPropEnt(index, Prop_Send, "m_hBuilder") == client && g_bRobroEnabled[client])
			AcceptEntityInput(index, "Kill");
	}
	
	int path = EntRefToEntIndex(g_iPathTrack[client][0]);
	if (path != INVALID_ENT_REFERENCE)
	{
		AcceptEntityInput(path, "KillHierarchy");
		path = INVALID_ENT_REFERENCE;
	}
	
	path = EntRefToEntIndex(g_iPathTrack[client][1]);
	if (EntRefToEntIndex(path) != INVALID_ENT_REFERENCE)
	{
		AcceptEntityInput(path, "KillHierarchy");
		path = INVALID_ENT_REFERENCE;
	}
	
	g_flNextHealTime[client] = GetGameTime();
	g_iRobo[client] = INVALID_ENT_REFERENCE;
	g_iPathTrack[client][0] = INVALID_ENT_REFERENCE;
	g_iPathTrack[client][1] = INVALID_ENT_REFERENCE;
}

stock void Annotate(int entity, int client, char[] strMsg)
{
	Event event = CreateEvent("show_annotation");
	if (event != INVALID_HANDLE)
	{
		event.SetInt("follow_entindex", entity);
		event.SetFloat("lifetime", 3.0);
		event.SetInt("id", entity + 8750);
		event.SetString("text", strMsg);
		event.SetString("play_sound", "vo/null.wav");
		event.SetString("show_effect", "0");
		event.SetString("show_distance", "1");
		event.SetInt("visibilityBitfield", 1 << client);
		event.Fire(false);
	}
}

stock void TelePortTracks(int client, float flPos[3])
{
	int path = EntRefToEntIndex(g_iPathTrack[client][0]);
	if (path != INVALID_ENT_REFERENCE)
	{
		TeleportEntity(path, flPos, NULL_VECTOR, NULL_VECTOR);
	}
	
	path = EntRefToEntIndex(g_iPathTrack[client][1]);
	if (path != INVALID_ENT_REFERENCE)
	{
		TeleportEntity(path, flPos, NULL_VECTOR, NULL_VECTOR);
	}
}

stock int AttachParticle(int iEntity, char[] strParticleEffect, char[] strAttachPoint = "", float flZOffset = 0.0, int iSelfDestruct)
{
	int iParticle = CreateEntityByName("info_particle_system");
	if (!IsValidEdict(iParticle))
		return 0;
	
	float flPos[3];
	GetEntPropVector(iEntity, Prop_Send, "m_vecOrigin", flPos);
	flPos[2] += flZOffset;
	
	DispatchKeyValueVector(iParticle, "origin", flPos);
	DispatchKeyValue(iParticle, "effect_name", strParticleEffect);
	DispatchSpawn(iParticle);
	
	SetVariantString("!activator");
	AcceptEntityInput(iParticle, "SetParent", iEntity);
	ActivateEntity(iParticle);
	
	if (strlen(strAttachPoint))
	{
		SetVariantString(strAttachPoint);
		AcceptEntityInput(iParticle, "SetParentAttachmentMaintainOffset");
	}
	
	AcceptEntityInput(iParticle, "start");
	
	char addoutput[64];
	Format(addoutput, sizeof(addoutput), "OnUser1 !self:kill::%i:1", iSelfDestruct);
	SetVariantString(addoutput);
	AcceptEntityInput(iParticle, "AddOutput");
	AcceptEntityInput(iParticle, "FireUser1");
	
	return iParticle;
}

stock bool IsValidBuilding(int iBuilding)
{
	if (IsValidEntity(iBuilding))
	{
		int iBuilder = GetEntPropEnt(iBuilding, Prop_Send, "m_hBuilder");
		if (iBuilder > 0 && iBuilder <= MaxClients && IsClientInGame(iBuilder))
		{
			if (GetEntProp(iBuilding, Prop_Send, "m_iTeamNum") == GetClientTeam(iBuilder)
			 && GetEntProp(iBuilding, Prop_Send, "m_bPlacing") == 0
			 && GetEntProp(iBuilding, Prop_Send, "m_bCarried") == 0
			 && GetEntProp(iBuilding, Prop_Send, "m_bCarryDeploy") == 0
			 && GetEntProp(iBuilding, Prop_Send, "m_bBuilding") == 0)
				return true;
		}
	}
	
	return false;
}

stock bool IsMiniBuilding(int iBuilding)
{
	if (GetEntProp(iBuilding, Prop_Send, "m_bMiniBuilding") == 1
	 || GetEntProp(iBuilding, Prop_Send, "m_bDisposableBuilding") == 1)
		return true;
	
	return false;
}

stock bool IsEntityOnSameTeam(int iEnt1, int iEnt2)
{
	return !!(GetEntProp(iEnt1, Prop_Send, "m_iTeamNum") == GetEntProp(iEnt2, Prop_Send, "m_iTeamNum"));
}

stock bool TF2_IsMvM()
{
	return view_as<bool>(GameRules_GetProp("m_bPlayingMannVsMachine"));
}

stock bool IsPointVisible(int iExclude, float flStart[3], float vecPoint[3])
{
	bool bSee = true;
	
	Handle hTrace = TR_TraceRayFilterEx(flStart, vecPoint, MASK_ALL, RayType_EndPoint, ExcludeFilter, iExclude);
	if(hTrace != INVALID_HANDLE)
	{
		if(TR_DidHit(hTrace))
			bSee = false;
			
		delete hTrace;
	}
	
	return bSee;
}

public bool ExcludeFilter(int entityhit, int mask, any entity)
{
	if (entityhit > MaxClients && entityhit != entity)
	{
		return true;
	}
	
	return false;
}