//
//  QuakeWrapper.c
//  WatchQuake Watch App
//
//  Created by ByteOverlord on 29.10.2022.
//

#include "QuakeWrapper.h"

#import <Foundation/Foundation.h>

#include "Common.h"
#import "WQSoundCallback.h"
#include "Threading.h"
#include "Threading.hpp"
#include "sys_watch.h"
#include "cd_watch.h"

#define INPUT_THREADSAFE

#ifdef INPUT_THREADSAFE
#include <pthread/pthread.h>
pthread_mutex_t input_lock;
#define INPUT_INIT pthread_mutex_init(&input_lock,NULL);
#define INPUT_LOCK pthread_mutex_lock(&input_lock);
#define INPUT_UNLOCK pthread_mutex_unlock(&input_lock);
#else
#define INPUT_INIT
#define INPUT_LOCK
#define INPUT_UNLOCK
#endif

// Quake keys
#define    KEY_TAB           9
#define    KEY_ENTER         13
#define    KEY_ESCAPE        27
#define    KEY_SPACE         32
#define    KEY_BACKSPACE     127
#define    KEY_UPARROW       128
#define    KEY_DOWNARROW     129
#define    KEY_LEFTARROW     130
#define    KEY_RIGHTARROW    131
#define    KEY_PGDN          149
//

#define WQ_INPUT_FIRE        (u16)(0x0001)
#define WQ_INPUT_PREVWEAPON  (u16)(0x0002)
#define WQ_INPUT_NEXTWEAPON  (u16)(0x0004)
#define WQ_INPUT_JUMP        (u16)(0x0008)
#define WQ_INPUT_MENU_ESCAPE (u16)(0x0010)
#define WQ_INPUT_MENU_ENTER  (u16)(0x0020)
#define WQ_INPUT_MENU_LEFT   (u16)(0x0040)
#define WQ_INPUT_MENU_UP     (u16)(0x0080)
#define WQ_INPUT_MENU_DOWN   (u16)(0x0100)
#define WQ_INPUT_SWIM_UP     (u16)(0x0200)
#define WQ_INPUT_SWIM_DOWN   (u16)(0x0400)

typedef struct
{
    i16 vel;
    u16 keys;
} WQInput_t;

void WQBlitFrameBuffer(unsigned char* dstRGBA, unsigned char* srcPaletteIndexed, unsigned int* palette);

void WQInitGameScreen(void);

void WQJumpCommand(int pressed);
void WQSwitchWeaponCommand(int next);
void WQShootCommand(int pressed);
void WQArrowCommand(int up);
void WQMenuToggle(void);
void WQConsoleToggle(void);
void WQRestart(void);
void WQChangeLevel(int e, int m, bool keepStats);
void WQKeyEvent(int key, int pressed);

void WQTick(void);
bool WQNeedsUpdate(void);
void WQUpdate(void);
void WQEndFrame(void);

extern unsigned char* g_DataImages[3];// palette indexed
unsigned char* g_DataRGBA = NULL;// converted final image
CGColorSpaceRef g_ColorSpaceRef;
CGContextRef g_Context;

int g_frameBufferWriteIndex = 0;
int g_frameBufferReadIndex = 0;

TimeStepAccumulator_t logicAcc;
u64 prevTime = 0;

int g_WQFrameCounter;
u64 g_WQFrametimeAggregate;
u64 g_WQLastMeasurementTimeStamp;

float g_WQForwardSpeed = 0;
float g_WQTurnX = 0;
float g_WQTurnY = 0;

CGPoint g_WQPrevPanPoint = {0,0};
CGPoint g_WQCurPanPoint = {0,0};
int g_WQPanState = 0;
int g_WQPrevPanState = 0;

float g_WQSwimTimer = 0;
float g_WQJumpTimer = 0;
float g_WQShootTimer = 0;
bool g_WQFullAuto = false;
float g_WQArrowTimer = 0;
int g_WQTicksSinceTap = 0;
uint g_WQFlags = 0;

WQGameStats_t g_GameStats;

u32 g_TImerFPS = 60;

#include "quakedef.h"

extern byte* vid_buffer;

extern uint g_WQVidScreenWidth;
extern uint g_WQVidScreenHeight;

WQInput_t g_WQPlayerInput;

// todo
//
// replace volatile ints with _Atomic ints?
//
//#include <stdatomic.h>
//_Atomic int g_WQState = 1;

int g_WQResTimer = 0;

