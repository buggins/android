/*
 * Copyright (C) 2010 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */

import android_native_app_glue;

import core.sys.posix.sys.time, core.sys.posix.time : clock_gettime, CLOCK_MONOTONIC;
import android.log : __android_log_print, android_LogPriority;
import android.native_window;
import android.input, android.looper : ALooper_pollAll;

import core.stdc.stdint, core.stdc.math: sin;
import core.stdc.stdarg : va_list, va_start;

enum LOG_TAG = "libplasma";
int LOGI(const(char)* fmt, ...) { 
    va_list arg_list;
    va_start(arg_list, fmt);
    return __android_log_print(android_LogPriority.ANDROID_LOG_INFO, LOG_TAG, arg_list);
}
int LOGW(const(char)* warning) { return  __android_log_print(android_LogPriority.ANDROID_LOG_WARN, LOG_TAG, warning); }

/* Set to 1 to enable debug log traces. */
enum DEBUG = 0;

/* Set to 1 to optimize memory stores when generating plasma. */
enum OPTIMIZE_WRITES = 1;

/* Return current time in milliseconds */
double now_ms()
{
    timeval tv;
    gettimeofday(&tv, null);
    return tv.tv_sec*1000. + tv.tv_usec/1000.;
}

/* We're going to perform computations for every pixel of the target
 * bitmap. floating-point operations are very slow on ARMv5, and not
 * too bad on ARMv7 with the exception of trigonometric functions.
 *
 * For better performance on all platforms, we're going to use fixed-point
 * arithmetic and all kinds of tricks
 */

alias Fixed = int32_t;

enum FIXED_BITS = 16;
enum FIXED_ONE  = 1 << FIXED_BITS;

Fixed FIXED_FROM_FLOAT(float x) { return cast(Fixed)(x*FIXED_ONE); }
Fixed FIXED_FRAC(Fixed x) { return x & ((1 << FIXED_BITS)-1); }

alias Angle = int32_t;

enum ANGLE_BITS = 9;

static assert(ANGLE_BITS >= 8, "ANGLE_BITS must be at least 8");

enum ANGLE_2PI = 1 << ANGLE_BITS;
enum ANGLE_PI  = 1 << (ANGLE_BITS-1);
enum ANGLE_PI2 = 1 << (ANGLE_BITS-2);

Angle ANGLE_FROM_FIXED(Fixed x)
{
    static if(ANGLE_BITS <= FIXED_BITS)
        return cast(Angle)(x >> (FIXED_BITS - ANGLE_BITS));
    else
        return cast(Angle)(x << (ANGLE_BITS - FIXED_BITS));
}

Fixed[ANGLE_2PI+1] angle_sin_tab;

void init_angles()
{
    int  nn;
    enum M_PI = 3.1415926;
    for (nn = 0; nn < ANGLE_2PI+1; nn++) {
        double  radians = nn*M_PI/ANGLE_PI;
        angle_sin_tab[nn] = FIXED_FROM_FLOAT(sin(radians));
    }
}

Fixed angle_sin( Angle  a )
{
    return angle_sin_tab[cast(uint32_t)a & (ANGLE_2PI-1)];
}

Fixed angle_cos( Angle  a )
{
    return angle_sin(a + ANGLE_PI2);
}

Fixed fixed_sin( Fixed  f )
{
    return angle_sin(ANGLE_FROM_FIXED(f));
}

Fixed  fixed_cos( Fixed  f )
{
    return angle_cos(ANGLE_FROM_FIXED(f));
}

/* Color palette used for rendering the plasma */
enum PALETTE_BITS = 8;
enum PALETTE_SIZE = 1 << PALETTE_BITS;

static assert(PALETTE_BITS <= FIXED_BITS, "PALETTE_BITS must be smaller than FIXED_BITS"); 

uint16_t[PALETTE_SIZE] palette;

uint16_t  make565(int red, int green, int blue)
{
    return cast(uint16_t)( ((red   << 8) & 0xf800) |
                       ((green << 2) & 0x03e0) |
                       ((blue  >> 3) & 0x001f) );
}

void init_palette()
{
    int  nn, mm = 0;
    /* fun with colors */
    for (nn = 0; nn < PALETTE_SIZE/4; nn++) {
        int  jj = (nn-mm)*4*255/PALETTE_SIZE;
        palette[nn] = make565(255, jj, 255-jj);
    }

    for ( mm = nn; nn < PALETTE_SIZE/2; nn++ ) {
        int  jj = (nn-mm)*4*255/PALETTE_SIZE;
        palette[nn] = make565(255-jj, 255, jj);
    }

    for ( mm = nn; nn < PALETTE_SIZE*3/4; nn++ ) {
        int  jj = (nn-mm)*4*255/PALETTE_SIZE;
        palette[nn] = make565(0, 255-jj, 255);
    }

    for ( mm = nn; nn < PALETTE_SIZE; nn++ ) {
        int  jj = (nn-mm)*4*255/PALETTE_SIZE;
        palette[nn] = make565(jj, 0, 255);
    }
}

