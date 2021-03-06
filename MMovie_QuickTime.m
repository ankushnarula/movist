//
//  Movist
//
//  Copyright 2006 ~ 2008 Yong-Hoe Kim. All rights reserved.
//      Yong-Hoe Kim  <cocoable@gmail.com>
//
//  This file is part of Movist.
//
//  Movist is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 3 of the License, or
//  (at your option) any later version.
//
//  Movist is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "MMovie_QuickTime.h"
#import "UserDefaults.h"

@interface QTTrack (Movist)

- (NSString*)summary;

@end

@implementation QTTrack (Movist)

- (NSString*)summary
{
    NSString* result = @"";

    ImageDescriptionHandle idh;
    idh = (ImageDescriptionHandle)NewHandleClear(sizeof(ImageDescription));
    GetMediaSampleDescription([[self media] quickTimeMedia], 1,
                              (SampleDescriptionHandle)idh);

    NSString* mediaType = [self attributeForKey:QTTrackMediaTypeAttribute];
    if ([mediaType isEqualToString:QTMediaTypeVideo]) {
        CFStringRef s;
        if (noErr == ICMImageDescriptionGetProperty(idh,
                                kQTPropertyClass_ImageDescription,
                                kICMImageDescriptionPropertyID_SummaryString,
                                sizeof(CFStringRef), &s, 0)) {
            result = [NSString stringWithString:(NSString*)s];
            CFRelease(s);
        }
    }
    else if ([mediaType isEqualToString:QTMediaTypeMPEG]) {
        NSRect rc = [[self attributeForKey:QTTrackBoundsAttribute] rectValue];
        NSString* name = [self attributeForKey:QTTrackDisplayNameAttribute];
        result = [NSString stringWithFormat:@"%@, %g x %g",
                  /*FIXME*/name, rc.size.width, rc.size.height];
    }
    else if ([mediaType isEqualToString:QTMediaTypeSound]) {
        // temporary impl. : how to get audio properties?
        CFStringRef s;
        if (noErr == ICMImageDescriptionGetProperty(idh,
                                kQTPropertyClass_ImageDescription,
                                kICMImageDescriptionPropertyID_SummaryString,
                                sizeof(CFStringRef), &s, 0)) {
            // remove strange contents after codec name.
            NSRange range = [(NSString*)s rangeOfString:@", "];
            result = [(NSString*)s substringToIndex:range.location];
            CFRelease(s);
        }
    }
    DisposeHandle((Handle)idh);
    return result;
}

@end

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

// a52Codec digital-audio
BOOL _a52CodecInstalled = FALSE;
BOOL _a52CodecAttemptPassthrough = FALSE;

// perian subtitle
static BOOL _perianInstalled = FALSE;
static BOOL _perianSubtitleEnabled = FALSE;

static BOOL _useQuickTimeSubtitles = FALSE;

@implementation MMovie_QuickTime

+ (NSString*)name { return @"QuickTime"; }

+ (void)setUseQuickTimeSubtitles:(BOOL)use
{
    _useQuickTimeSubtitles = use;
}

+ (void)checkA52CodecInstalled
{
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = @"/Library/Audio/Plug-Ins/Components/A52Codec.component";
    NSString* home = [[@"~" stringByExpandingTildeInPath] stringByAppendingString:root];
    _a52CodecInstalled = [fm fileExistsAtPath:root] || [fm fileExistsAtPath:home];
}

- (void)initA52Codec:(BOOL)digitalAudioOut
{
    // remember original settings & update new settings
    if (_a52CodecInstalled) {
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        _a52CodecAttemptPassthrough = [defaults a52CodecAttemptPassthrough];
        [defaults setA52CodecAttemptPassthrough:digitalAudioOut];
    }
}

- (void)cleanupA52Codec
{
    // restore original settings
    if (_a52CodecInstalled) {
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        [defaults setA52CodecAttemptPassthrough:_a52CodecAttemptPassthrough];
    }
}

+ (void)checkPerianInstalled
{
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* root = @"/Library/QuickTime/Perian.component";
    NSString* home = [[@"~" stringByExpandingTildeInPath] stringByAppendingString:root];
    _perianInstalled = [fm fileExistsAtPath:root] || [fm fileExistsAtPath:home];
}