#define WQ_RESOLUTION_UPDATE_DELAY 4
#define WQ_RESOLUTION_RESIZE_TICK 2

volatile int g_WQState = 1;

int WQRequestState(int state)
{
INPUT_LOCK

    if (g_WQState != state)
    {
        if (state == WQ_STATE_PAUSE)
        {
            printf("Game Paused\n");
            g_WQState = WQ_STATE_PAUSE;
            M_SaveSettings();
            SetGameLoopState(0);
        }
        else if (state == WQ_STATE_PLAY)
        {
            printf("Game Resumed\n");
            g_WQState = WQ_STATE_PLAY;
            SetGameLoopState(1);
        }
    }

INPUT_UNLOCK

    return 0;
}

void WQNotifyActive(int isActive)
{
INPUT_LOCK

   if (isActive)
   {
       //printf("Notify Active\n");

       // clear player input
       g_WQTurnX = 0;
       g_WQTurnY = 0;
       g_WQPlayerInput.keys = 0;
       g_WQPlayerInput.vel = 0;
       g_WQPanState = 0;
       g_WQPrevPanState = g_WQPanState;
       g_WQPrevPanPoint = g_WQCurPanPoint;
   }
   else
   {
       //printf("Notify Inactive\n");
   }

INPUT_UNLOCK
}

void WQInputInit(WQInput_t* input)
{
    input->vel = 0;
    input->keys = 0;
}

void WQInputClear(WQInput_t* input)
{
    input->vel = 0;
    input->keys = 0;
}

void WQBlitFrameBuffer(unsigned char* dstRGBA, unsigned char* srcPaletteIndexed, unsigned int* palette)
{
    u32 width = g_WQVidScreenWidth;
    u32 height = g_WQVidScreenHeight;
    u32 pixelCount = width * height;
#ifdef WQ_BLITTER_BLOCK64
    u32* fb = __builtin_assume_aligned((u32*)dstRGBA,8);
    u32 blocks8 = pixelCount / 8;
    u32 leftOver = pixelCount - (blocks8 * 8);
    u64* vPtr = __builtin_assume_aligned((u64*)srcPaletteIndexed,8);
    u32 p = blocks8;
    while (p--)
    {
        u64 block = *vPtr++;
        fb[0] = palette[(block >> 0) & 0xFF];
        fb[1] = palette[(block >> 8) & 0xFF];
        fb[2] = palette[(block >> 16) & 0xFF];
        fb[3] = palette[(block >> 24) & 0xFF];
        fb[4] = palette[(block >> 32) & 0xFF];
        fb[5] = palette[(block >> 40) & 0xFF];
        fb[6] = palette[(block >> 48) & 0xFF];
        fb[7] = palette[(block >> 56) & 0xFF];
        fb += 8;
    }
#else
    u32* fb = __builtin_assume_aligned((u32*)dstRGBA,4);
    u32 blocks4 = width / 4;
    u32 leftOver = pixelCount - (blocks4 * 4);
    u32* vPtr = __builtin_assume_aligned((u32*)srcPaletteIndexed,4);
    u32 p = blocks4;
    while (p--)
    {
        u32 block = *vPtr++;
        fb[0] = palette[(block >> 0) & 0xFF];
        fb[1] = palette[(block >> 8) & 0xFF];
        fb[2] = palette[(block >> 16) & 0xFF];
        fb[3] = palette[(block >> 24) & 0xFF];
        fb += 4;
    }
#endif
    u8* vbPtr = (u8*)vPtr;
    p = leftOver;
    while (p--)
    {
        *fb++ = palette[*vbPtr++];
    }
}

extern cvar_t vid_width;
extern cvar_t vid_height;

void WQSetScreenSize(int width, int height, float pixelsPerDot)
{
    g_GameStats.devWidth = width;
    g_GameStats.devHeight = height;
    g_GameStats.devPixelsPerDot = pixelsPerDot;
    g_WQVidScreenWidth = width * pixelsPerDot;
    g_WQVidScreenHeight = height * pixelsPerDot;
    while ((g_WQVidScreenWidth % 8) != 0)
    {
        g_WQVidScreenWidth++;
    }
}