uint16_t  palette_from_fixed( Fixed  x )
{
    if (x < 0) x = -x;
    if (x >= FIXED_ONE) x = FIXED_ONE-1;
    int  idx = FIXED_FRAC(x) >> (FIXED_BITS - PALETTE_BITS);
    return palette[idx & (PALETTE_SIZE-1)];
}

/* Angles expressed as fixed point radians */

void init_tables()
{
    init_palette();
    init_angles();
}

void fill_plasma(ANativeWindow_Buffer* buffer, double  t)
{
    Fixed yt1 = FIXED_FROM_FLOAT(t/1230.);
    Fixed yt2 = yt1;
    Fixed xt10 = FIXED_FROM_FLOAT(t/3000.);
    Fixed xt20 = xt10;

    enum YT1_INCR = FIXED_FROM_FLOAT(1/100.);
    enum YT2_INCR = FIXED_FROM_FLOAT(1/163.);

    void* pixels = buffer.bits;
    //LOGI("width=%d height=%d stride=%d format=%d", buffer->width, buffer->height,
    //        buffer->stride, buffer->format);

    int  yy;
    for (yy = 0; yy < buffer.height; yy++) {
        uint16_t*  line = cast(uint16_t*)pixels;
        Fixed      base = fixed_sin(yt1) + fixed_sin(yt2);
        Fixed      xt1 = xt10;
        Fixed      xt2 = xt20;

        yt1 += YT1_INCR;
        yt2 += YT2_INCR;

        enum XT1_INCR = FIXED_FROM_FLOAT(1/173.);
        enum XT2_INCR = FIXED_FROM_FLOAT(1/242.);

        static if(OPTIMIZE_WRITES) {
        /* optimize memory writes by generating one aligned 32-bit store
         * for every pair of pixels.
         */
        uint16_t*  line_end = line + buffer.width;

        if (line < line_end) {
            if ((cast(uint32_t)line & 3) != 0) {
                Fixed ii = base + fixed_sin(xt1) + fixed_sin(xt2);

                xt1 += XT1_INCR;
                xt2 += XT2_INCR;

                line[0] = palette_from_fixed(ii >> 2);
                line++;
            }

            while (line + 2 <= line_end) {
                Fixed i1 = base + fixed_sin(xt1) + fixed_sin(xt2);
                xt1 += XT1_INCR;
                xt2 += XT2_INCR;

                Fixed i2 = base + fixed_sin(xt1) + fixed_sin(xt2);
                xt1 += XT1_INCR;
                xt2 += XT2_INCR;

                uint32_t  pixel = (cast(uint32_t)palette_from_fixed(i1 >> 2) << 16) |
                                   cast(uint32_t)palette_from_fixed(i2 >> 2);

                (cast(uint32_t*)line)[0] = pixel;
                line += 2;
            }

            if (line < line_end) {
                Fixed ii = base + fixed_sin(xt1) + fixed_sin(xt2);
                line[0] = palette_from_fixed(ii >> 2);
                line++;
            }
        }
        } else {/* !OPTIMIZE_WRITES */
        int xx;
        for (xx = 0; xx < buffer.width; xx++) {

            Fixed ii = base + fixed_sin(xt1) + fixed_sin(xt2);

            xt1 += XT1_INCR;
            xt2 += XT2_INCR;

            line[xx] = palette_from_fixed(ii / 4);
        }
        }/* !OPTIMIZE_WRITES */

        // go to next line
        pixels = cast(uint16_t*)pixels + buffer.stride;
    }
}

/* simple stats management */
struct FrameStats {
    double  renderTime;
    double  frameTime;
}

enum MAX_FRAME_STATS = 200;
enum MAX_PERIOD_MS   = 1500;

struct Stats {
    double  firstTime;
    double  lastTime;
    double  frameTime;

    int         firstFrame;
    int         numFrames;
    FrameStats[MAX_FRAME_STATS] frames;
}

void
stats_init( Stats*  s )
{
    s.lastTime = now_ms();
    s.firstTime = 0.;
    s.firstFrame = 0;
    s.numFrames  = 0;
}

void
stats_startFrame( Stats*  s )
{
    s.frameTime = now_ms();
}