- (void)initPerianSubtitle
{
    // remember original settings & update new settings
    if (_perianInstalled) {
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        _perianSubtitleEnabled = [defaults isPerianSubtitleEnabled];
        [defaults setPerianSubtitleEnabled:[defaults boolForKey:MUseQuickTimeSubtitlesKey]];
    }
}

- (void)cleanupPerianSubtitle
{
    // restore original settings
    if (_perianInstalled) {
        NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
        [defaults setPerianSubtitleEnabled:_perianSubtitleEnabled];
    }
}

- (MTrack*)videoTrackWithIndex:(int)index qtTrack:(QTTrack*)qtTrack
{
    NSSize displaySize = [[qtTrack attributeForKey:QTTrackDimensionsAttribute] sizeValue];
    NSSize encodedSize = displaySize;

    ImageDescriptionHandle idh = (ImageDescriptionHandle)NewHandleClear(sizeof(ImageDescription));
    if (idh) {
        GetMediaSampleDescription([[qtTrack media] quickTimeMedia], 1, (SampleDescriptionHandle)idh);
        FixedPoint fp;
        if (noErr == ICMImageDescriptionGetProperty(idh,
                        kQTPropertyClass_ImageDescription,
                        kICMImageDescriptionPropertyID_CleanApertureDisplayDimensions,
                        sizeof(fp), &fp, 0)) {
            NSSize size = NSMakeSize(FixedToFloat(fp.x), FixedToFloat(fp.y));
            if ((size.width < 10000 && size.height < 10000) &&
                (displaySize.width  != size.width ||     // check invalid value
                 displaySize.height != size.height)) {
                displaySize = size;
            }
        }
        if (noErr == ICMImageDescriptionGetProperty(idh,
                        kQTPropertyClass_ImageDescription,
                        kICMImageDescriptionPropertyID_EncodedPixelsDimensions,
                        sizeof(fp), &fp, 0)) {
            NSSize size = NSMakeSize(FixedToFloat(fp.x), FixedToFloat(fp.y));
            if ((size.width < 10000 && size.height < 10000) &&
                (encodedSize.width  != size.width ||     // check invalid value
                 encodedSize.height != size.height)) {
                encodedSize = size;
            }
        }
        DisposeHandle((Handle)idh);
    }
    //TRACE(@"displaySize=%@, encodedSize=%@",
    //      NSStringFromSize(displaySize), NSStringFromSize(encodedSize));

    MTrack* newTrack = [MTrack trackWithImpl:qtTrack];
    [newTrack setName:[qtTrack attributeForKey:QTTrackDisplayNameAttribute]];
    [newTrack setSummary:[qtTrack summary]];
    [newTrack setEncodedSize:encodedSize];
    [newTrack setDisplaySize:displaySize];
    [newTrack setEnabled:index == 0];  // enable first track only
    [newTrack setMovie:self];
    if (index < [_videoTracks count]) {
        MTrack* track = [_videoTracks objectAtIndex:index];
        [newTrack setCodecId:[track codecId]];
        [newTrack setFps:[track fps]];
    }
    return newTrack;
}

- (MTrack*)audioTrackWithIndex:(int)index qtTrack:(QTTrack*)qtTrack
{
    MTrack* newTrack = [MTrack trackWithImpl:qtTrack];
    [newTrack setName:[qtTrack attributeForKey:QTTrackDisplayNameAttribute]];
    [newTrack setSummary:[qtTrack summary]];
    [newTrack setEnabled:index == 0];  // enable first track only
    [newTrack setMovie:self];
    if (index < [_audioTracks count]) {
        MTrack* track = [_audioTracks objectAtIndex:index];
        [newTrack setCodecId:[track codecId]];
        [newTrack setAudioChannels:[track audioChannels]];
        [newTrack setAudioSampleRate:[track audioSampleRate]];
    }
    return newTrack;
}