void WQInitGameScreen(void)
{
    // allocate enough space for largest supported resolution
    uint maxImgSize = 1280*960;

    uint width = vid_width.value;
    uint height = vid_height.value;

    g_DataRGBA = AlignedMalloc(maxImgSize*4,16);
    memset(g_DataRGBA,0,maxImgSize*4);

    g_ColorSpaceRef = CGColorSpaceCreateDeviceRGB();
    g_Context = CGBitmapContextCreate(g_DataRGBA,width,height,8,width*4,g_ColorSpaceRef,kCGImageAlphaPremultipliedLast);
}

void WQResizeGameScreen(void)
{
    CGContextRelease(g_Context);
    uint width = g_WQVidScreenWidth;
    uint height = g_WQVidScreenHeight;
    g_Context = CGBitmapContextCreate(g_DataRGBA,width,height,8,width*4,g_ColorSpaceRef,kCGImageAlphaPremultipliedLast);
}

void VID_OnResize(cvar_t* var)
{
    if ((int)(vid_width.value) != g_WQVidScreenWidth || (int)(vid_height.value) != g_WQVidScreenHeight)
    {
        g_WQResTimer = WQ_RESOLUTION_UPDATE_DELAY;
        VID_SetSize((int)(vid_width.value),(int)(vid_height.value));
    }
}

void WQRemoveGameScreen(void)
{
    CGContextRelease(g_Context);
    AlignedFree(g_DataRGBA);
    g_DataRGBA = NULL;
}

CGImageRef WQCreateGameImage(void)
{
    // triple buffering
    int idx = g_frameBufferReadIndex;
    WQBlitFrameBuffer(g_DataRGBA,g_DataImages[idx],d_8to24tables[idx]);
    ++g_frameBufferReadIndex;
    g_frameBufferReadIndex %= 3;
    return CGBitmapContextCreateImage(g_Context);
}

volatile int frames = 0;

void refresh_screen(void*);

void WQUpdateStats(void)
{
    double meanframeRate = 60;
    u64 now = GetTimeNanoSeconds();
    if (g_WQLastMeasurementTimeStamp != 0)
    {
        meanframeRate = GetDeltaTime(now - g_WQLastMeasurementTimeStamp) * g_WQFrameCounter;
    }
    double meanFrametime = (g_WQFrametimeAggregate / g_WQFrameCounter) / 1000000.0;
    g_GameStats.frameCounter = meanframeRate;
    g_GameStats.meanFrameTime = meanFrametime;
    g_WQFrameCounter = 0;
    g_WQFrametimeAggregate = 0;
    g_WQLastMeasurementTimeStamp = now;
}

WQGameStats_t WQGetStats(void)
{
    return g_GameStats;
}

#include <string.h>

char statsBuffer[256];
const char* WQGetStatsString(void)
{
    snprintf(statsBuffer,256,"FPS: %d, CPU: %.2fms, %dx%d", g_GameStats.frameCounter, g_GameStats.meanFrameTime, g_WQVidScreenWidth, g_WQVidScreenHeight);
    return statsBuffer;
}

int statsHidden = 0;
extern cvar_t scr_showfps;

void* GameLoop(void* p)
{

INPUT_LOCK
    if (g_WQState == WQ_STATE_PAUSE)
    {
        INPUT_UNLOCK
        return NULL;
    }
INPUT_UNLOCK

    ++frames;
    if (statsHidden == 0 && frames == 60)
    {
        // hack!
        // fixes stuttering audio when ImageOverlay.Text displays first time
        scr_showfps.value = 0;
        statsHidden = 1;
    }
    WQTick();
    bool updated = false;
    while (WQNeedsUpdate())
    {
        WQUpdate();
        WQEndFrame();
        g_WQFrameCounter++;
        if (g_TImerFPS)
        {
            --g_TImerFPS;
        }
        updated = true;
    }
    if (updated)
    {
        if (!g_TImerFPS)
        {
            WQUpdateStats();
            g_TImerFPS = 60;
        }
    }
    return NULL;
}

int WQGetFrame(void)
{
    return frames;
}

#include <sys/stat.h>

int do_mkdir(const char* path, mode_t mode)
{
    struct stat st;
    int status = 0;

    if (stat(path,&st) != 0)
    {
        if (mkdir(path,mode) != 0 && errno != EEXIST)
        {
            return -1;
        }
    }
    else if (!S_ISDIR(st.st_mode))
    {
        errno = ENOTDIR;
        status = -1;
    }
    return status;
}