void
stats_endFrame( Stats*  s )
{
    double now = now_ms();
    double renderTime = now - s.frameTime;
    double frameTime  = now - s.lastTime;
    int nn;

    if (now - s.firstTime >= MAX_PERIOD_MS) {
        if (s.numFrames > 0) {
            double minRender, maxRender, avgRender;
            double minFrame, maxFrame, avgFrame;
            int count;

            nn = s.firstFrame;
            minRender = maxRender = avgRender = s.frames[nn].renderTime;
            minFrame  = maxFrame  = avgFrame  = s.frames[nn].frameTime;
            for (count = s.numFrames; count > 0; count-- ) {
                nn += 1;
                if (nn >= MAX_FRAME_STATS)
                    nn -= MAX_FRAME_STATS;
                double render = s.frames[nn].renderTime;
                if (render < minRender) minRender = render;
                if (render > maxRender) maxRender = render;
                double frame = s.frames[nn].frameTime;
                if (frame < minFrame) minFrame = frame;
                if (frame > maxFrame) maxFrame = frame;
                avgRender += render;
                avgFrame  += frame;
            }
            avgRender /= s.numFrames;
            avgFrame  /= s.numFrames;

            LOGI("frame/s (avg,min,max) = (%.1f,%.1f,%.1f) "
                 "render time ms (avg,min,max) = (%.1f,%.1f,%.1f)\n",
                 1000./avgFrame, 1000./maxFrame, 1000./minFrame,
                 avgRender, minRender, maxRender);
        }
        s.numFrames  = 0;
        s.firstFrame = 0;
        s.firstTime  = now;
    }

    nn = s.firstFrame + s.numFrames;
    if (nn >= MAX_FRAME_STATS)
        nn -= MAX_FRAME_STATS;

    s.frames[nn].renderTime = renderTime;
    s.frames[nn].frameTime  = frameTime;

    if (s.numFrames < MAX_FRAME_STATS) {
        s.numFrames += 1;
    } else {
        s.firstFrame += 1;
        if (s.firstFrame >= MAX_FRAME_STATS)
            s.firstFrame -= MAX_FRAME_STATS;
    }

    s.lastTime = now;
}

// ----------------------------------------------------------------------

struct engine {
    android_app* app;

    Stats stats;

    int animating;
}

void engine_draw_frame(engine* engine) {
    if (engine.app.window == null) {
        // No window.
        return;
    }

    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(engine.app.window, &buffer, null) < 0) {
        LOGW("Unable to lock window buffer");
        return;
    }

    stats_startFrame(&engine.stats);

    timespec t;
    t.tv_sec = t.tv_nsec = 0;
    clock_gettime(CLOCK_MONOTONIC, &t);
    int64_t time_ms = ((cast(int64_t)t.tv_sec)*1_000_000_000L + t.tv_nsec)/1_000_000;

    /* Now fill the values with a nice little plasma */
    fill_plasma(&buffer, time_ms);

    ANativeWindow_unlockAndPost(engine.app.window);

    stats_endFrame(&engine.stats);
}

void engine_term_display(engine* engine) {
    engine.animating = 0;
}

extern(C) int32_t engine_handle_input(android_app* app, AInputEvent* event) {
    engine* engine = cast(engine*)app.userData;
    if (AInputEvent_getType(event) == AINPUT_EVENT_TYPE_MOTION) {
        engine.animating = 1;
        return 1;
    } else if (AInputEvent_getType(event) == AINPUT_EVENT_TYPE_KEY) {
        LOGI("Key event: action=%d keyCode=%d metaState=0x%x",
                AKeyEvent_getAction(event),
                AKeyEvent_getKeyCode(event),
                AKeyEvent_getMetaState(event));
    }

    return 0;
}

extern(C) void engine_handle_cmd(android_app* app, int32_t cmd) {
    engine* engine = cast(engine*)app.userData;
    switch (cmd) {
        case APP_CMD_INIT_WINDOW:
            if (engine.app.window != null) {
                engine_draw_frame(engine);
            }
            break;
        case APP_CMD_TERM_WINDOW:
            engine_term_display(engine);
            break;
        case APP_CMD_LOST_FOCUS:
            engine.animating = 0;
            engine_draw_frame(engine);
            break;
        default:
            break;
    }
}

void main(){}
extern(C) void android_main(android_app* state) {
    static int init;

    engine engine;

    // Make sure glue isn't stripped.
    app_dummy();

    memset(&engine, 0, engine.sizeof);
    state.userData = &engine;
    state.onAppCmd = &engine_handle_cmd;
    state.onInputEvent = &engine_handle_input;
    engine.app = state;

    if (!init) {
        init_tables();
        init = 1;
    }

    stats_init(&engine.stats);

    // loop waiting for stuff to do.

    while (1) {
        // Read all pending events.
        int ident;
        int events;
        android_poll_source* source;

        // If not animating, we will block forever waiting for events.
        // If animating, we loop until all events are read, then continue
        // to draw the next frame of animation.
        while ((ident=ALooper_pollAll(engine.animating ? 0 : -1, null, &events,
                cast(void**)&source)) >= 0) {

            // Process this event.
            if (source != null) {
                source.process(state, source);
            }

            // Check if we are exiting.
            if (state.destroyRequested != 0) {
                LOGI("Engine thread destroy requested!");
                engine_term_display(&engine);
                return;
            }
        }

        if (engine.animating) {
            engine_draw_frame(&engine);
        }
    }
}