- (id)initWithURL:(NSURL*)url movieInfo:(MMovieInfo*)movieInfo
  digitalAudioOut:(BOOL)digitalAudioOut error:(NSError**)error
{
    // currently, A52Codec supports AC3 only (not DTS).
    [self initA52Codec:(digitalAudioOut && movieInfo->hasAC3Codec)];

    //TRACE(@"%s %@", __PRETTY_FUNCTION__, [url absoluteString]);
    QTMovie* qtMovie;
    [self initPerianSubtitle];
    if ([url isFileURL]) {
        qtMovie = [QTMovie movieWithFile:[url path] error:error];
    }
    else {
        qtMovie = [QTMovie movieWithURL:url error:error];
    }
    [self cleanupPerianSubtitle];
    if (!qtMovie) {
        [self release];
        return nil;
    }
    NSSize movieSize = [[qtMovie attributeForKey:QTMovieNaturalSizeAttribute] sizeValue];
    if (movieSize.width == 0 || movieSize.height == 0) {
        *error = [NSError errorWithDomain:[MMovie_QuickTime name]
                                     code:ERROR_INVALID_VIDEO_DIMENSION
                                 userInfo:nil];
        [self release];
        return nil;
    }

    if ((self = [super initWithURL:url movieInfo:movieInfo
                   digitalAudioOut:digitalAudioOut error:error])) {
        av_close_input_file(movieInfo->formatContext);
        _qtMovie = [qtMovie retain];

        // override video/audio tracks
        NSMutableArray* vTracks = [NSMutableArray arrayWithCapacity:1];
        NSMutableArray* aTracks = [NSMutableArray arrayWithCapacity:1];
        NSString* mediaType;
        QTTrack* qtTrack;
        int vi = 0, ai = 0;
        NSEnumerator* enumerator = [[_qtMovie tracks] objectEnumerator];
        while (qtTrack = [enumerator nextObject]) {
            mediaType = [qtTrack attributeForKey:QTTrackMediaTypeAttribute];
            if ([mediaType isEqualToString:QTMediaTypeVideo] ||
                [mediaType isEqualToString:QTMediaTypeMPEG]/* ||
                [mediaType isEqualToString:QTMediaTypeMovie]*/) {
                [vTracks addObject:[self videoTrackWithIndex:vi++ qtTrack:qtTrack]];
            }
            else if ([mediaType isEqualToString:QTMediaTypeSound]/* ||
                     [mediaType isEqualToString:QTMediaTypeMusic]*/) {
                [aTracks addObject:[self audioTrackWithIndex:ai++ qtTrack:qtTrack]];
            }
        }
        [_videoTracks setArray:vTracks];
        [_audioTracks setArray:aTracks];
        [self setAspectRatio:_aspectRatio]; // for _adjustedSize

        // override _duration & _startTime by QuickTime
        QTTime t = [_qtMovie duration];
        _duration = (float)t.timeValue / t.timeScale;
        _startTime = 0;

        // override _preferredVolume, _volume & _muted by QuickTime
        _preferredVolume = [[_qtMovie attributeForKey:QTMoviePreferredVolumeAttribute] floatValue];
        _volume = [_qtMovie volume];
        _muted = [_qtMovie muted];

        // loading-state cannot be get by QTMovieLoadStateDidChangeNotification.
        // I think that it may be already posted before _qtMovie is returned.
        _indexingUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                target:self selector:@selector(updateIndexedDuration:)
                                userInfo:nil repeats:TRUE];
    }
    return self;
}

- (BOOL)setOpenGLContext:(NSOpenGLContext*)openGLContext
             pixelFormat:(NSOpenGLPixelFormat*)openGLPixelFormat
                   error:(NSError**)error
{
    //TRACE(@"%s", __PRETTY_FUNCTION__);
    // create visual context
    OSStatus ret = QTOpenGLTextureContextCreate(kCFAllocatorDefault,
                                                [openGLContext CGLContextObj],
                                                [openGLPixelFormat CGLPixelFormatObj],
                                                0, &_visualContext);
    if (ret != noErr) {
        //TRACE(@"QTOpenGLTextureContextCreate() failed: %d", ret);
        if (error) {
            NSDictionary* dict =
            [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:ret]
                                        forKey:@"returnCode"];
            *error = [NSError errorWithDomain:@"QuickTime"
                                         code:ERROR_VISUAL_CONTEXT_CREATE_FAILED
                                     userInfo:dict];
        }
        return FALSE;
    }

    SetMovieVisualContext([_qtMovie quickTimeMovie], _visualContext);

    NSNotificationCenter* nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(qtMovieRateChanged:)
               name:QTMovieRateDidChangeNotification object:_qtMovie];
    [nc addObserver:self selector:@selector(qtMovieEnded:)
               name:QTMovieDidEndNotification object:_qtMovie];
    return TRUE;
}