int CreateFolder(const char* path)
{
    mode_t mode = S_IRWXU;
    char* copypath = strdup(path);
    char* pp = copypath;
    char* sp;
    int status = 0;

    while (status == 0 && (sp = strchr(pp,'/')) != 0)
    {
        if (sp != pp)
        {
            *sp = '\0';
            status = do_mkdir(copypath,mode);
            *sp = '/';
        }
        pp = sp + 1;
    }
    if (status == 0)
    {
        status = do_mkdir(path,mode);
    }
    free(copypath);
    return status;
}

void refresh_mapselect(void*);

void WQOnMapsNavigate(void)
{
    dispatch_async_f(dispatch_get_main_queue(),NULL,refresh_mapselect);
}

void WQInit(void)
{
    INPUT_INIT
    INPUT_LOCK

    M_EnterMapsFunc = &WQOnMapsNavigate;
    M_ExitMapsFunc = &WQOnMapsNavigate;
    M_SelectMapsFunc = &WQOnMapsNavigate;
    
    g_WQFrameCounter = 0;
    g_WQFrametimeAggregate = 0;
    g_WQLastMeasurementTimeStamp = 0;

    NSBundle* bundle = [NSBundle mainBundle];
    NSString* resourceDir = bundle.resourcePath;
    NSString* commandLine = [[NSUserDefaults standardUserDefaults] stringForKey:@"sys_commandline0"];
    
    if (commandLine == nil)
    {
        commandLine = @"";
    }
    resourceDir = [resourceDir stringByAppendingString:@"/id1"];
    NSString* musicDir = [resourceDir stringByAppendingString:@"/music"];
    NSString* saveDir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES) objectAtIndex:0];
    //NSString* saveDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) objectAtIndex:0];
    saveDir = [saveDir stringByAppendingString:@"/watchquake"];
    CreateFolder([saveDir UTF8String]);
    
    CDAudio_SetPath([musicDir UTF8String]);
    Sys_Init([resourceDir UTF8String] , [resourceDir UTF8String], [saveDir UTF8String], [commandLine UTF8String]);
    Cvar_SetCallback(&vid_width,&VID_OnResize);
    Cvar_SetCallback(&vid_height,&VID_OnResize);

    WQInitGameScreen();

    prevTime = GetTimeNanoSeconds();
    TimeStepAccumulator_Set(&logicAcc,60,2);

    g_GameStats.frameCounter = 0;
    g_GameStats.meanFrameTime = 0.0f;
    g_GameStats.width = g_WQVidScreenWidth;
    g_GameStats.height = g_WQVidScreenHeight;

    WQInputInit(&g_WQPlayerInput);

    INPUT_UNLOCK
}

void WQSetLoop(void)
{
    int threads = GetHardwareConcurrency();
    printf("hardware concurrency %i\n",threads);
    SetConcurrency(2);
    SetAudioMixerLoop(&WQAudioMixerLoop,NULL);
    SetGameUpdateTask(&GameLoop,"ge.WatchQuake.queue");
    SetGameLoopState(1);
}

void WQFree(void)
{
    WQRemoveGameScreen();
}

#include "cmd.h"
#include "keys.h"

void WQConsoleToggle(void)
{
    Cmd_ExecuteString("toggleconsole",src_command);
}

void WQMenuToggle(void)
{
    Cmd_ExecuteString("togglemenu",src_command);
}

void WQRestart(void)
{
    Cmd_ExecuteString("restart",src_command);
}

void WQChangeLevel(int e, int m, bool keepStats)
{
    char buffer[1024];
    if (keepStats)
    {
        snprintf(buffer,1024,"changelevel \"e%im%i\"",e,m);
    }
    else
    {
        snprintf(buffer,1024,"map \"e%im%i\"",e,m);
    }
    Cmd_ExecuteString(buffer,src_command);
}

void WQKeyEvent(int key, int pressed)
{
    Key_Event(key,pressed);
}

void WQJumpCommand(int pressed)
{
    if (pressed)
    {
        Cmd_ExecuteString("+jump",src_command);
        g_WQJumpTimer = 0.5f;
    }
    else
    {
        Cmd_ExecuteString("-jump",src_command);
    }
}

void WQSwimUpCommand(int pressed)
{
    if (pressed)
    {
        Cmd_ExecuteString("+moveup",src_command);
        g_WQSwimTimer = 0.5f;
    }
    else
    {
        Cmd_ExecuteString("-moveup",src_command);
    }
}

void WQSwimStopCommand(void)
{
    Cmd_ExecuteString("-moveup",src_command);
    Cmd_ExecuteString("-movedown",src_command);
}

