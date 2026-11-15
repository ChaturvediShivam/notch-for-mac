#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include "NotchMediaRemote.h"

// One JSON object per line on stdout whenever now-playing changes (and every 3 s as a safety net).
// Commands on stdin: "cmd <n>" (MRMediaRemoteSendCommand), "seek <seconds>".

typedef void (*GetInfoF)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPlayingF)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetPIDF)(dispatch_queue_t, void (^)(int));
typedef void (*RegisterF)(dispatch_queue_t);
typedef Boolean (*SendF)(int, NSDictionary *);
typedef void (*SeekF)(double);

static GetInfoF getInfo; static GetPlayingF getPlaying; static GetPIDF getPID;
static SendF sendCmd; static SeekF setElapsed;
static NSString *lastArtID;

static void emit(void) {
    dispatch_queue_t q = dispatch_get_main_queue();
    getInfo(q, ^(NSDictionary *info) {
        getPlaying(q, ^(Boolean playing) {
            getPID(q, ^(int pid) {
                NSMutableDictionary *o = [NSMutableDictionary dictionary];
                o[@"playing"] = @(playing);
                o[@"pid"] = @(pid);
                if (info) {
                    #define K(x) [@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:(x)]
                    for (NSString *k in @[@"Title", @"Artist", @"Album"]) {
                        id v = info[K(k)];
                        if ([v isKindOfClass:[NSString class]]) o[k.lowercaseString] = v;
                    }
                    for (NSString *k in @[@"Duration", @"ElapsedTime", @"PlaybackRate"]) {
                        id v = info[K(k)];
                        if ([v isKindOfClass:[NSNumber class]]) o[k.lowercaseString] = v;
                    }
                    NSDate *ts = info[K(@"Timestamp")];
                    if ([ts isKindOfClass:[NSDate class]]) o[@"timestamp"] = @([ts timeIntervalSince1970]);
                    NSData *art = info[K(@"ArtworkData")];
                    NSString *artID = [NSString stringWithFormat:@"%@|%@|%lu", o[@"title"], o[@"album"], (unsigned long)art.length];
                    if ([art isKindOfClass:[NSData class]] && art.length && ![artID isEqualToString:lastArtID]) {
                        o[@"artwork"] = [art base64EncodedStringWithOptions:0];
                        lastArtID = artID;
                    } else if (!art.length) {
                        lastArtID = nil;
                        o[@"noArtwork"] = @YES;
                    }
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
                if (json) { fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout); }
            });
        });
    });
}

void notch_mr_stream(void *perl, void *cv) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (GetInfoF)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = (GetPlayingF)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (GetPIDF)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCmd = (SendF)dlsym(h, "MRMediaRemoteSendCommand");
    setElapsed = (SeekF)dlsym(h, "MRMediaRemoteSetElapsedTime");
    RegisterF reg = (RegisterF)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getPlaying || !getPID || !reg) { printf("{\"error\":\"MediaRemote unavailable\"}\n"); fflush(stdout); exit(1); }

    reg(dispatch_get_main_queue());
    for (NSString *n in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                          @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) { emit(); }];
    }
    [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *t) { emit(); }];

    // stdin commands; EOF (app quit) ends the process.
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        char buf[256];
        ssize_t n = read(STDIN_FILENO, buf, sizeof(buf) - 1);
        if (n <= 0) exit(0);
        buf[n] = 0;
        for (char *line = strtok(buf, "\n"); line; line = strtok(NULL, "\n")) {
            int c; double s;
            if (sscanf(line, "cmd %d", &c) == 1 && sendCmd) sendCmd(c, nil);
            else if (sscanf(line, "seek %lf", &s) == 1 && setElapsed) setElapsed(s);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ emit(); });
    });
    dispatch_resume(src);
    emit();
    CFRunLoopRun();
}