- (void)cleanup
{
    //TRACE(@"%s", __PRETTY_FUNCTION__);
    if ([_indexingUpdateTimer isValid]) {
        [_indexingUpdateTimer invalidate];
        _indexingUpdateTimer = nil;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    SetMovieVisualContext([_qtMovie quickTimeMovie], 0);
    if (_visualContext) {
        CFRelease(_visualContext);
    }
    [_qtMovie release], _qtMovie = nil;
    [self cleanupA52Codec];

    [super cleanup];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

- (void)updateIndexedDuration:(NSTimer*)timer
{
    float duration = _indexedDuration;
    long ret = GetMovieLoadState([_qtMovie quickTimeMovie]);
    if (ret == kMovieLoadStateComplete) {
        [_indexingUpdateTimer invalidate];
        _indexingUpdateTimer = nil;
        duration = [self duration];
    }
    else {
        TimeValue tv;
        if (noErr == GetMaxLoadedTimeInMovie([_qtMovie quickTimeMovie], &tv)) {
            duration = tv / 1000.0;
        }
    }
    [self indexedDurationUpdated:duration];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -

// currently, A52Codec supports AC3 only (not DTS)
- (BOOL)supportsAC3DigitalOut { return _a52CodecInstalled; }
- (BOOL)supportsDTSDigitalOut { return FALSE; }

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark volume

- (void)setVolume:(float)volume
{
    [_qtMovie setVolume:volume];
    [super setVolume:volume];
}

- (void)setMuted:(BOOL)muted
{
    [_qtMovie setMuted:muted];
    [super setMuted:muted];
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark playback

- (float)currentTime
{
    QTTime t = [_qtMovie currentTime];
    return (float)t.timeValue / t.timeScale;
}

- (float)rate { return [_qtMovie rate]; }
- (void)setRate:(float)rate { [_qtMovie setRate:rate]; }
- (void)stepBackward { [_qtMovie stepBackward]; }
- (void)stepForward { [_qtMovie stepForward]; }
- (void)gotoBeginning { [_qtMovie gotoBeginning]; }
- (void)gotoEnd { [_qtMovie gotoEnd]; }

- (void)gotoTime:(float)time
{
    //TRACE(@"%s %g", __PRETTY_FUNCTION__, time);
    QTTime t = [_qtMovie currentTime];    // to fill timeScale & flags
    t.timeValue = (long long)(time * t.timeScale);

    if (t.timeValue < 0) {
        [_qtMovie gotoBeginning];
    }
    else if ([_qtMovie duration].timeValue < t.timeValue) {
        [_qtMovie gotoEnd];
    }
    else {
        float rate = [_qtMovie rate];
        [_qtMovie setCurrentTime:t];
        [_qtMovie setRate:rate];   // play continue...
    }
}

- (void)seekByTime:(float)dt
{
    //TRACE(@"%s %g", __PRETTY_FUNCTION__, dt);
    float time = [self currentTime] + dt;
    time = (dt < 0) ? MAX(0, time) : MIN(time, [self duration]);
    [self gotoTime:time];
}

- (CVOpenGLTextureRef)nextImage:(const CVTimeStamp*)timeStamp
{
    //TRACE(@"%s", __PRETTY_FUNCTION__);
    if (!QTVisualContextIsNewImageAvailable(_visualContext, timeStamp)) {
        return 0;
    }

    CVOpenGLTextureRef image;
    OSStatus ret = QTVisualContextCopyImageForTime(_visualContext, 0, timeStamp, &image);
    if (ret != noErr || !image) {
        return 0;
    }

    [[NSNotificationCenter defaultCenter]
        postNotificationName:MMovieCurrentTimeNotification object:self];
    return image;
}

- (void)idleTask
{
    QTVisualContextTask(_visualContext);
}

////////////////////////////////////////////////////////////////////////////////
#pragma mark -
#pragma mark notifications

- (void)qtMovieRateChanged:(NSNotification*)notification
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MMovieRateChangeNotification object:self];
}

- (void)qtMovieEnded:(NSNotification*)notification
{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MMovieEndNotification object:self];
}

@end