void WQSwimDownCommand(int pressed)
{
    if (pressed)
    {
        Cmd_ExecuteString("+movedown",src_command);
        g_WQSwimTimer = 0.5f;
    }
    else
    {
        Cmd_ExecuteString("-movedown",src_command);
    }
}

void WQSwitchWeaponCommand(int next)
{
    if (next)
    {
        // weapons.qc impulse 10 CycleWeaponCommand()
        Cmd_ExecuteString("impulse 10",src_command);
    }
    else
    {
        // needs newer Quake version 1.06 to work (progs.dat QuakeC)
        // weapons.qc impulse 12 CycleWeaponReverseCommand()
        Cmd_ExecuteString("impulse 12",src_command);
    }
}

void WQShootCommand(int pressed)
{
    if (pressed)
    {
        if (g_WQShootTimer <= 0.0f)
        {
            Cmd_ExecuteString ("+attack 133", src_command);
            g_WQShootTimer = 0.5f;
        }
    }
    else
    {
        Cmd_ExecuteString ("-attack 133", src_command);
    }
}

void WQArrowCommand(int up)
{
    if (up)
    {
        if (g_WQArrowTimer <= 0.0)
        {
            WQKeyEvent(KEY_UPARROW,true);
            g_WQArrowTimer = 0.2;
        }
        WQKeyEvent(KEY_DOWNARROW,false);
    }
    else
    {
        if (g_WQArrowTimer <= 0.0)
        {
            WQKeyEvent(KEY_DOWNARROW,true);
            g_WQArrowTimer = 0.2;
        }
        WQKeyEvent(KEY_UPARROW,false);
    }
}

keydest_t prev_key_dest = key_menu;// key_game, key_console, key_message, key_menu

int WQShowFPS()
{
    return Sys_ShowFPS();
}

u64 frametimeStart;

void WQTick()
{
    frametimeStart = GetTimeNanoSeconds();
    u64 dt = frametimeStart - prevTime;
    prevTime = frametimeStart;
    TimeStepAccumulator_Update(&logicAcc,dt);
}

bool WQNeedsUpdate(void)
{
    return TimeStepAccumulator_Tick(&logicAcc);
}

extern cvar_t sensitivity;
extern int g_QWPaletteCopied;

void WQUpdate(void)
{
    // Input handling
    // lock needed, swiftui should be running in another thread
    INPUT_LOCK

    const float logicDT = 1.0f / 60.0f;

    if (key_dest != prev_key_dest)// switched input destination (game, menu, etc.)
    {
        // cancel shoot command
        g_WQFullAuto = qFalse;
        g_WQShootTimer = 1.0f;
        WQShootCommand(qFalse);
    }
    if (key_dest == key_game)
    {
        if (g_WQPlayerInput.keys & WQ_INPUT_FIRE)
        {
            if (g_WQTicksSinceTap < 20)// double tap
            {
                if (g_WQFullAuto)
                {
                    g_WQFullAuto = qFalse;
                    WQShootCommand(qFalse);
                    g_WQShootTimer = 0.0f;
                }
                else
                {
                    g_WQFullAuto = qTrue;
                    WQShootCommand(qTrue);
                }
                // don't reset g_QWTicksSinceTap here, otherwise triple tap counts as double tap twise in row!
            }
            else // single tap
            {
                if (g_WQFullAuto)
                {
                    g_WQFullAuto = qFalse;
                    WQShootCommand(qFalse);
                    g_WQShootTimer = 0.0;
                }
                else
                {
                    WQShootCommand(qTrue);
                }
                g_WQTicksSinceTap = 0;
            }
            if (cl.intermission || cls.demoplayback)
            {
                // advance to next map during intermission
                //
                // cancel shoot command
                g_WQFullAuto = qFalse;
                WQShootCommand(qFalse);
                g_WQShootTimer = 1.0f;
            }
        }
        if (g_WQPlayerInput.keys & (WQ_INPUT_NEXTWEAPON | WQ_INPUT_PREVWEAPON))
        {
            if (g_WQPlayerInput.keys & WQ_INPUT_NEXTWEAPON)
            {
                WQSwitchWeaponCommand(g_WQPlayerInput.keys & WQ_INPUT_NEXTWEAPON);
            }
            else
            {
                g_WQFlags ^= 0x01;// toggle between strafe and forward movement.
            }
        }
        if (g_WQPlayerInput.keys & WQ_INPUT_JUMP)
        {
            WQJumpCommand(qTrue);
        }
        if (g_WQPlayerInput.keys & WQ_INPUT_SWIM_UP)
        {
            WQSwimUpCommand(qTrue);
        }
        if (g_WQPlayerInput.keys & WQ_INPUT_SWIM_DOWN)
        {
            WQSwimDownCommand(qTrue);
        }
        g_WQForwardSpeed += g_WQPlayerInput.vel * (4.0f / 32767.0f);
        g_WQForwardSpeed = g_WQForwardSpeed > 1.0f ? 1.0f : g_WQForwardSpeed;
        g_WQForwardSpeed = g_WQForwardSpeed < -1.0f ? -1.0f : g_WQForwardSpeed;
        if (g_WQSwimTimer > 0.0f)
        {
            g_WQSwimTimer -= logicDT;
            if (g_WQSwimTimer <= 0.0f)
            {
                WQSwimStopCommand();
            }
        }
        if (g_WQJumpTimer > 0.0f)
        {
            g_WQJumpTimer -= logicDT;
            if (g_WQJumpTimer <= 0.0f)
            {
                WQJumpCommand(qFalse);
            }
        }
        if (!g_WQFullAuto && g_WQShootTimer > 0.0f)
        {
            g_WQShootTimer -= logicDT;
            if (g_WQShootTimer <= 0.0f)
            {
                WQShootCommand(qFalse);
            }
        }
        if (g_WQPanState)
        {
            if (!g_WQPrevPanState)// touch started
            {
                g_WQPrevPanPoint = g_WQCurPanPoint;
            }
        }
        else // touch ended
        {
            g_WQPrevPanPoint = g_WQCurPanPoint;
        }
        g_WQPrevPanState = g_WQPanState;

        if (g_WQPanState)
        {
            CGPoint vel;
            vel.x =  g_WQCurPanPoint.x - g_WQPrevPanPoint.x;
            vel.y =  g_WQCurPanPoint.y - g_WQPrevPanPoint.y;
            g_WQPrevPanPoint = g_WQCurPanPoint;
            g_WQTurnX = vel.x;
            g_WQTurnY = vel.y;
        }
        else
        {
            g_WQTurnX = 0.0f;
            g_WQTurnY = 0.0f;
        }
    }
    else
    {
        g_WQPrevPanPoint = g_WQCurPanPoint;
        g_WQTurnX = 0.0f;
        g_WQTurnY = 0.0f;
    }

    if (g_WQPlayerInput.keys & WQ_INPUT_MENU_ENTER)
    {
        WQKeyEvent(KEY_ENTER,qTrue);
        WQKeyEvent(KEY_ENTER,qFalse);
    }
    if (g_WQPlayerInput.keys & WQ_INPUT_MENU_ESCAPE)
    {
        WQKeyEvent(KEY_ESCAPE,qTrue);
        WQKeyEvent(KEY_ESCAPE,qFalse);
    }
    if (g_WQPlayerInput.keys & WQ_INPUT_MENU_LEFT)
    {
        WQKeyEvent(KEY_LEFTARROW,qTrue);
        WQKeyEvent(KEY_LEFTARROW,qFalse);
    }
    if (g_WQPlayerInput.keys & (WQ_INPUT_MENU_UP | WQ_INPUT_MENU_DOWN))
    {
        WQArrowCommand(g_WQPlayerInput.keys & WQ_INPUT_MENU_UP);
    }
    if (g_WQArrowTimer > 0.0f)
    {
        g_WQArrowTimer -= logicDT;
        if (g_WQArrowTimer <= 0.0f)
        {
            WQKeyEvent(KEY_UPARROW,qFalse);
            WQKeyEvent(KEY_DOWNARROW,qFalse);
        }
    }

    g_WQTicksSinceTap++;

    prev_key_dest = key_dest;// remember where input was directed last frame

    WQInputClear(&g_WQPlayerInput);
    
    INPUT_UNLOCK

    g_QWPaletteCopied = 0;
    Sys_FrameBeforeRender();
    Sys_FrameRender();
    Sys_FrameAfterRender();
}

void WQEndFrame(void)
{
    int prevIndex = g_frameBufferWriteIndex;
    ++g_frameBufferWriteIndex;
    g_frameBufferWriteIndex %= 3;
    VID_SwapBuffer(g_frameBufferWriteIndex);
    if (g_QWPaletteCopied == 0)
    {
        int prevPrevIndex = prevIndex - 1;
        if (prevPrevIndex < 0)
        {
            prevPrevIndex = 2;
        }
        memcpy(__builtin_assume_aligned(d_8to24tables[prevIndex],16),__builtin_assume_aligned(d_8to24tables[prevPrevIndex],16),256*sizeof(u32));
    }
    int copyScreen = 1;
    if (g_WQResTimer != 0)
    {
        g_WQResTimer--;
        if (g_WQResTimer == WQ_RESOLUTION_RESIZE_TICK)
        {
            WQResizeGameScreen();
        }
        if (g_WQResTimer == 0)
        {
            g_GameStats.width = g_WQVidScreenWidth;
            g_GameStats.height = g_WQVidScreenHeight;
            g_frameBufferReadIndex = prevIndex;
        }
        else
        {
            copyScreen = 0;
        }
    }
    if (copyScreen)
    {
        dispatch_async_f(dispatch_get_main_queue(),NULL,refresh_screen);
    }
    u64 frametimeU64 = GetTimeNanoSeconds() - frametimeStart;
    g_WQFrametimeAggregate += frametimeU64;
}

void WQInputTapAndPan(CGPoint location, int type)
{
    INPUT_LOCK

    if (type == 2)// tapping
    {
        CGFloat x = g_GameStats.devWidth / 2.0f;
        CGFloat x2 = x / 2.0f;
        x += x2;
        CGFloat y = g_GameStats.devHeight - g_GameStats.devHeight / 10.0;
        if (location.y < g_GameStats.devHeight / 10.0)// upper part of the screen
        {
            g_WQPlayerInput.keys |= location.x > x2 ? WQ_INPUT_SWIM_UP : WQ_INPUT_SWIM_DOWN;
        }
        else if (location.y > y)// lower part of the screen, inventory
        {
            if (location.x > x || location.x < x2)// left or right side
            {
                g_WQPlayerInput.keys |= location.x > x ? WQ_INPUT_NEXTWEAPON : WQ_INPUT_PREVWEAPON;
                g_WQPlayerInput.keys |= location.x > x ? WQ_INPUT_MENU_ENTER : WQ_INPUT_MENU_LEFT;
            }
            else // middle
            {
                g_WQPlayerInput.keys |= WQ_INPUT_JUMP;
            }
        }
        else
        {
            g_WQPlayerInput.keys |= WQ_INPUT_MENU_ENTER;
            g_WQPlayerInput.keys |= WQ_INPUT_FIRE;
        }
    }

    // if tapping, type == 0
    // else type 0-1
    g_WQPanState = type & 0x01;
    g_WQCurPanPoint = location;

    INPUT_UNLOCK
}

void WQInputLongPress(void)
{
    INPUT_LOCK

    g_WQPlayerInput.keys |= WQ_INPUT_MENU_ESCAPE;
    
    INPUT_UNLOCK
}

void WQInputCrownRotate(float f, float delta)
{
    INPUT_LOCK

    int vel = (delta * 0.025f) * 32767;
    vel = vel < -32767 ? -32767 : vel;
    vel = vel > 32767 ? 32767 : vel;
    g_WQPlayerInput.vel = vel;// 16bits should be enough for everyone...
    
    if (delta < 0)
    {
        g_WQPlayerInput.keys |= WQ_INPUT_MENU_DOWN;
    }
    else if (delta > 0)
    {
        g_WQPlayerInput.keys |= WQ_INPUT_MENU_UP;
    }

    INPUT_UNLOCK
}

extern int sndDesiredSamples;
int WQGetFrameBufferLength(void)
{
    return sndDesiredSamples;
}

extern int g_WQAudio_freq;
extern int g_WQAudio_bits;
extern int g_WQAudio_channels;
extern int g_WQAudio_interleaved;
extern int g_WQAudio_type;

void WQSetAudioFormat(int Hz, uint bits, int channels, int interleaved, int type)
{
    g_WQAudio_freq = Hz;
    g_WQAudio_bits = bits;
    g_WQAudio_channels = channels;
    g_WQAudio_interleaved = interleaved;
    g_WQAudio_type = type;

    CDAudio_SetMixerSamplerate(Hz);
}

const char* WQGetSelectedMapName(void)
{
    if (M_IsInMapSelect())
    {
        return M_GetSelectedMapName();
    }
    return 0;
}
